package com.dosboxmultiplatform.dosbox_multiplatform

import android.content.Context
import android.content.Intent
import android.hardware.input.InputManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.provider.Settings
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
     * "All files access" (MANAGE_EXTERNAL_STORAGE) plumbing.
     *
     * A DOS game collection in shared storage is folders of .exe/.com/.bat
     * plus .iso/.img/.zip files. None of those are media types, so the
     * READ_MEDIA_* permissions do not cover them: on Android 11+ the app can
     * LIST a games folder but every attempt to read a file's bytes fails.
     * That failure mode is nasty precisely because the library looks fine and
     * then every title launches to a black screen.
     *
     * A two-method channel rather than the permission_handler package: the
     * only thing needed from it is these two platform calls.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STORAGE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                "requestAllFilesAccess" -> {
                    requestAllFilesAccess()
                    // The grant happens in system Settings, so this only
                    // reports the state as of right now; Dart re-checks when
                    // the app resumes.
                    result.success(hasAllFilesAccess())
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            RESTART_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "restartApp" -> {
                    result.success(true)
                    restartApp()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true // pre-R: the manifest's READ_EXTERNAL_STORAGE covers it
        }

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        if (hasAllFilesAccess()) return
        val appSpecific = Intent(
            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
            Uri.parse("package:$packageName")
        )
        try {
            startActivity(appSpecific)
        } catch (_: Exception) {
            // Some OEM builds do not implement the per-app screen; the global
            // list always exists.
            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }

    /**
     * DOSBox-X cannot be torn down and started again safely in one process.
     * Relaunch the Flutter activity after this process has exited, giving the
     * user a fresh core while returning directly to the library.
     */
    private fun restartApp() {
        // AppRestartActivity runs in :restart. Unlike an alarm PendingIntent,
        // it is a foreground activity and Android therefore allows it to
        // launch MainActivity after this process has gone away.
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
        private const val TAG = "DosboxMultiplatform"
        private const val STORAGE_CHANNEL = "dosbox_multiplatform/storage_permissions"
        private const val RESTART_CHANNEL = "dosbox_multiplatform/app_restart"
        private const val PROCESS_EXIT_DELAY_MS = 100L

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
