package com.crownpark.retrodosbox

import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the emulator, in the :dosbox process.
 *
 * DOSBox-X is a one-shot core: its upstream globals have no teardown path, so
 * a session can only really end by ending a process. Running the engine here
 * means exactly that -- stopping this service kills the process, Android
 * reclaims whatever the engine leaked, and the next game gets a genuinely
 * fresh core while the launcher's process is never touched.
 *
 * A service rather than an activity because the engine has no window of its
 * own: it renders offscreen and publishes frames into a mapping the launcher
 * draws from, in its own panel, under its own controls. An activity would have
 * covered the launcher it is meant to be drawing inside.
 *
 * It runs a headless FlutterEngine purely to reach the core: the FFI bindings
 * the launcher already has are the shortest path to the bridge, and doing it
 * from Kotlin instead would have meant a JNI wrapper around the whole bridge
 * ABI plus another rebuild of both cores to add it.
 */
class DosboxCoreService : Service() {

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

    /** Held until the Dart isolate says it is ready to be given one. */
    private var pendingStart: Intent? = null
    private var ready = false

    /**
     * Input, over a binding rather than the intents that carry start/stop.
     *
     * Input is the one thing here that is continuous: a held direction is a
     * stream of events, and startService() for each one goes through
     * ActivityManager and would turn a joystick push into a queue of process
     * management. A bound Messenger is a direct binder hop into this process,
     * which is what a keypress can afford.
     */
    private val inbox = Messenger(
        Handler(Looper.getMainLooper()) { msg ->
            if (msg.what == MSG_INPUT) {
                val b = msg.data
                channel?.invokeMethod(
                    "input",
                    mapOf(
                        "kind" to b.getString("kind"),
                        "a" to b.getInt("a"),
                        "b" to b.getInt("b"),
                        "x" to b.getDouble("x"),
                        "y" to b.getDouble("y"),
                        "down" to b.getBoolean("down"),
                        "text" to b.getString("text"),
                        "text2" to b.getString("text2"),
                        "text3" to b.getString("text3"),
                    ),
                )
            }
            true
        }
    )

    override fun onBind(intent: Intent?): IBinder = inbox.binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) return START_NOT_STICKY

        // A pause is not a start: it arrives for a session already running,
        // and treating it as one would boot the title a second time.
        if (intent.hasExtra(EXTRA_PAUSED)) {
            channel?.invokeMethod(
                "pause",
                mapOf("paused" to intent.getBooleanExtra(EXTRA_PAUSED, false)),
            )
            return START_NOT_STICKY
        }

        if (engine == null) {
            startEngine()
        }
        if (ready) {
            deliver(intent)
        } else {
            // The isolate is still starting. A start() that lands before it is
            // listening is a session that silently never begins, so it waits.
            pendingStart = intent
        }
        // NOT sticky: a restarted service with no title would be a process
        // running an engine nobody asked for.
        return START_NOT_STICKY
    }

    private fun startEngine() {
        // SDL's JNI has to be wired before the core touches it. In the
        // launcher that happens because MainActivity does it; out here there is
        // no activity at all, and SDL_VideoInit dereferenced a null activity
        // and took the process down with SIGSEGV.
        MainActivity.setupSdlJni(applicationContext)

        val e = FlutterEngine(this)
        // The three-argument form, with the library the function lives in.
        //
        // The two-argument one looks the name up in the ROOT library - main.dart
        // - so a correctly annotated entrypoint in any other file fails with
        // "Could not resolve main entrypoint function", which is exactly what
        // this did. Naming the library is what makes it findable; importing it
        // from main.dart only gets it compiled.
        e.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                flutterLoader().findAppBundlePath(),
                ENTRYPOINT_LIBRARY,
                ENTRYPOINT,
            )
        )
        channel = MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> {
                        ready = true
                        pendingStart?.let { deliver(it) }
                        pendingStart = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        engine = e
    }

    private fun flutterLoader() =
        io.flutter.FlutterInjector.instance().flutterLoader().apply {
            if (!initialized()) {
                startInitialization(applicationContext)
                ensureInitializationComplete(applicationContext, null)
            }
        }

    private fun deliver(intent: Intent) {
        channel?.invokeMethod(
            "start",
            mapOf(
                "confPath" to intent.getStringExtra(EXTRA_CONF_PATH),
                "sharedFramePath" to intent.getStringExtra(EXTRA_SHARED_FRAME),
                "maxWidth" to intent.getIntExtra(EXTRA_MAX_WIDTH, 1024),
                "maxHeight" to intent.getIntExtra(EXTRA_MAX_HEIGHT, 768),
            ),
        )
    }

    override fun onDestroy() {
        super.onDestroy()
        // The engine is not asked to shut down cleanly, because it cannot: the
        // process going away IS the teardown, and that is the whole reason the
        // core lives out here.
        engine?.destroy()
        engine = null
        android.os.Process.killProcess(android.os.Process.myPid())
    }

    companion object {
        const val EXTRA_CONF_PATH = "conf_path"
        const val EXTRA_SHARED_FRAME = "shared_frame_path"
        const val EXTRA_MAX_WIDTH = "max_width"
        const val EXTRA_MAX_HEIGHT = "max_height"
        const val EXTRA_PAUSED = "paused"

        /** A key, mouse, or joystick event for the running session. */
        const val MSG_INPUT = 1

        private const val CHANNEL = "com.crownpark.retrodosbox/core_process"
        private const val ENTRYPOINT_LIBRARY =
            "package:retro_dosbox/core_process_main.dart"
        private const val ENTRYPOINT = "dosboxCoreMain"
    }
}
