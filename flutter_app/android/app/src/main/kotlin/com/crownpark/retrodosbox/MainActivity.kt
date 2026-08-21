package com.crownpark.retrodosbox

import android.content.Context
import android.content.Intent
import android.hardware.input.InputManager
import android.net.Uri
import android.os.Build
import android.os.Looper
import android.os.Bundle
import android.os.Handler
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.flame_engine.gamepads_android.GamepadsCompatibleActivity

/**
 * The gamepads_android plugin casts the host Activity to
 * GamepadsCompatibleActivity in onAttachedToActivityShared(). A plain
 * FlutterActivity does not implement it, so plugin registration throws a
 * ClassCastException on every launch, the plugin is skipped entirely, and no
 * physical controller is ever seen on Android. (External gamepads work on
 * Linux desktop regardless, because a different plugin implementation is used
 * there -- which is exactly why this failure is easy to miss during
 * development.)
 *
 * Implementing the interface here wires the plugin's listeners into this
 * Activity's own input dispatch, which is what it expects.
 */
class MainActivity : FlutterActivity(), GamepadsCompatibleActivity {
    private var keyEventHandler: ((KeyEvent) -> Boolean)? = null
    private var motionEventHandler: ((MotionEvent) -> Boolean)? = null

    override fun registerInputDeviceListener(
        listener: InputManager.InputDeviceListener,
        handler: Handler?
    ) {
        val inputManager = getSystemService(Context.INPUT_SERVICE) as InputManager
        inputManager.registerInputDeviceListener(listener, handler)
    }

    override fun registerKeyEventHandler(handler: (KeyEvent) -> Boolean) {
        keyEventHandler = handler
    }

    override fun registerMotionEventHandler(handler: (MotionEvent) -> Boolean) {
        motionEventHandler = handler
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (keyEventHandler?.invoke(event) == true) {
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (motionEventHandler?.invoke(event) == true) {
            return true
        }
        return super.dispatchGenericMotionEvent(event)
    }

    /**
     * Bringing a game collection in, without asking for all-files access.
     *
     * A DOS collection in shared storage is folders of .exe/.com/.bat plus
     * .iso/.img/.zip. None of those are media types, so READ_MEDIA_* never
     * covered them, and on Android 11+ the app can LIST a games folder while
     * every attempt to read a file's bytes fails - a failure mode that is
     * nasty precisely because the library looks fine and every title then
     * launches to a black screen.
     *
     * MANAGE_EXTERNAL_STORAGE is what used to paper over that, and it is a
     * Play sensitive permission: undeclared it blocks the release outright,
     * declared it means a review aimed at file managers, backup and antivirus
     * apps. This app is replacing a published one, so gating that on a review
     * is not worth it.
     *
     * dosbox-x mounts a DIRECTORY, so unlike a single disk image there is
     * nothing to materialise on demand - the games have to genuinely live
     * somewhere the app can read. They do: the app's own external folder. The
     * user grants a source folder through the picker and its contents are
     * copied in, relative structure intact. See MediaFolderAccess.
     */
    /** The Dart call waiting on the folder picker; completed in onActivityResult. */
    private var pendingFolderPick: MethodChannel.Result? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != MediaFolderAccess.REQUEST_PICK_FOLDER) return
        val pending = pendingFolderPick
        pendingFolderPick = null
        if (pending == null) return
        val uri: Uri? = if (resultCode == RESULT_OK) data?.data else null
        if (uri == null) {
            pending.success(null)
            return
        }
        try {
            MediaFolderAccess.persist(this, uri)
            pending.success(uri.toString())
        } catch (e: SecurityException) {
            pending.error("not_persistable", "the folder grant could not be kept", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STORAGE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "mediaFolderUri" ->
                    result.success(MediaFolderAccess.grantedTree(this)?.toString())

                "pickMediaFolder" -> {
                    // The answer arrives in onActivityResult, not here.
                    if (pendingFolderPick != null) {
                        result.error("busy", "a folder picker is already open", null)
                    } else {
                        pendingFolderPick = result
                        MediaFolderAccess.pickFolder(this)
                    }
                }

                "forgetMediaFolder" -> {
                    MediaFolderAccess.release(this)
                    result.success(true)
                }

                "listMediaFolder" -> {
                    val limit = call.argument<Int>("fileLimit") ?: 20000
                    val tree = MediaFolderAccess.grantedTree(this)
                    if (tree == null) {
                        result.error("no_folder", "no folder has been granted", null)
                    } else {
                        // Off the main thread: a DOS collection is thousands of
                        // small files, and that many provider rows on the UI
                        // thread is an ANR, not a slow scan.
                        Thread {
                            val entries = MediaFolderAccess.enumerate(
                                contentResolver, tree, limit)
                            val payload = entries.map {
                                mapOf(
                                    "documentId" to it.documentId,
                                    "name" to it.name,
                                    "directory" to it.relativeDirectory,
                                    "size" to it.size,
                                )
                            }
                            Handler(Looper.getMainLooper()).post { result.success(payload) }
                        }.start()
                    }
                }

                "copyFromMediaFolder" -> {
                    val documentId = call.argument<String>("documentId")
                    val destination = call.argument<String>("destination")
                    val tree = MediaFolderAccess.grantedTree(this)
                    if (documentId == null || destination == null) {
                        result.error("bad_args",
                            "copyFromMediaFolder needs documentId and destination", null)
                    } else if (tree == null) {
                        result.error("no_folder", "no folder has been granted", null)
                    } else {
                        Thread {
                            val ok = MediaFolderAccess.copyDocument(
                                contentResolver, tree, documentId, destination)
                            Handler(Looper.getMainLooper()).post { result.success(ok) }
                        }.start()
                    }
                }

                // The one-shot core's way out. See restartApp.
                "restartApp" -> {
                    // Answer BEFORE restarting: the channel goes away with the
                    // process, and a caller awaiting a reply that can never
                    // arrive hangs instead of finishing its own teardown.
                    result.success(true)
                    restartApp()
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Replaces this process with a fresh one, returning to the library.
     *
     * DOSBox-X cannot be torn down and started again safely in one process:
     * its upstream globals have no complete teardown path, and the Quit that
     * dosbox_core_stop relies on is delivered through the frame-publish hook,
     * which a core that has stopped rendering never reaches. Asking it to stop
     * therefore times out and leaves the core wedged - started, unstoppable,
     * and refusing every later launch.
     *
     * So closing a game replaces the process instead. AppRestartActivity runs
     * in :restart and is a foreground activity, which is what lets it start
     * MainActivity after this process has gone; an alarm or a PendingIntent
     * would be refused by background-start rules.
     */
    private fun restartApp() {
        startActivity(
            Intent(this, AppRestartActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        Handler(mainLooper).postDelayed({
            finishAndRemoveTask()
            android.os.Process.killProcess(android.os.Process.myPid())
        }, PROCESS_EXIT_DELAY_MS)
    }

    companion object {
        private const val PROCESS_EXIT_DELAY_MS = 100L
        private const val TAG = "RetroDosbox"
        private const val STORAGE_CHANNEL = "com.crownpark.retrodosbox/storage_permissions"

        @Volatile private var sdlInitialized = false

        // HIDDeviceManager owns the Java callback object used by SDL's Android
        // HIDAPI backend. Keep the acquired singleton for the lifetime of the
        // process: releasing it unregisters that callback while DOSBox's SDL
        // thread may still be running.
        private var sdlHidDeviceManager: org.libsdl.app.HIDDeviceManager? = null

        // Bind SDL2's JNI bridge so a downstream dosbox launch does not segfault
        // in SDL_AndroidGetInternalStoragePath. DOSBox-X is built against SDL2
        // Android, which assumes its host activity is org.libsdl.app.SDLActivity.
        // Our MainActivity is a FlutterActivity, so SDLActivity.onCreate never
        // runs, mActivityClass stays NULL, and the very first SDL subsystem init
        // that touches storage -- SDL_INIT_JOYSTICK's controller mapping loader
        // calling SDL_AndroidGetInternalStoragePath() -- segfaults dereferencing
        // a NULL JNI class.
        //
        // The shipped org.libsdl.app.* Java stubs satisfy JNI_OnLoad's FindClass
        // lookups and provide the static native method declarations SDL C side
        // binds against. setupJNI() then populates mActivityClass and the mid*
        // method IDs against the stub; setContext() makes getContext() return
        // the application context so SDL's storage-path JNI callback resolves.
        // The stub SDLActivity is never instantiated.
        //
        // libSDL2's JNI_OnLoad must run before setupJNI() (so mJavaVM is set).
        // libSDL2 is loaded as a dependency of libdosboxcore.so when Dart FFI
        // calls core.init() at app start. We don't depend on that ordering here:
        // System.loadLibrary("SDL2") is idempotent and pre-loads it if the .so
        // hasn't been pulled in yet.
        private fun setupSdlJni(ctx: Context) {
            if (sdlInitialized) return
            // Three distinct failure modes have to be distinguishable in
            // logcat, not all swallowed silently -- otherwise a missing
            // org.libsdl.app.SDL class (the case behind the "crash on zip
            // launch" bug this method was added to fix) lands as a NULL
            // deref inside SDL_InitSubSystem with no breadcrumb back to
            // Android setup. UnsatisfiedLinkError is the documented
            // "no .so yet" mode; the class-lookup failures are a build
            // mismatch and must surface.
            try {
                System.loadLibrary("SDL2")
                org.libsdl.app.SDL.setupJNI()
                // initialize() registers Bluetooth/USB receivers via
                // HIDDeviceManager and sets up the audio recorder. They key off
                // the supplied Context, not whether it is an Activity, so the
                // application context is fine here.
                org.libsdl.app.SDL.initialize()
                org.libsdl.app.SDL.setContext(ctx.applicationContext)
                // SDLActivity normally does this from its onCreate(). This app
                // embeds DOSBox in Flutter, so SDLActivity is never created.
                // Without the acquire call, Android HIDAPI's g_JVM remains
                // null and SDL_INIT_JOYSTICK crashes in PLATFORM_hid_init().
                sdlHidDeviceManager = org.libsdl.app.HIDDeviceManager.acquire(
                    ctx.applicationContext
                )
                sdlInitialized = true
            } catch (_: UnsatisfiedLinkError) {
                // libSDL2 not packaged yet -- a pure-UI dev cycle without the
                // .so. Real launches will retry from the FFI path: Dart FFI's
                // DynamicLibrary.open auto-runs JNI_OnLoad for libSDL2.so via
                // the Android dynamic linker, but does not give us a hook to
                // call setupJNI() afterwards. We carry a flag on the JNI side
                // so dosbox_core_init can run setup itself (see
                // bridge/dosbox_bridge.cpp). Until that lands, a missing .so
                // means no library-based launches.
            } catch (e: Throwable) {
                // The org.libsdl.app.* Java stubs are required -- without
                // them SDL2's JNI callbacks (SDL_AndroidGetInternalStoragePath
                // and friends) segfault dereferencing a NULL mActivityClass.
                // Surface that distinctly from the "no .so" case above so a
                // stale APK (stubs dropped from the build) shows up as
                // "setupSdlJni: ..." in logcat rather than as a SIGSEGV in
                // dosbox_core_start.
                Log.e(TAG, "setupSdlJni: SDL Java stubs unavailable -- "
                    + "libSDL2.so will segfault the first time dosbox starts. "
                    + "Rebuild the APK with the org.libsdl.app.* sources.", e)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Run before super so SDL's JNI is ready by the time Flutter starts
        // pumping input events through the bridge.
        setupSdlJni(this)
        super.onCreate(savedInstanceState)
    }
}