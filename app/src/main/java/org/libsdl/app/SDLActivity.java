package org.libsdl.app;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.app.UiModeManager;
import android.content.ClipboardManager;
import android.content.ClipData;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.graphics.drawable.Drawable;
import android.hardware.Sensor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Message;
import android.text.Editable;
import android.text.InputType;
import android.text.Selection;
import android.util.DisplayMetrics;
import android.util.Log;
import android.util.SparseArray;
import android.view.Display;
import android.view.Gravity;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.PointerIcon;
import android.view.Surface;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.RelativeLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.util.Hashtable;
import java.util.Locale;
import java.util.Map;


/**
    SDL Activity
*/
public class SDLActivity extends Activity implements View.OnSystemUiVisibilityChangeListener {
    private static final String TAG = "SDL";
    private static final int SDL_MAJOR_VERSION = 2;
    private static final int SDL_MINOR_VERSION = 32;
    private static final int SDL_MICRO_VERSION = 10;
/*
    // Display InputType.SOURCE/CLASS of events and devices
    //
    // SDLActivity.debugSource(device.getSources(), "device[" + device.getName() + "]");
    // SDLActivity.debugSource(event.getSource(), "event");
    public static void debugSource(int sources, String prefix) {
        int s = sources;
        int s_copy = sources;
        String cls = "";
        String src = "";
        int tst = 0;
        int FLAG_TAINTED = 0x80000000;

        if ((s & InputDevice.SOURCE_CLASS_BUTTON) != 0)     cls += " BUTTON";
        if ((s & InputDevice.SOURCE_CLASS_JOYSTICK) != 0)   cls += " JOYSTICK";
        if ((s & InputDevice.SOURCE_CLASS_POINTER) != 0)    cls += " POINTER";
        if ((s & InputDevice.SOURCE_CLASS_POSITION) != 0)   cls += " POSITION";
        if ((s & InputDevice.SOURCE_CLASS_TRACKBALL) != 0)  cls += " TRACKBALL";


        int s2 = s_copy & ~InputDevice.SOURCE_ANY; // keep class bits
        s2 &= ~(  InputDevice.SOURCE_CLASS_BUTTON
                | InputDevice.SOURCE_CLASS_JOYSTICK
                | InputDevice.SOURCE_CLASS_POINTER
                | InputDevice.SOURCE_CLASS_POSITION
                | InputDevice.SOURCE_CLASS_TRACKBALL);

        if (s2 != 0) cls += "Some_Unknown";

        s2 = s_copy & InputDevice.SOURCE_ANY; // keep source only, no class;

        if (Build.VERSION.SDK_INT >= 23) {
            tst = InputDevice.SOURCE_BLUETOOTH_STYLUS;
            if ((s & tst) == tst) src += " BLUETOOTH_STYLUS";
            s2 &= ~tst;
        }

        tst = InputDevice.SOURCE_DPAD;
        if ((s & tst) == tst) src += " DPAD";
        s2 &= ~tst;

        tst = InputDevice.SOURCE_GAMEPAD;
        if ((s & tst) == tst) src += " GAMEPAD";
        s2 &= ~tst;

        if (Build.VERSION.SDK_INT >= 21) {
            tst = InputDevice.SOURCE_HDMI;
            if ((s & tst) == tst) src += " HDMI";
            s2 &= ~tst;
        }

        tst = InputDevice.SOURCE_JOYSTICK;
        if ((s & tst) == tst) src += " JOYSTICK";
        s2 &= ~tst;

        tst = InputDevice.SOURCE_KEYBOARD;
        if ((s & tst) == tst) src += " KEYBOARD";
        s2 &= ~tst;

        tst = InputDevice.SOURCE_MOUSE;
        if ((s & tst) == tst) src += " MOUSE";
        s2 &= ~tst;

        if (Build.VERSION.SDK_INT >= 26) {
            tst = InputDevice.SOURCE_MOUSE_RELATIVE;
            if ((s & tst) == tst) src += " MOUSE_RELATIVE";
            s2 &= ~tst;

            tst = InputDevice.SOURCE_ROTARY_ENCODER;
            if ((s & tst) == tst) src += " ROTARY_ENCODER";
            s2 &= ~tst;
        }
        tst = InputDevice.SOURCE_STYLUS;
        if ((s & tst) == tst) src += " STYLUS";
        s2 &= ~tst;

        tst = InputDevice.SOURCE_TOUCHPAD;
        if ((s & tst) == tst) src += " TOUCHPAD";
        s2 &= ~tst;

        tst = InputDevice.SOURCE_TOUCHSCREEN;
        if ((s & tst) == tst) src += " TOUCHSCREEN";
        s2 &= ~tst;

        if (Build.VERSION.SDK_INT >= 18) {
            tst = InputDevice.SOURCE_TOUCH_NAVIGATION;
            if ((s & tst) == tst) src += " TOUCH_NAVIGATION";
            s2 &= ~tst;
        }

        tst = InputDevice.SOURCE_TRACKBALL;
        if ((s & tst) == tst) src += " TRACKBALL";
        s2 &= ~tst;

        tst = InputDevice.SOURCE_ANY;
        if ((s & tst) == tst) src += " ANY";
        s2 &= ~tst;

        if (s == FLAG_TAINTED) src += " FLAG_TAINTED";
        s2 &= ~FLAG_TAINTED;

        if (s2 != 0) src += " Some_Unknown";

        Log.v(TAG, prefix + "int=" + s_copy + " CLASS={" + cls + " } source(s):" + src);
    }
*/

    public static boolean mIsResumedCalled, mHasFocus;
    public static final boolean mHasMultiWindow = (Build.VERSION.SDK_INT >= 24  /* Android 7.0 (N) */);

    // Cursor types
    // private static final int SDL_SYSTEM_CURSOR_NONE = -1;
    private static final int SDL_SYSTEM_CURSOR_ARROW = 0;
    private static final int SDL_SYSTEM_CURSOR_IBEAM = 1;
    private static final int SDL_SYSTEM_CURSOR_WAIT = 2;
    private static final int SDL_SYSTEM_CURSOR_CROSSHAIR = 3;
    private static final int SDL_SYSTEM_CURSOR_WAITARROW = 4;
    private static final int SDL_SYSTEM_CURSOR_SIZENWSE = 5;
    private static final int SDL_SYSTEM_CURSOR_SIZENESW = 6;
    private static final int SDL_SYSTEM_CURSOR_SIZEWE = 7;
    private static final int SDL_SYSTEM_CURSOR_SIZENS = 8;
    private static final int SDL_SYSTEM_CURSOR_SIZEALL = 9;
    private static final int SDL_SYSTEM_CURSOR_NO = 10;
    private static final int SDL_SYSTEM_CURSOR_HAND = 11;

    protected static final int SDL_ORIENTATION_UNKNOWN = 0;
    protected static final int SDL_ORIENTATION_LANDSCAPE = 1;
    protected static final int SDL_ORIENTATION_LANDSCAPE_FLIPPED = 2;
    protected static final int SDL_ORIENTATION_PORTRAIT = 3;
    protected static final int SDL_ORIENTATION_PORTRAIT_FLIPPED = 4;

    protected static int mCurrentOrientation;
    protected static Locale mCurrentLocale;

    // Handle the state of the native layer
    public enum NativeState {
           INIT, RESUMED, PAUSED
    }

    public static NativeState mNextNativeState;
    public static NativeState mCurrentNativeState;

    /** If shared libraries (e.g. SDL or the native application) could not be loaded. */
    public static boolean mBrokenLibraries = true;

    /* DosBoxX: per-game gamepad-to-keyboard keymap. Set by
     * GameLauncherActivity before it starts us. A null map means "use the
     * hard-coded defaults" (see mapGamepadButtonToKey). */
    public static Map<String, Integer> sKeyMap = null;

    // Main components
    protected static SDLActivity mSingleton;
    protected static SDLSurface mSurface;
    protected static DummyEdit mTextEdit;
    protected static boolean mScreenKeyboardShown;
    protected static ViewGroup mLayout;
    protected static SDLClipboardHandler mClipboardHandler;
    protected static Hashtable<Integer, PointerIcon> mCursors;
    protected static int mLastCursorID;
    protected static SDLGenericMotionListener_API12 mMotionListener;
    protected static HIDDeviceManager mHIDDeviceManager;

    // This is what SDL runs in. It invokes SDL_main(), eventually
    protected static Thread mSDLThread;

    protected static SDLGenericMotionListener_API12 getMotionListener() {
        if (mMotionListener == null) {
            if (Build.VERSION.SDK_INT >= 26 /* Android 8.0 (O) */) {
                mMotionListener = new SDLGenericMotionListener_API26();
            } else if (Build.VERSION.SDK_INT >= 24 /* Android 7.0 (N) */) {
                mMotionListener = new SDLGenericMotionListener_API24();
            } else {
                mMotionListener = new SDLGenericMotionListener_API12();
            }
        }

        return mMotionListener;
    }

    /**
     * This method returns the name of the shared object with the application entry point
     * It can be overridden by derived classes.
     */
    protected String getMainSharedObject() {
        String library;
        String[] libraries = SDLActivity.mSingleton.getLibraries();
        if (libraries.length > 0) {
            library = "lib" + libraries[libraries.length - 1] + ".so";
        } else {
            library = "libmain.so";
        }
        return getContext().getApplicationInfo().nativeLibraryDir + "/" + library;
    }

    /**
     * This method returns the name of the application entry point
     * It can be overridden by derived classes.
     */
    protected String getMainFunction() {
        return "SDL_main";
    }

    /**
     * This method is called by SDL before loading the native shared libraries.
     * It can be overridden to provide names of shared libraries to be loaded.
     * The default implementation returns the defaults. It never returns null.
     * An array returned by a new implementation must at least contain "SDL2".
     * Also keep in mind that the order the libraries are loaded may matter.
     * @return names of shared libraries to be loaded (e.g. "SDL2", "main").
     */
    protected String[] getLibraries() {
        return new String[] {
            "SDL2",
            // "SDL2_image",
            // "SDL2_mixer",
            // "SDL2_net",
            // "SDL2_ttf",
            "main"
        };
    }

    // Load the .so
    public void loadLibraries() {
       for (String lib : getLibraries()) {
          SDL.loadLibrary(lib, this);
       }
    }

    /**
     * This method is called by SDL before starting the native application thread.
     * It can be overridden to provide the arguments after the application name.
     * The default implementation returns an empty array. It never returns null.
     * @return arguments for the native application.
     */
    protected String[] getArguments() {
        return new String[0];
    }

    public static void initialize() {
        // The static nature of the singleton and Android quirkyness force us to initialize everything here
        // Otherwise, when exiting the app and returning to it, these variables *keep* their pre exit values
        mSingleton = null;
        mSurface = null;
        mTextEdit = null;
        mLayout = null;
        mClipboardHandler = null;
        mCursors = new Hashtable<Integer, PointerIcon>();
        mLastCursorID = 0;
        mSDLThread = null;
        mIsResumedCalled = false;
        mHasFocus = true;
        mNextNativeState = NativeState.INIT;
        mCurrentNativeState = NativeState.INIT;
    }
    
    protected SDLSurface createSDLSurface(Context context) {
        return new SDLSurface(context);
    }

    // Setup
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        Log.v(TAG, "Device: " + Build.DEVICE);
        Log.v(TAG, "Model: " + Build.MODEL);
        Log.v(TAG, "onCreate()");
        super.onCreate(savedInstanceState);

        try {
            Thread.currentThread().setName("SDLActivity");
        } catch (Exception e) {
            Log.v(TAG, "modify thread properties failed " + e.toString());
        }

        // Load shared libraries
        String errorMsgBrokenLib = "";
        try {
            loadLibraries();
            mBrokenLibraries = false; /* success */
        } catch(UnsatisfiedLinkError e) {
            System.err.println(e.getMessage());
            mBrokenLibraries = true;
            errorMsgBrokenLib = e.getMessage();
        } catch(Exception e) {
            System.err.println(e.getMessage());
            mBrokenLibraries = true;
            errorMsgBrokenLib = e.getMessage();
        }

        if (!mBrokenLibraries) {
            String expected_version = String.valueOf(SDL_MAJOR_VERSION) + "." +
                                      String.valueOf(SDL_MINOR_VERSION) + "." +
                                      String.valueOf(SDL_MICRO_VERSION);
            String version = nativeGetVersion();
            if (!version.equals(expected_version)) {
                mBrokenLibraries = true;
                errorMsgBrokenLib = "SDL C/Java version mismatch (expected " + expected_version + ", got " + version + ")";
            }
        }

        if (mBrokenLibraries) {
            mSingleton = this;
            AlertDialog.Builder dlgAlert  = new AlertDialog.Builder(this);
            dlgAlert.setMessage("An error occurred while trying to start the application. Please try again and/or reinstall."
                  + System.getProperty("line.separator")
                  + System.getProperty("line.separator")
                  + "Error: " + errorMsgBrokenLib);
            dlgAlert.setTitle("SDL Error");
            dlgAlert.setPositiveButton("Exit",
                new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog,int id) {
                        // if this button is clicked, close current activity
                        SDLActivity.mSingleton.finish();
                    }
                });
           dlgAlert.setCancelable(false);
           dlgAlert.create().show();

           return;
        }

        // Set up JNI
        SDL.setupJNI();

        // Initialize state
        SDL.initialize();

        // DosBoxX: never expose the accelerometer as an SDL joystick. In
        // joystick mode DOSBox grabs the first SDL joystick, and a phone lying
        // flat reads gravity as a permanently-held direction.
        nativeSetenv("SDL_ACCELEROMETER_AS_JOYSTICK", "0");

        // So we can call stuff from static callbacks
        mSingleton = this;
        SDL.setContext(this);

        mClipboardHandler = new SDLClipboardHandler();

        mHIDDeviceManager = HIDDeviceManager.acquire(this);

        // Set up the surface
        mSurface = createSDLSurface(this);

        mLayout = new RelativeLayout(this);
        mLayout.addView(mSurface);

        // Get our current screen orientation and pass it down.
        mCurrentOrientation = SDLActivity.getCurrentOrientation();
        // Only record current orientation
        SDLActivity.onNativeOrientationChanged(mCurrentOrientation);

        try {
            if (Build.VERSION.SDK_INT < 24 /* Android 7.0 (N) */) {
                mCurrentLocale = getContext().getResources().getConfiguration().locale;
            } else {
                mCurrentLocale = getContext().getResources().getConfiguration().getLocales().get(0);
            }
        } catch(Exception ignored) {
        }

        setContentView(mLayout);

        /* DosBoxX: mark an emulator session as running, so the launcher
         * forwards back here (resuming the guest) instead of showing the
         * games list when the app is re-opened after being minimized. */
        try { new java.io.File(getExternalFilesDir(null), ".emu_running").createNewFile(); }
        catch (Exception ignored) { }

        /* DosBoxX: the launcher sets sTrackpadMouse before starting us, but
         * that static dies with the process (e.g. relaunch from recents).
         * Re-derive it from the conf we are about to run: a `boot` line means
         * a Windows guest, which needs the trackpad mouse. */
        try {
            java.io.File conf = new java.io.File(getExternalFilesDir(null), "dosbox-x.conf");
            if (conf.isFile()) {
                byte[] buf = new byte[(int) conf.length()];
                java.io.FileInputStream in = new java.io.FileInputStream(conf);
                try { in.read(buf); } finally { in.close(); }
                String s = new String(buf, "US-ASCII");
                if (s.contains("\nboot ")) setTrackpadMouse(true);
                // The D: imgmount line carries one quoted path per disc in
                // the changer — its order IS the Ctrl+F4 swap order, so the
                // disc picker can jump to any disc by name.
                sCdNames.clear();
                for (String line : s.split("\n")) {
                    if (!line.startsWith("imgmount d")) continue;
                    sCdNames.clear();
                    int i = 0;
                    while (true) {
                        int q1 = line.indexOf('"', i); if (q1 < 0) break;
                        int q2 = line.indexOf('"', q1 + 1); if (q2 < 0) break;
                        String p = line.substring(q1 + 1, q2);
                        int slash = p.lastIndexOf('/');
                        String base = slash >= 0 ? p.substring(slash + 1) : p;
                        int dot = base.lastIndexOf('.');
                        sCdNames.add(dot > 0 ? base.substring(0, dot) : base);
                        i = q2 + 1;
                    }
                }
            }
        } catch (Exception ignored) { }

        /* DosBoxX: we run in our own :emu process, so the launcher's static
         * setters never reach us — load the per-game keymap and joystick mode
         * ourselves from the game name in the launch intent. */
        try {
            String game = getIntent() != null ? getIntent().getStringExtra(EXTRA_GAME_NAME) : null;
            if (game != null && !game.isEmpty()) {
                setKeyMap(com.dosboxx.app.KeyMapStore.load(this, game));
                setJoystickMode(com.dosboxx.app.KeyMapStore.loadJoystickMode(this, game));
                setStickMouseMode(com.dosboxx.app.KeyMapStore.loadStickMouseMode(this, game));
            }
        } catch (Exception ignored) { }

        setupDosKeyboardOverlay();

        setWindowStyle(false);

        getWindow().getDecorView().setOnSystemUiVisibilityChangeListener(this);

        // Get filename from "Open with" of another application
        Intent intent = getIntent();
        if (intent != null && intent.getData() != null) {
            String filename = intent.getData().getPath();
            if (filename != null) {
                Log.v(TAG, "Got filename: " + filename);
                SDLActivity.onNativeDropFile(filename);
            }
        }
    }

    protected void pauseNativeThread() {
        mNextNativeState = NativeState.PAUSED;
        mIsResumedCalled = false;

        if (SDLActivity.mBrokenLibraries) {
            return;
        }

        SDLActivity.handleNativeState();
    }

    protected void resumeNativeThread() {
        mNextNativeState = NativeState.RESUMED;
        mIsResumedCalled = true;

        if (SDLActivity.mBrokenLibraries) {
           return;
        }

        SDLActivity.handleNativeState();
    }

    // Events
    @Override
    protected void onPause() {
        Log.v(TAG, "onPause()");
        super.onPause();

        if (mHIDDeviceManager != null) {
            mHIDDeviceManager.setFrozen(true);
        }
        if (!mHasMultiWindow) {
            pauseNativeThread();
        }
    }

    @Override
    protected void onResume() {
        Log.v(TAG, "onResume()");
        super.onResume();

        if (mHIDDeviceManager != null) {
            mHIDDeviceManager.setFrozen(false);
        }
        if (!mHasMultiWindow) {
            resumeNativeThread();
        }
    }

    @Override
    protected void onStop() {
        Log.v(TAG, "onStop()");
        super.onStop();
        if (mHasMultiWindow) {
            pauseNativeThread();
        }
    }

    @Override
    protected void onStart() {
        Log.v(TAG, "onStart()");
        super.onStart();
        if (mHasMultiWindow) {
            resumeNativeThread();
        }
    }

    public static int getCurrentOrientation() {
        int result = SDL_ORIENTATION_UNKNOWN;

        Activity activity = (Activity)getContext();
        if (activity == null) {
            return result;
        }
        Display display = activity.getWindowManager().getDefaultDisplay();

        switch (display.getRotation()) {
            case Surface.ROTATION_0:
                result = SDL_ORIENTATION_PORTRAIT;
                break;

            case Surface.ROTATION_90:
                result = SDL_ORIENTATION_LANDSCAPE;
                break;

            case Surface.ROTATION_180:
                result = SDL_ORIENTATION_PORTRAIT_FLIPPED;
                break;

            case Surface.ROTATION_270:
                result = SDL_ORIENTATION_LANDSCAPE_FLIPPED;
                break;
        }

        return result;
    }

    /** Intent extra: the game name, so this process can reload its keymap. */
    public static final String EXTRA_GAME_NAME = "dosboxx.gameName";

    /** Graceful Windows shutdown: drive Start → Shut Down... → OK with
     *  injected keys, give the guest time to flush (the "safe to turn off"
     *  screen), then leave. Keeps the image clean — no ScanDisk next boot. */
    private void shutdownWindowsThenExit() {
        android.widget.Toast.makeText(this,
            "Shutting down Windows — returning to the games list…",
            android.widget.Toast.LENGTH_LONG).show();
        final android.os.Handler h = new android.os.Handler(android.os.Looper.getMainLooper());
        h.postDelayed(new Runnable() {   // Ctrl+Esc: open the Start menu
            @Override public void run() {
                onNativeKeyDown(KeyEvent.KEYCODE_CTRL_LEFT);
                onNativeKeyDown(KeyEvent.KEYCODE_ESCAPE);
                onNativeKeyUp(KeyEvent.KEYCODE_ESCAPE);
                onNativeKeyUp(KeyEvent.KEYCODE_CTRL_LEFT);
            }
        }, 200);
        h.postDelayed(new Runnable() {   // U: "Shut Down..."
            @Override public void run() {
                onNativeKeyDown(KeyEvent.KEYCODE_U);
                onNativeKeyUp(KeyEvent.KEYCODE_U);
            }
        }, 1200);
        h.postDelayed(new Runnable() {   // Enter: confirm "Shut down"
            @Override public void run() {
                onNativeKeyDown(KeyEvent.KEYCODE_ENTER);
                onNativeKeyUp(KeyEvent.KEYCODE_ENTER);
            }
        }, 2400);
        // Win98 takes a few seconds to write everything out and park on the
        // "It's now safe to turn off your computer" screen.
        h.postDelayed(new Runnable() {
            @Override public void run() { exitToLauncher(); }
        }, 25000);
    }

    /** Quit to the games list. finish() alone isn't enough: onDestroy joins
     *  the SDL thread with no timeout and a guest OS can ignore SDL's quit
     *  event, so a watchdog thread guarantees the :emu process dies — the
     *  launcher lives in the main process and survives untouched. */
    private void exitToLauncher() {
        // Clear the session marker first so the launcher doesn't forward back
        // here while this process is being torn down.
        try { new java.io.File(getExternalFilesDir(null), ".emu_running").delete(); }
        catch (Exception ignored) { }
        new Thread(new Runnable() {
            @Override public void run() {
                try { Thread.sleep(400); } catch (InterruptedException ignored) { }
                android.os.Process.killProcess(android.os.Process.myPid());
            }
        }).start();
        try { finishAndRemoveTask(); } catch (Throwable t) { finish(); }
    }

    // ---- DosBoxX on-screen PC keyboard overlay ----
    private android.widget.LinearLayout mDosKeyPanel;
    private android.widget.LinearLayout mDosCursorPanel;
    // Keys are weight-sized so every row stretches edge-to-edge across the
    // device; compact heights + translucency keep the game visible behind.
    private int mDosKeyH = 60;
    private float mDosKeyTextSp = 18f;
    private int mDosKeyBg = 0xD8383838;

    /** Build a small toggle button + a full PC keyboard laid out like the
     * real thing (staggered rows, wide Backspace/Enter/Shift/Space) that
     * injects real key events into DOS. Always the full layout — every game
     * and the Win98 guest get all keys; rows fill the device width. */
    private void setupDosKeyboardOverlay() {
        final float d = getResources().getDisplayMetrics().density;
        final int pad = (int)(4*d);

        // Container pinned to the bottom by default; rows are weight-distributed.
        // The user can drag the handle bar at the top of the panel to move it
        // anywhere on screen (handy when a text field sits at the bottom and
        // the keyboard would cover it). Long-press the handle to snap back
        // to the bottom. While dragging, the per-key touch listeners stay
        // active (touch events still hit the buttons), so keys remain
        // responsive when the panel is in its new position.
        mDosKeyPanel = new android.widget.LinearLayout(this);
        mDosKeyPanel.setOrientation(android.widget.LinearLayout.VERTICAL);
        mDosKeyPanel.setBackgroundColor(0x90202020);
        mDosKeyPanel.setVisibility(View.GONE);

        // Thin drag-handle bar above the keys. The bar itself is the grab
        // target; below it the row of keys is unaffected.
        android.widget.LinearLayout handle = new android.widget.LinearLayout(this);
        handle.setOrientation(android.widget.LinearLayout.HORIZONTAL);
        handle.setGravity(android.view.Gravity.CENTER);
        handle.setBackgroundColor(0x60505050);
        android.widget.TextView grip = new android.widget.TextView(this);
        grip.setText("≡  drag to move · long-press to snap bottom");
        grip.setTextColor(0xFFE0E0E0);
        grip.setTextSize(8f);
        android.widget.LinearLayout.LayoutParams gripLp =
            new android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT);
        gripLp.gravity = android.view.Gravity.CENTER;
        handle.addView(grip, gripLp);
        android.widget.LinearLayout.LayoutParams handleLp =
            new android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
                (int)(14*d));
        mDosKeyPanel.addView(handle, handleLp);
        attachKeyboardDragHandler(handle);

        // The main (typewriter) block sums to about 15 weight units per row.
        // The arrow/navigation cluster is a separate floating pad so the
        // letter/number keys can use the full screen width.
        {
            // Row 1: ESC + function keys (main subtotal 13 -> pad to 15)
            android.widget.LinearLayout row1 = newDosKeyRow();
            addDosKey(row1, "ESC", 111, false, 1f);
            for (int i=1;i<=12;i++) addDosKey(row1, "F"+i, 130+i, false, 1f); // F1=131..F12=142

            android.widget.LinearLayout num = newDosKeyRow();
            addDosKey(num, "`", 68, false, 1f);
            int[] numKeys = {8,9,10,11,12,13,14,15,16,7};   // KEYCODE_1..9, 0
            String[] numLabels = {"1","2","3","4","5","6","7","8","9","0"};
            for (int i = 0; i < numKeys.length; i++) addDosKey(num, numLabels[i], numKeys[i], false, 1f);
            addDosKey(num, "-", 69, false, 1f);
            addDosKey(num, "=", 70, false, 1f);
            addDosKey(num, "BKSP", 67, false, 2f);

            android.widget.LinearLayout top = newDosKeyRow();
            addDosKey(top, "TAB", 61, false, 1.5f);
            int[] topKeys = {45,51,33,46,48,53,49,37,43,44};        // Q W E R T Y U I O P
            String[] topLabels = {"Q","W","E","R","T","Y","U","I","O","P"};
            for (int i = 0; i < topKeys.length; i++) addDosKey(top, topLabels[i], topKeys[i], false, 1f);
            addDosKey(top, "[", 71, false, 1f);
            addDosKey(top, "]", 72, false, 1f);
            addDosKey(top, "\\", 73, false, 1.5f);

            android.widget.LinearLayout home = newDosKeyRow();
            addDosKey(home, "CAPS", 115, false, 1.75f);
            int[] homeKeys = {29,47,32,34,35,36,38,39,40};          // A S D F G H J K L
            String[] homeLabels = {"A","S","D","F","G","H","J","K","L"};
            for (int i = 0; i < homeKeys.length; i++) addDosKey(home, homeLabels[i], homeKeys[i], false, 1f);
            addDosKey(home, ";", 74, false, 1f);
            addDosKey(home, "'", 75, false, 1f);
            addDosKey(home, "ENTER", 66, false, 2.25f);

            android.widget.LinearLayout bot = newDosKeyRow();
            addDosKey(bot, "SHIFT", 59, true, 2.25f);   // latching modifier
            int[] botKeys = {54,52,31,50,30,42,41};                 // Z X C V B N M
            String[] botLabels = {"Z","X","C","V","B","N","M"};
            for (int i = 0; i < botKeys.length; i++) addDosKey(bot, botLabels[i], botKeys[i], false, 1f);
            addDosKey(bot, ",", 55, false, 1f);
            addDosKey(bot, ".", 56, false, 1f);
            addDosKey(bot, "/", 76, false, 1f);
            addDosKey(bot, "SHIFT", 60, true, 2.75f);   // latching modifier

            android.widget.LinearLayout sp = newDosKeyRow();
            addDosKey(sp, "CTRL", 113, true, 1.5f);     // latching modifier
            addDosKey(sp, "ALT", 57, true, 1.5f);       // latching modifier
            addDosKey(sp, "SPACE", 62, false, 12f);
        }

        // Default position: pinned to the bottom (the initial state before
        // the user has dragged it). The drag handler removes the
        // ALIGN_PARENT_BOTTOM rule on first move and switches to explicit
        // leftMargin/topMargin from then on.
        RelativeLayout.LayoutParams plp = new RelativeLayout.LayoutParams(
            RelativeLayout.LayoutParams.MATCH_PARENT, RelativeLayout.LayoutParams.WRAP_CONTENT);
        plp.addRule(RelativeLayout.ALIGN_PARENT_BOTTOM);
        mLayout.addView(mDosKeyPanel, plp);

        buildCursorPad(d);

        // Keyboard toggle — top-left.
        android.widget.Button toggle = new android.widget.Button(this);
        toggle.setText("⌨");           // keyboard glyph
        toggle.setTextColor(0xFFFFFFFF);
        toggle.setBackgroundColor(0xA0303030);
        toggle.setPadding(pad,pad,pad,pad);
        RelativeLayout.LayoutParams tlp = new RelativeLayout.LayoutParams(
            (int)(48*d), (int)(40*d));
        tlp.addRule(RelativeLayout.ALIGN_PARENT_TOP);
        tlp.addRule(RelativeLayout.ALIGN_PARENT_LEFT);
        toggle.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                boolean show = mDosKeyPanel.getVisibility() != View.VISIBLE;
                mDosKeyPanel.setVisibility(show ? View.VISIBLE : View.GONE);
                if (mDosCursorPanel != null) {
                    mDosCursorPanel.setVisibility(show ? View.VISIBLE : View.GONE);
                }
                showOverlayButtons();
            }
        });
        mLayout.addView(toggle, tlp);
        mOverlayButtons.add(toggle);

        // Disc picker (2+ discs mounted): the swap set is fixed at boot, but
        // any disc in it can be put in the drive by name. Top-right, left of ✕.
        if (sCdNames.size() >= 2) {
            android.widget.Button cdBtn = new android.widget.Button(this);
            cdBtn.setText("CD▾");
            cdBtn.setTextColor(0xFFFFFFFF);
            cdBtn.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 10);
            cdBtn.setAllCaps(false);
            cdBtn.setBackgroundColor(0xA0303030);
            RelativeLayout.LayoutParams cb = new RelativeLayout.LayoutParams((int)(52*d),(int)(40*d));
            cb.addRule(RelativeLayout.ALIGN_PARENT_TOP);
            cb.addRule(RelativeLayout.ALIGN_PARENT_RIGHT);
            cb.rightMargin = (int)(54*d);   // left of the ✕ button
            cdBtn.setOnClickListener(new View.OnClickListener() {
                @Override public void onClick(View v) { showCdPicker(); }
            });
            mLayout.addView(cdBtn, cb);
            mOverlayButtons.add(cdBtn);
        }

        // Exit: confirm, then back to the games list (kills this :emu process).
        android.widget.Button exitBtn = new android.widget.Button(this);
        exitBtn.setText("✕");
        exitBtn.setTextColor(0xFFFFFFFF);
        exitBtn.setAllCaps(false);
        exitBtn.setBackgroundColor(0xA0303030);
        RelativeLayout.LayoutParams xb = new RelativeLayout.LayoutParams((int)(48*d),(int)(40*d));
        xb.addRule(RelativeLayout.ALIGN_PARENT_TOP);
        xb.addRule(RelativeLayout.ALIGN_PARENT_RIGHT);
        exitBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                if (sTrackpadMouse) {
                    // Booted Windows guest: shut it down properly so the
                    // registry/FAT get flushed (no ScanDisk on next boot).
                    new android.app.AlertDialog.Builder(SDLActivity.this)
                        .setMessage("Return to the games list?")
                        .setPositiveButton("Shut down Windows", new android.content.DialogInterface.OnClickListener() {
                            @Override public void onClick(android.content.DialogInterface dlg, int w) {
                                shutdownWindowsThenExit();
                            }
                        })
                        .setNeutralButton("Force quit", new android.content.DialogInterface.OnClickListener() {
                            @Override public void onClick(android.content.DialogInterface dlg, int w) {
                                exitToLauncher();
                            }
                        })
                        .setNegativeButton("Cancel", null)
                        .show();
                } else {
                    new android.app.AlertDialog.Builder(SDLActivity.this)
                        .setMessage("Quit the game and return to the games list?")
                        .setPositiveButton("Quit", new android.content.DialogInterface.OnClickListener() {
                            @Override public void onClick(android.content.DialogInterface dlg, int w) {
                                exitToLauncher();
                            }
                        })
                        .setNegativeButton("Cancel", null)
                        .show();
                }
            }
        });
        mLayout.addView(exitBtn, xb);
        mOverlayButtons.add(exitBtn);

        showOverlayButtons();   // visible on launch, then auto-hide after 2s
    }

    /** Separate cursor/navigation pad so the main keyboard can keep full-width keys. */
    private void buildCursorPad(final float d) {
        mDosCursorPanel = new android.widget.LinearLayout(this);
        mDosCursorPanel.setOrientation(android.widget.LinearLayout.VERTICAL);
        mDosCursorPanel.setBackgroundColor(0x90202020);
        mDosCursorPanel.setPadding((int)(4*d), (int)(4*d), (int)(4*d), (int)(4*d));
        mDosCursorPanel.setVisibility(View.GONE);

        android.widget.LinearLayout nav = cursorRow();
        addCursorKey(nav, "INS", 124);
        addCursorKey(nav, "HOME", 122);
        addCursorKey(nav, "PGUP", 92);

        android.widget.LinearLayout nav2 = cursorRow();
        addCursorKey(nav2, "DEL", 112);
        addCursorKey(nav2, "END", 123);
        addCursorKey(nav2, "PGDN", 93);

        android.widget.LinearLayout up = cursorRow();
        addCursorGap(up);
        addCursorKey(up, "↑", 19);
        addCursorGap(up);

        android.widget.LinearLayout arrows = cursorRow();
        addCursorKey(arrows, "←", 21);
        addCursorKey(arrows, "↓", 20);
        addCursorKey(arrows, "→", 22);

        RelativeLayout.LayoutParams cp = new RelativeLayout.LayoutParams(
            RelativeLayout.LayoutParams.WRAP_CONTENT, RelativeLayout.LayoutParams.WRAP_CONTENT);
        cp.addRule(RelativeLayout.ALIGN_PARENT_TOP);
        cp.addRule(RelativeLayout.ALIGN_PARENT_RIGHT);
        cp.topMargin = (int)(48*d);
        cp.rightMargin = (int)(8*d);
        mLayout.addView(mDosCursorPanel, cp);
    }

    private android.widget.LinearLayout cursorRow() {
        android.widget.LinearLayout row = new android.widget.LinearLayout(this);
        row.setOrientation(android.widget.LinearLayout.HORIZONTAL);
        mDosCursorPanel.addView(row, new android.widget.LinearLayout.LayoutParams(
            android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
            android.widget.LinearLayout.LayoutParams.WRAP_CONTENT));
        return row;
    }

    private void addCursorGap(android.widget.LinearLayout row) {
        final float d = getResources().getDisplayMetrics().density;
        View gap = new View(this);
        row.addView(gap, new android.widget.LinearLayout.LayoutParams((int)(56*d), (int)(56*d)));
    }

    private void addCursorKey(android.widget.LinearLayout row, String label, final int keycode) {
        final float d = getResources().getDisplayMetrics().density;
        final android.widget.Button b = new android.widget.Button(this);
        b.setText(label);
        b.setTextColor(0xFFE0E0E0);
        b.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 14f);
        b.setAllCaps(false);
        b.setBackgroundColor(mDosKeyBg);
        b.setPadding((int)(2*d), 0, (int)(2*d), 0);
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        android.widget.LinearLayout.LayoutParams lp =
            new android.widget.LinearLayout.LayoutParams((int)(56*d), (int)(56*d));
        lp.setMargins((int)(2*d), (int)(2*d), (int)(2*d), (int)(2*d));
        b.setLayoutParams(lp);
        b.setOnTouchListener(new View.OnTouchListener() {
            @Override public boolean onTouch(View v, android.view.MotionEvent e) {
                switch (e.getActionMasked()) {
                    case android.view.MotionEvent.ACTION_DOWN:
                        SDLActivity.onNativeKeyDown(keycode); v.setPressed(true); return true;
                    case android.view.MotionEvent.ACTION_UP:
                    case android.view.MotionEvent.ACTION_CANCEL:
                        SDLActivity.onNativeKeyUp(keycode); v.setPressed(false); return true;
                }
                return false;
            }
        });
        row.addView(b);
    }

    /** Make the keyboard draggable via its handle bar. The handle is the
     *  strip at the top of {@link #mDosKeyPanel}; pressing-and-dragging on
     *  the keys themselves must keep typing (those listeners are
     *  attached to each button), so the drag is isolated to the handle. */
    private void attachKeyboardDragHandler(View handle) {
        final float[] downXY = new float[2];
        final boolean[] everMoved = new boolean[1];
        final boolean[] snapped = new boolean[1];   // true once user has dragged at all
        handle.setOnTouchListener(new View.OnTouchListener() {
            @Override public boolean onTouch(View v, android.view.MotionEvent ev) {
                RelativeLayout.LayoutParams lp =
                    (RelativeLayout.LayoutParams) mDosKeyPanel.getLayoutParams();
                switch (ev.getActionMasked()) {
                    case android.view.MotionEvent.ACTION_DOWN:
                        downXY[0] = ev.getRawX();
                        downXY[1] = ev.getRawY();
                        everMoved[0] = false;
                        return true;
                    case android.view.MotionEvent.ACTION_MOVE: {
                        float dx = ev.getRawX() - downXY[0];
                        float dy = ev.getRawY() - downXY[1];
                        // Ignore jittery touches (less than 6 px in either axis)
                        // so a tap on the handle doesn't shift the panel.
                        if (!everMoved[0] && Math.abs(dx) < 6 && Math.abs(dy) < 6) {
                            return true;
                        }
                        everMoved[0] = true;
                        // First move: drop the bottom-pinned rule and switch
                        // to explicit margins. After this, leftMargin /
                        // topMargin drive the position.
                        if (!snapped[0]) {
                            lp.addRule(RelativeLayout.ALIGN_PARENT_BOTTOM, 0);
                            // Seed the margins from wherever the panel
                            // currently is, so the drag is continuous
                            // rather than jumping to (0, 0).
                            int[] loc = new int[2];
                            mDosKeyPanel.getLocationOnScreen(loc);
                            lp.leftMargin = loc[0];
                            lp.topMargin = loc[1];
                            snapped[0] = true;
                        }
                        int parentW = mLayout.getWidth();
                        int parentH = mLayout.getHeight();
                        int panelW = mDosKeyPanel.getWidth();
                        int panelH = mDosKeyPanel.getHeight();
                        if (parentW <= 0 || parentH <= 0 || panelW <= 0 || panelH <= 0) {
                            return true;     // layout not settled yet
                        }
                        int newLeft = lp.leftMargin + (int) dx;
                        int newTop  = lp.topMargin  + (int) dy;
                        // Clamp so the panel stays fully on screen.
                        newLeft = Math.max(0, Math.min(newLeft, parentW - panelW));
                        newTop  = Math.max(0, Math.min(newTop,  parentH - panelH));
                        lp.leftMargin = newLeft;
                        lp.topMargin  = newTop;
                        mDosKeyPanel.setLayoutParams(lp);
                        downXY[0] = ev.getRawX();
                        downXY[1] = ev.getRawY();
                        return true;
                    }
                    case android.view.MotionEvent.ACTION_UP:
                    case android.view.MotionEvent.ACTION_CANCEL:
                        // A pure tap on the handle is a no-op (a touch on
                        // the handle is not meaningful to the user).
                        return true;
                }
                return false;
            }
        });
        handle.setOnLongClickListener(new View.OnLongClickListener() {
            @Override public boolean onLongClick(View v) {
                // Snap back to the bottom — clear explicit margins and
                // re-add the ALIGN_PARENT_BOTTOM rule. Convenient when the
                // user has dragged it somewhere awkward.
                RelativeLayout.LayoutParams lp =
                    (RelativeLayout.LayoutParams) mDosKeyPanel.getLayoutParams();
                lp.leftMargin = 0;
                lp.topMargin = 0;
                lp.addRule(RelativeLayout.ALIGN_PARENT_BOTTOM);
                mDosKeyPanel.setLayoutParams(lp);
                snapped[0] = false;
                return true;
            }
        });
    }

    // ---- auto-hiding overlay buttons (⌨ / CD▾ / ✕) for a clean "cursor only"
    //      view: they fade out 2s after a touch and reappear on the next touch.
    private final java.util.List<View> mOverlayButtons = new java.util.ArrayList<>();
    private final android.os.Handler mOverlayHandler =
        new android.os.Handler(android.os.Looper.getMainLooper());
    private final Runnable mHideOverlays = new Runnable() {
        @Override public void run() {
            // Keep them up while the on-screen keyboard is open.
            if ((mDosKeyPanel != null && mDosKeyPanel.getVisibility() == View.VISIBLE)
                    || (mDosCursorPanel != null && mDosCursorPanel.getVisibility() == View.VISIBLE)) {
                showOverlayButtons();
                return;
            }
            for (View b : mOverlayButtons) {
                b.animate().alpha(0f).setDuration(250).withEndAction(() -> b.setVisibility(View.GONE));
            }
        }
    };

    /** Reveal the overlay buttons and (re)start the 2-second hide timer. */
    private void showOverlayButtons() {
        for (View b : mOverlayButtons) {
            b.animate().cancel();
            b.setVisibility(View.VISIBLE);
            b.setAlpha(1f);
        }
        mOverlayHandler.removeCallbacks(mHideOverlays);
        mOverlayHandler.postDelayed(mHideOverlays, 2000);
    }

    @Override
    public boolean dispatchTouchEvent(android.view.MotionEvent ev) {
        if (ev.getActionMasked() == android.view.MotionEvent.ACTION_DOWN
                && !mOverlayButtons.isEmpty()) {
            showOverlayButtons();   // reveal on touch; event still passes through
        }
        return super.dispatchTouchEvent(ev);
    }

    /** Append the right-hand nav cluster to a row: a spacer padding the main
     *  block out to 15 units (so clusters line up across rows) + a separator,
     *  then 3 columns that are each a key (label+code) or, if label==null, a
     *  blank spacer of equal width. Keeps every row the same total width. */
    private void navCluster(android.widget.LinearLayout row, float mainWeight,
                            String l1, int c1, String l2, int c2, String l3, int c3) {
        final float NW = 1.3f;
        addDosGap(row, (15f - mainWeight) + 0.5f);   // fill to 15 + separator
        navCell(row, l1, c1, NW);
        navCell(row, l2, c2, NW);
        navCell(row, l3, c3, NW);
    }

    private void navCell(android.widget.LinearLayout row, String label, int code, float w) {
        if (label == null) addDosGap(row, w);
        else                addDosKey(row, label, code, false, w);
    }

    private void addDosGap(android.widget.LinearLayout row, float weight) {
        View s = new View(this);
        s.setLayoutParams(new android.widget.LinearLayout.LayoutParams(0, 1, weight));
        row.addView(s);
    }

    /** New full-width keyboard row appended to the panel. */
    private android.widget.LinearLayout newDosKeyRow() {
        android.widget.LinearLayout row = new android.widget.LinearLayout(this);
        row.setOrientation(android.widget.LinearLayout.HORIZONTAL);
        mDosKeyPanel.addView(row, new android.widget.LinearLayout.LayoutParams(
            android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
            android.widget.LinearLayout.LayoutParams.WRAP_CONTENT));
        return row;
    }

    /** Add a key sized by layout weight — rows share the full device width,
     *  so weights reproduce a real keyboard's stagger (e.g. Shift = 2.25). */
    private void addDosKey(android.widget.LinearLayout row, String label, final int keycode,
                           final boolean modifier, float weight) {
        final float d = getResources().getDisplayMetrics().density;
        final android.widget.Button b = new android.widget.Button(this);
        b.setText(label);
        b.setTextColor(0xFFE0E0E0);
        b.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, mDosKeyTextSp);
        b.setAllCaps(false);
        b.setBackgroundColor(mDosKeyBg);
        b.setPadding((int)(2*d),0,(int)(2*d),0);
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        android.widget.LinearLayout.LayoutParams lp =
            new android.widget.LinearLayout.LayoutParams(0, (int)(mDosKeyH*d), weight);
        lp.setMargins((int)(1*d),(int)(1*d),(int)(1*d),(int)(1*d));
        b.setLayoutParams(lp);
        if (modifier) {
            // latch: tap toggles the held state so combos like Ctrl+C work
            final boolean[] held = { false };
            b.setOnClickListener(new View.OnClickListener() {
                @Override public void onClick(View v) {
                    held[0] = !held[0];
                    if (held[0]) { SDLActivity.onNativeKeyDown(keycode); b.setBackgroundColor(0xFF1565C0); }
                    else { SDLActivity.onNativeKeyUp(keycode); b.setBackgroundColor(mDosKeyBg); }
                }
            });
        } else {
            b.setOnTouchListener(new View.OnTouchListener() {
                @Override public boolean onTouch(View v, android.view.MotionEvent e) {
                    switch (e.getActionMasked()) {
                        case android.view.MotionEvent.ACTION_DOWN:
                            SDLActivity.onNativeKeyDown(keycode); v.setPressed(true); return true;
                        case android.view.MotionEvent.ACTION_UP:
                        case android.view.MotionEvent.ACTION_CANCEL:
                            SDLActivity.onNativeKeyUp(keycode); v.setPressed(false); return true;
                    }
                    return false;
                }
            });
        }
        row.addView(b);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        Log.v(TAG, "onWindowFocusChanged(): " + hasFocus);

        if (SDLActivity.mBrokenLibraries) {
           return;
        }

        mHasFocus = hasFocus;
        if (hasFocus) {
           mNextNativeState = NativeState.RESUMED;
           SDLActivity.getMotionListener().reclaimRelativeMouseModeIfNeeded();

           SDLActivity.handleNativeState();
           nativeFocusChanged(true);

           /* DosBoxX: force immersive fullscreen so the DOS output uses the whole
            * screen (no status/nav bar overlap), like the DOSBox desktop window. */
           try {
               final android.view.Window w = getWindow();
               w.getDecorView().setSystemUiVisibility(
                   View.SYSTEM_UI_FLAG_FULLSCREEN |
                   View.SYSTEM_UI_FLAG_HIDE_NAVIGATION |
                   View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY |
                   View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN |
                   View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION |
                   View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
               w.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
               w.clearFlags(WindowManager.LayoutParams.FLAG_FORCE_NOT_FULLSCREEN);
           } catch (Exception e) { /* ignore */ }

        } else {
           nativeFocusChanged(false);
           if (!mHasMultiWindow) {
               mNextNativeState = NativeState.PAUSED;
               SDLActivity.handleNativeState();
           }
        }
    }

    @Override
    public void onLowMemory() {
        Log.v(TAG, "onLowMemory()");
        super.onLowMemory();

        if (SDLActivity.mBrokenLibraries) {
           return;
        }

        SDLActivity.nativeLowMemory();
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        Log.v(TAG, "onConfigurationChanged()");
        super.onConfigurationChanged(newConfig);

        if (SDLActivity.mBrokenLibraries) {
           return;
        }

        if (mCurrentLocale == null || !mCurrentLocale.equals(newConfig.locale)) {
            mCurrentLocale = newConfig.locale;
            SDLActivity.onNativeLocaleChanged();
        }
    }

    @Override
    protected void onDestroy() {
        Log.v(TAG, "onDestroy()");

        if (mHIDDeviceManager != null) {
            HIDDeviceManager.release(mHIDDeviceManager);
            mHIDDeviceManager = null;
        }

        SDLAudioManager.release(this);

        if (SDLActivity.mBrokenLibraries) {
           super.onDestroy();
           return;
        }

        if (SDLActivity.mSDLThread != null) {

            // Send Quit event to "SDLThread" thread
            SDLActivity.nativeSendQuit();

            // Wait for "SDLThread" thread to end
            try {
                SDLActivity.mSDLThread.join();
            } catch(Exception e) {
                Log.v(TAG, "Problem stopping SDLThread: " + e);
            }
        }

        SDLActivity.nativeQuit();

        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        // Check if we want to block the back button in case of mouse right click.
        //
        // If we do, the normal hardware back button will no longer work and people have to use home,
        // but the mouse right click will work.
        //
        boolean trapBack = SDLActivity.nativeGetHintBoolean("SDL_ANDROID_TRAP_BACK_BUTTON", false);
        if (trapBack) {
            // Exit and let the mouse handler handle this button (if appropriate)
            return;
        }

        // Default system back button behavior.
        if (!isFinishing()) {
            super.onBackPressed();
        }
    }

    // Called by JNI from SDL.
    public static void manualBackButton() {
        mSingleton.pressBackButton();
    }

    // Used to get us onto the activity's main thread
    public void pressBackButton() {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (!SDLActivity.this.isFinishing()) {
                    SDLActivity.this.superOnBackPressed();
                }
            }
        });
    }

    // Used to access the system back behavior.
    public void superOnBackPressed() {
        super.onBackPressed();
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {

        if (SDLActivity.mBrokenLibraries) {
           return false;
        }

        int keyCode = event.getKeyCode();

        // DosBoxX: map the physical gamepad's BUTTONS to keyboard keys so they
        // work in DOS games and in menus (sticks stay as the analog DOS joystick,
        // handled via MotionEvents/SDL). START=Enter, BACK/SELECT=Esc, A=fire,
        // B=jump, X=use, Y=run, L1/R1=fire/jump, Dpad=arrows.
        // In per-game joystick mode the pad is NOT translated — events fall
        // through to SDL's controller path and reach DOS as a real joystick.
        if (!sJoystickMode) {
            int mapped = SDLActivity.mapGamepadButtonToKey(keyCode);
            if (mapped != 0) {
                int action = event.getAction();
                if (isMouseTarget(mapped)) {
                    int mouseButton = mapped == com.dosboxx.app.KeyMapStore.TARGET_MOUSE_RIGHT ? 3 : 1;
                    if (action == KeyEvent.ACTION_DOWN || action == KeyEvent.ACTION_UP) {
                        SDLActivity.onNativeMouse(mouseButton, action, 0, 0, true);
                    }
                } else if (action == KeyEvent.ACTION_DOWN) {
                    SDLActivity.onNativeKeyDown(mapped);
                } else if (action == KeyEvent.ACTION_UP) {
                    SDLActivity.onNativeKeyUp(mapped);
                }
                return true;
            }
        }

        // DosBoxX: BACK button -> Escape (menu "back"). The on-screen keyboard is
        // toggled with the on-screen keyboard button instead.
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            if (event.getAction() == KeyEvent.ACTION_DOWN)    SDLActivity.onNativeKeyDown(KeyEvent.KEYCODE_ESCAPE);
            else if (event.getAction() == KeyEvent.ACTION_UP) SDLActivity.onNativeKeyUp(KeyEvent.KEYCODE_ESCAPE);
            return true;
        }
        // Ignore certain special keys so they're handled by Android
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN ||
            keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
            keyCode == KeyEvent.KEYCODE_CAMERA ||
            keyCode == KeyEvent.KEYCODE_ZOOM_IN || /* API 11 */
            keyCode == KeyEvent.KEYCODE_ZOOM_OUT /* API 11 */
            ) {
            return false;
        }
        return super.dispatchKeyEvent(event);
    }

    /* Left-thumbstick -> arrow keys. The DOS gameport joystick is unreliable
     * (needs calibration, only move+turn), so we translate the analog stick to
     * keyboard arrows ourselves: up/down = forward/back, left/right = turn. */
    private final boolean[] mStickKeyDown = new boolean[4]; // up, down, left, right
    // Canonical button names for the four directions; STICK_KEYCODES is now
    // resolved at runtime so the analog stick honors the user's keymap.
    private static final String[] STICK_BUTTONS = {
        "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT"
    };
    private static final int[] STICK_FALLBACKS = {
        KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN,
        KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT
    };

    @Override
    public boolean dispatchGenericMotionEvent(android.view.MotionEvent event) {
        if (!sJoystickMode
                && (event.getSource() & InputDevice.SOURCE_JOYSTICK) != 0
                && event.getAction() == android.view.MotionEvent.ACTION_MOVE) {
            float lx = event.getAxisValue(android.view.MotionEvent.AXIS_X);
            float ly = event.getAxisValue(android.view.MotionEvent.AXIS_Y);
            // fold in the right stick for turning (X) so either stick can aim
            float rx = event.getAxisValue(android.view.MotionEvent.AXIS_Z);
            if (Math.abs(rx) > Math.abs(lx)) lx = rx;
            if (sStickMouseMode) {
                final float dz = 0.16f;
                float mx = Math.abs(lx) > dz ? lx * 18f : 0f;
                float my = Math.abs(ly) > dz ? ly * 18f : 0f;
                if (mx != 0f || my != 0f) SDLActivity.onNativeMouse(0, android.view.MotionEvent.ACTION_MOVE, mx, my, true);
                releaseStickKeys();
                return true;
            }
            final float dz = 0.35f;
            boolean[] want = new boolean[4];
            want[0] = ly < -dz;   // up    -> forward
            want[1] = ly >  dz;   // down  -> back
            want[2] = lx < -dz;   // left  -> turn left
            want[3] = lx >  dz;   // right -> turn right
            for (int i = 0; i < 4; i++) {
                int kc = stickKeyFor(STICK_BUTTONS[i], STICK_FALLBACKS[i]);
                if (isMouseTarget(kc)) continue;
                if (want[i] && !mStickKeyDown[i])      { onNativeKeyDown(kc); mStickKeyDown[i] = true; }
                else if (!want[i] && mStickKeyDown[i]) { onNativeKeyUp(kc);   mStickKeyDown[i] = false; }
            }
            return true;
        }
        return super.dispatchGenericMotionEvent(event);
    }

    private void releaseStickKeys() {
        for (int i = 0; i < 4; i++) {
            if (mStickKeyDown[i]) {
                int kc = stickKeyFor(STICK_BUTTONS[i], STICK_FALLBACKS[i]);
                if (!isMouseTarget(kc)) onNativeKeyUp(kc);
                mStickKeyDown[i] = false;
            }
        }
    }

    /** Map a physical gamepad button (Android keycode) to the keyboard key we
     *  inject for DOS games. Returns KEYCODE_UNKNOWN (0) for anything that is
     *  not a mapped gamepad button (so it falls through to normal handling).
     *  The thumbsticks are handled by dispatchGenericMotionEvent below.
     *  If a per-game override was set via setKeyMap, that wins; otherwise
     *  we fall back to the hard-coded defaults below. */
    public static int mapGamepadButtonToKey(int keyCode) {
        String btn = gamepadButtonName(keyCode);
        if (btn != null && sKeyMap != null) {
            Integer v = sKeyMap.get(btn);
            if (v != null) return v.intValue();
        }
        switch (keyCode) {
            case KeyEvent.KEYCODE_BUTTON_START:  return KeyEvent.KEYCODE_ENTER;      // menu select / pause
            case KeyEvent.KEYCODE_BUTTON_SELECT: return KeyEvent.KEYCODE_ESCAPE;     // menu back
            case KeyEvent.KEYCODE_BUTTON_A:      return KeyEvent.KEYCODE_CTRL_LEFT;  // Quake +attack
            case KeyEvent.KEYCODE_BUTTON_B:      return KeyEvent.KEYCODE_SPACE;      // Quake +jump
            case KeyEvent.KEYCODE_BUTTON_X:      return KeyEvent.KEYCODE_ENTER;      // use / confirm
            case KeyEvent.KEYCODE_BUTTON_Y:      return KeyEvent.KEYCODE_TAB;        // scoreboard / map
            case KeyEvent.KEYCODE_BUTTON_L1:     return KeyEvent.KEYCODE_SHIFT_LEFT; // run / speed
            case KeyEvent.KEYCODE_BUTTON_R1:     return KeyEvent.KEYCODE_CTRL_LEFT;  // fire (trigger)
            case KeyEvent.KEYCODE_DPAD_UP:       return KeyEvent.KEYCODE_DPAD_UP;    // menu up / forward
            case KeyEvent.KEYCODE_DPAD_DOWN:     return KeyEvent.KEYCODE_DPAD_DOWN;
            case KeyEvent.KEYCODE_DPAD_LEFT:     return KeyEvent.KEYCODE_DPAD_LEFT;
            case KeyEvent.KEYCODE_DPAD_RIGHT:    return KeyEvent.KEYCODE_DPAD_RIGHT;
            case KeyEvent.KEYCODE_DPAD_CENTER:   return KeyEvent.KEYCODE_ENTER;
            default:                             return KeyEvent.KEYCODE_UNKNOWN;    // 0
        }
    }

    /** GameLauncherActivity calls this before launching SDLActivity so the
     *  mapping honors the user's per-game keymap. The map is keyed by the
     *  canonical button names from com.dosboxx.app.KeyMapStore.BUTTONS. */
    public static void setKeyMap(Map<String, Integer> map) {
        sKeyMap = map;
    }

    /** Per-game joystick mode: when true the gamepad is NOT translated to
     *  keyboard keys — buttons and sticks flow through SDL's controller path
     *  and reach DOS as a real gameport joystick (joysticktype=auto in the
     *  conf). Set by GameLauncherActivity before each launch. */
    public static boolean sJoystickMode = false;
    public static boolean sStickMouseMode = false;

    public static void setJoystickMode(boolean on) {
        sJoystickMode = on;
    }

    public static void setStickMouseMode(boolean on) {
        sStickMouseMode = on;
    }

    private static boolean isMouseTarget(int target) {
        return target == com.dosboxx.app.KeyMapStore.TARGET_MOUSE_LEFT
            || target == com.dosboxx.app.KeyMapStore.TARGET_MOUSE_RIGHT;
    }

    /** Trackpad mouse for booted-OS sessions (Win98): the touch screen acts
     *  as a laptop trackpad — drags send RELATIVE mouse motion (what the
     *  guest's PS/2 driver tracks), tap = left click, two-finger tap = right
     *  click, long-press then move = drag. Absolute finger taps are useless
     *  to Windows guests, whose cursor is drawn by the guest itself. */
    public static boolean sTrackpadMouse = false;

    public static void setTrackpadMouse(boolean on) {
        sTrackpadMouse = on;
    }

    /** Disc names of the swap set, in mount (= Ctrl+F4 cycle) order. */
    public static final java.util.ArrayList<String> sCdNames = new java.util.ArrayList<String>();
    private int mCdIndex = 0;   // which disc is currently in the drive

    /** List the swap set by name; tapping a disc sends however many Ctrl+F4
     *  cycles it takes to put that disc in the drive. */
    private void showCdPicker() {
        final int n = sCdNames.size();
        String[] items = new String[n];
        for (int i = 0; i < n; i++) items[i] = (i == mCdIndex ? "▶ " : "") + sCdNames.get(i);
        new android.app.AlertDialog.Builder(this)
            .setTitle("Insert which disc?")
            .setItems(items, new android.content.DialogInterface.OnClickListener() {
                @Override public void onClick(android.content.DialogInterface d, int which) {
                    swapToDisc(which);
                }
            })
            .show();
    }

    private void swapToDisc(final int target) {
        final int n = sCdNames.size();
        final int steps = ((target - mCdIndex) % n + n) % n;
        if (steps == 0) return;
        mCdIndex = target;
        final android.os.Handler h = new android.os.Handler(android.os.Looper.getMainLooper());
        for (int i = 0; i < steps; i++) {
            // space the swap hotkeys out so the core registers each one
            h.postDelayed(new Runnable() {
                @Override public void run() {
                    onNativeKeyDown(KeyEvent.KEYCODE_CTRL_LEFT);
                    onNativeKeyDown(KeyEvent.KEYCODE_F4);
                    onNativeKeyUp(KeyEvent.KEYCODE_F4);
                    onNativeKeyUp(KeyEvent.KEYCODE_CTRL_LEFT);
                }
            }, i * 350L);
        }
        h.postDelayed(new Runnable() {
            @Override public void run() {
                android.widget.Toast.makeText(SDLActivity.this,
                    "Disc: " + sCdNames.get(target), android.widget.Toast.LENGTH_SHORT).show();
            }
        }, steps * 350L);
    }

    /** Inverse of the canonical-button-name lookup for the thumbstick code. */
    public static int stickKeyFor(String button, int fallback) {
        if (sKeyMap != null) {
            Integer v = sKeyMap.get(button);
            if (v != null) return v.intValue();
        }
        return fallback;
    }

    /** Returns the canonical button name (matching KeyMapStore.BUTTONS) for
     *  an Android keycode, or null for anything that isn't a button we
     *  expose in the editor. */
    private static String gamepadButtonName(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_BUTTON_A:      return "A";
            case KeyEvent.KEYCODE_BUTTON_B:      return "B";
            case KeyEvent.KEYCODE_BUTTON_X:      return "X";
            case KeyEvent.KEYCODE_BUTTON_Y:      return "Y";
            case KeyEvent.KEYCODE_BUTTON_L1:     return "L1";
            case KeyEvent.KEYCODE_BUTTON_R1:     return "R1";
            case KeyEvent.KEYCODE_BUTTON_START:  return "START";
            case KeyEvent.KEYCODE_BUTTON_SELECT: return "SELECT";
            case KeyEvent.KEYCODE_DPAD_UP:       return "DPAD_UP";
            case KeyEvent.KEYCODE_DPAD_DOWN:     return "DPAD_DOWN";
            case KeyEvent.KEYCODE_DPAD_LEFT:     return "DPAD_LEFT";
            case KeyEvent.KEYCODE_DPAD_RIGHT:    return "DPAD_RIGHT";
            case KeyEvent.KEYCODE_DPAD_CENTER:   return "DPAD_CENTER";
            default:                             return null;
        }
    }

    /* Transition to next state */
    public static void handleNativeState() {

        if (mNextNativeState == mCurrentNativeState) {
            // Already in same state, discard.
            return;
        }

        // Try a transition to init state
        if (mNextNativeState == NativeState.INIT) {

            mCurrentNativeState = mNextNativeState;
            return;
        }

        // Try a transition to paused state
        if (mNextNativeState == NativeState.PAUSED) {
            if (mSDLThread != null) {
                nativePause();
            }
            if (mSurface != null) {
                mSurface.handlePause();
            }
            mCurrentNativeState = mNextNativeState;
            return;
        }

        // Try a transition to resumed state
        if (mNextNativeState == NativeState.RESUMED) {
            if (mSurface.mIsSurfaceReady && mHasFocus && mIsResumedCalled) {
                if (mSDLThread == null) {
                    // This is the entry point to the C app.
                    // Start up the C app thread and enable sensor input for the first time
                    // FIXME: Why aren't we enabling sensor input at start?

                    mSDLThread = new Thread(new SDLMain(), "SDLThread");
                    mSurface.enableSensor(Sensor.TYPE_ACCELEROMETER, true);
                    mSDLThread.start();

                    // No nativeResume(), don't signal Android_ResumeSem
                } else {
                    nativeResume();
                }
                mSurface.handleResume();

                mCurrentNativeState = mNextNativeState;
            }
        }
    }

    // Messages from the SDLMain thread
    static final int COMMAND_CHANGE_TITLE = 1;
    static final int COMMAND_CHANGE_WINDOW_STYLE = 2;
    static final int COMMAND_TEXTEDIT_HIDE = 3;
    static final int COMMAND_SET_KEEP_SCREEN_ON = 5;

    protected static final int COMMAND_USER = 0x8000;

    protected static boolean mFullscreenModeActive;

    /**
     * This method is called by SDL if SDL did not handle a message itself.
     * This happens if a received message contains an unsupported command.
     * Method can be overwritten to handle Messages in a different class.
     * @param command the command of the message.
     * @param param the parameter of the message. May be null.
     * @return if the message was handled in overridden method.
     */
    protected boolean onUnhandledMessage(int command, Object param) {
        return false;
    }

    /**
     * A Handler class for Messages from native SDL applications.
     * It uses current Activities as target (e.g. for the title).
     * static to prevent implicit references to enclosing object.
     */
    protected static class SDLCommandHandler extends Handler {
        @Override
        public void handleMessage(Message msg) {
            Context context = SDL.getContext();
            if (context == null) {
                Log.e(TAG, "error handling message, getContext() returned null");
                return;
            }
            switch (msg.arg1) {
            case COMMAND_CHANGE_TITLE:
                if (context instanceof Activity) {
                    ((Activity) context).setTitle((String)msg.obj);
                } else {
                    Log.e(TAG, "error handling message, getContext() returned no Activity");
                }
                break;
            case COMMAND_CHANGE_WINDOW_STYLE:
                if (Build.VERSION.SDK_INT >= 19 /* Android 4.4 (KITKAT) */) {
                    if (context instanceof Activity) {
                        Window window = ((Activity) context).getWindow();
                        if (window != null) {
                            if ((msg.obj instanceof Integer) && ((Integer) msg.obj != 0)) {
                                int flags = View.SYSTEM_UI_FLAG_FULLSCREEN |
                                        View.SYSTEM_UI_FLAG_HIDE_NAVIGATION |
                                        View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY |
                                        View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN |
                                        View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION |
                                        View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.INVISIBLE;
                                window.getDecorView().setSystemUiVisibility(flags);
                                window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
                                window.clearFlags(WindowManager.LayoutParams.FLAG_FORCE_NOT_FULLSCREEN);
                                SDLActivity.mFullscreenModeActive = true;
                            } else {
                                int flags = View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_VISIBLE;
                                window.getDecorView().setSystemUiVisibility(flags);
                                window.addFlags(WindowManager.LayoutParams.FLAG_FORCE_NOT_FULLSCREEN);
                                window.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
                                SDLActivity.mFullscreenModeActive = false;
                            }
                            if (Build.VERSION.SDK_INT >= 28 /* Android 9 (Pie) */) {
                                window.getAttributes().layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
                            }
                        }
                    } else {
                        Log.e(TAG, "error handling message, getContext() returned no Activity");
                    }
                }
                break;
            case COMMAND_TEXTEDIT_HIDE:
                if (mTextEdit != null) {
                    // Note: On some devices setting view to GONE creates a flicker in landscape.
                    // Setting the View's sizes to 0 is similar to GONE but without the flicker.
                    // The sizes will be set to useful values when the keyboard is shown again.
                    mTextEdit.setLayoutParams(new RelativeLayout.LayoutParams(0, 0));

                    InputMethodManager imm = (InputMethodManager) context.getSystemService(Context.INPUT_METHOD_SERVICE);
                    imm.hideSoftInputFromWindow(mTextEdit.getWindowToken(), 0);

                    mScreenKeyboardShown = false;

                    mSurface.requestFocus();
                }
                break;
            case COMMAND_SET_KEEP_SCREEN_ON:
            {
                if (context instanceof Activity) {
                    Window window = ((Activity) context).getWindow();
                    if (window != null) {
                        if ((msg.obj instanceof Integer) && ((Integer) msg.obj != 0)) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                        }
                    }
                }
                break;
            }
            default:
                if ((context instanceof SDLActivity) && !((SDLActivity) context).onUnhandledMessage(msg.arg1, msg.obj)) {
                    Log.e(TAG, "error handling message, command is " + msg.arg1);
                }
            }
        }
    }

    // Handler for the messages
    Handler commandHandler = new SDLCommandHandler();

    // Send a message from the SDLMain thread
    boolean sendCommand(int command, Object data) {
        Message msg = commandHandler.obtainMessage();
        msg.arg1 = command;
        msg.obj = data;
        boolean result = commandHandler.sendMessage(msg);

        if (Build.VERSION.SDK_INT >= 19 /* Android 4.4 (KITKAT) */) {
            if (command == COMMAND_CHANGE_WINDOW_STYLE) {
                // Ensure we don't return until the resize has actually happened,
                // or 500ms have passed.

                boolean bShouldWait = false;

                if (data instanceof Integer) {
                    // Let's figure out if we're already laid out fullscreen or not.
                    Display display = ((WindowManager) getSystemService(Context.WINDOW_SERVICE)).getDefaultDisplay();
                    DisplayMetrics realMetrics = new DisplayMetrics();
                    display.getRealMetrics(realMetrics);

                    boolean bFullscreenLayout = ((realMetrics.widthPixels == mSurface.getWidth()) &&
                            (realMetrics.heightPixels == mSurface.getHeight()));

                    if ((Integer) data == 1) {
                        // If we aren't laid out fullscreen or actively in fullscreen mode already, we're going
                        // to change size and should wait for surfaceChanged() before we return, so the size
                        // is right back in native code.  If we're already laid out fullscreen, though, we're
                        // not going to change size even if we change decor modes, so we shouldn't wait for
                        // surfaceChanged() -- which may not even happen -- and should return immediately.
                        bShouldWait = !bFullscreenLayout;
                    } else {
                        // If we're laid out fullscreen (even if the status bar and nav bar are present),
                        // or are actively in fullscreen, we're going to change size and should wait for
                        // surfaceChanged before we return, so the size is right back in native code.
                        bShouldWait = bFullscreenLayout;
                    }
                }

                if (bShouldWait && (SDLActivity.getContext() != null)) {
                    // We'll wait for the surfaceChanged() method, which will notify us
                    // when called.  That way, we know our current size is really the
                    // size we need, instead of grabbing a size that's still got
                    // the navigation and/or status bars before they're hidden.
                    //
                    // We'll wait for up to half a second, because some devices
                    // take a surprisingly long time for the surface resize, but
                    // then we'll just give up and return.
                    //
                    synchronized (SDLActivity.getContext()) {
                        try {
                            SDLActivity.getContext().wait(500);
                        } catch (InterruptedException ie) {
                            ie.printStackTrace();
                        }
                    }
                }
            }
        }

        return result;
    }

    // C functions we call
    public static native String nativeGetVersion();
    public static native int nativeSetupJNI();
    public static native int nativeRunMain(String library, String function, Object arguments);
    public static native void nativeLowMemory();
    public static native void nativeSendQuit();
    public static native void nativeQuit();
    public static native void nativePause();
    public static native void nativeResume();
    public static native void nativeFocusChanged(boolean hasFocus);
    public static native void onNativeDropFile(String filename);
    public static native void nativeSetScreenResolution(int surfaceWidth, int surfaceHeight, int deviceWidth, int deviceHeight, float rate);
    public static native void onNativeResize();
    public static native void onNativeKeyDown(int keycode);
    public static native void onNativeKeyUp(int keycode);
    public static native boolean onNativeSoftReturnKey();
    public static native void onNativeKeyboardFocusLost();
    public static native void onNativeMouse(int button, int action, float x, float y, boolean relative);
    public static native void onNativeTouch(int touchDevId, int pointerFingerId,
                                            int action, float x,
                                            float y, float p);
    public static native void onNativeAccel(float x, float y, float z);
    public static native void onNativeClipboardChanged();
    public static native void onNativeSurfaceCreated();
    public static native void onNativeSurfaceChanged();
    public static native void onNativeSurfaceDestroyed();
    public static native String nativeGetHint(String name);
    public static native boolean nativeGetHintBoolean(String name, boolean default_value);
    public static native void nativeSetenv(String name, String value);
    public static native void onNativeOrientationChanged(int orientation);
    public static native void nativeAddTouch(int touchId, String name);
    public static native void nativePermissionResult(int requestCode, boolean result);
    public static native void onNativeLocaleChanged();

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean setActivityTitle(String title) {
        // Called from SDLMain() thread and can't directly affect the view
        return mSingleton.sendCommand(COMMAND_CHANGE_TITLE, title);
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static void setWindowStyle(boolean fullscreen) {
        // Called from SDLMain() thread and can't directly affect the view
        mSingleton.sendCommand(COMMAND_CHANGE_WINDOW_STYLE, fullscreen ? 1 : 0);
    }

    /**
     * This method is called by SDL using JNI.
     * This is a static method for JNI convenience, it calls a non-static method
     * so that is can be overridden
     */
    public static void setOrientation(int w, int h, boolean resizable, String hint)
    {
        if (mSingleton != null) {
            mSingleton.setOrientationBis(w, h, resizable, hint);
        }
    }

    /**
     * This can be overridden
     */
    public void setOrientationBis(int w, int h, boolean resizable, String hint)
    {
        int orientation_landscape = -1;
        int orientation_portrait = -1;

        /* If set, hint "explicitly controls which UI orientations are allowed". */
        if (hint.contains("LandscapeRight") && hint.contains("LandscapeLeft")) {
            orientation_landscape = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE;
        } else if (hint.contains("LandscapeLeft")) {
            orientation_landscape = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE;
        } else if (hint.contains("LandscapeRight")) {
            orientation_landscape = ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE;
        }

        /* exact match to 'Portrait' to distinguish with PortraitUpsideDown */
        boolean contains_Portrait = hint.contains("Portrait ") || hint.endsWith("Portrait");

        if (contains_Portrait && hint.contains("PortraitUpsideDown")) {
            orientation_portrait = ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT;
        } else if (contains_Portrait) {
            orientation_portrait = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT;
        } else if (hint.contains("PortraitUpsideDown")) {
            orientation_portrait = ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT;
        }

        boolean is_landscape_allowed = (orientation_landscape != -1);
        boolean is_portrait_allowed = (orientation_portrait != -1);
        int req; /* Requested orientation */

        /* No valid hint, nothing is explicitly allowed */
        if (!is_portrait_allowed && !is_landscape_allowed) {
            if (resizable) {
                /* All orientations are allowed, respecting user orientation lock setting */
                req = ActivityInfo.SCREEN_ORIENTATION_FULL_USER;
            } else {
                /* Fixed window and nothing specified. Get orientation from w/h of created window */
                req = (w > h ? ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE : ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT);
            }
        } else {
            /* At least one orientation is allowed */
            if (resizable) {
                if (is_portrait_allowed && is_landscape_allowed) {
                    /* hint allows both landscape and portrait, promote to full user */
                    req = ActivityInfo.SCREEN_ORIENTATION_FULL_USER;
                } else {
                    /* Use the only one allowed "orientation" */
                    req = (is_landscape_allowed ? orientation_landscape : orientation_portrait);
                }
            } else {
                /* Fixed window and both orientations are allowed. Choose one. */
                if (is_portrait_allowed && is_landscape_allowed) {
                    req = (w > h ? orientation_landscape : orientation_portrait);
                } else {
                    /* Use the only one allowed "orientation" */
                    req = (is_landscape_allowed ? orientation_landscape : orientation_portrait);
                }
            }
        }

        Log.v(TAG, "setOrientation() requestedOrientation=" + req + " width=" + w +" height="+ h +" resizable=" + resizable + " hint=" + hint);
        mSingleton.setRequestedOrientation(req);
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static void minimizeWindow() {

        if (mSingleton == null) {
            return;
        }

        Intent startMain = new Intent(Intent.ACTION_MAIN);
        startMain.addCategory(Intent.CATEGORY_HOME);
        startMain.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        mSingleton.startActivity(startMain);
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean shouldMinimizeOnFocusLoss() {
/*
        if (Build.VERSION.SDK_INT >= 24) {
            if (mSingleton == null) {
                return true;
            }

            if (mSingleton.isInMultiWindowMode()) {
                return false;
            }

            if (mSingleton.isInPictureInPictureMode()) {
                return false;
            }
        }

        return true;
*/
        return false;
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean isScreenKeyboardShown()
    {
        if (mTextEdit == null) {
            return false;
        }

        if (!mScreenKeyboardShown) {
            return false;
        }

        InputMethodManager imm = (InputMethodManager) SDL.getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        return imm.isAcceptingText();

    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean supportsRelativeMouse()
    {
        // DeX mode in Samsung Experience 9.0 and earlier doesn't support relative mice properly under
        // Android 7 APIs, and simply returns no data under Android 8 APIs.
        //
        // This is fixed in Samsung Experience 9.5, which corresponds to Android 8.1.0, and
        // thus SDK version 27.  If we are in DeX mode and not API 27 or higher, as a result,
        // we should stick to relative mode.
        //
        if (Build.VERSION.SDK_INT < 27 /* Android 8.1 (O_MR1) */ && isDeXMode()) {
            return false;
        }

        return SDLActivity.getMotionListener().supportsRelativeMouse();
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean setRelativeMouseEnabled(boolean enabled)
    {
        if (enabled && !supportsRelativeMouse()) {
            return false;
        }

        return SDLActivity.getMotionListener().setRelativeMouseEnabled(enabled);
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean sendMessage(int command, int param) {
        if (mSingleton == null) {
            return false;
        }
        return mSingleton.sendCommand(command, param);
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static Context getContext() {
        return SDL.getContext();
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean isAndroidTV() {
        UiModeManager uiModeManager = (UiModeManager) getContext().getSystemService(UI_MODE_SERVICE);
        if (uiModeManager.getCurrentModeType() == Configuration.UI_MODE_TYPE_TELEVISION) {
            return true;
        }
        if (Build.MANUFACTURER.equals("MINIX") && Build.MODEL.equals("NEO-U1")) {
            return true;
        }
        if (Build.MANUFACTURER.equals("Amlogic") && Build.MODEL.equals("X96-W")) {
            return true;
        }
        return Build.MANUFACTURER.equals("Amlogic") && Build.MODEL.startsWith("TV");
    }

    public static double getDiagonal()
    {
        DisplayMetrics metrics = new DisplayMetrics();
        Activity activity = (Activity)getContext();
        if (activity == null) {
            return 0.0;
        }
        activity.getWindowManager().getDefaultDisplay().getMetrics(metrics);

        double dWidthInches = metrics.widthPixels / (double)metrics.xdpi;
        double dHeightInches = metrics.heightPixels / (double)metrics.ydpi;

        return Math.sqrt((dWidthInches * dWidthInches) + (dHeightInches * dHeightInches));
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean isTablet() {
        // If our diagonal size is seven inches or greater, we consider ourselves a tablet.
        return (getDiagonal() >= 7.0);
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean isChromebook() {
        if (getContext() == null) {
            return false;
        }
        return getContext().getPackageManager().hasSystemFeature("org.chromium.arc.device_management");
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean isDeXMode() {
        if (Build.VERSION.SDK_INT < 24 /* Android 7.0 (N) */) {
            return false;
        }
        try {
            final Configuration config = getContext().getResources().getConfiguration();
            final Class<?> configClass = config.getClass();
            return configClass.getField("SEM_DESKTOP_MODE_ENABLED").getInt(configClass)
                    == configClass.getField("semDesktopModeEnabled").getInt(config);
        } catch(Exception ignored) {
            return false;
        }
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static DisplayMetrics getDisplayDPI() {
        return getContext().getResources().getDisplayMetrics();
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean getManifestEnvironmentVariables() {
        try {
            if (getContext() == null) {
                return false;
            }

            ApplicationInfo applicationInfo = getContext().getPackageManager().getApplicationInfo(getContext().getPackageName(), PackageManager.GET_META_DATA);
            Bundle bundle = applicationInfo.metaData;
            if (bundle == null) {
                return false;
            }
            String prefix = "SDL_ENV.";
            final int trimLength = prefix.length();
            for (String key : bundle.keySet()) {
                if (key.startsWith(prefix)) {
                    String name = key.substring(trimLength);
                    String value = bundle.get(key).toString();
                    nativeSetenv(name, value);
                }
            }
            /* environment variables set! */
            return true;
        } catch (Exception e) {
           Log.v(TAG, "exception " + e.toString());
        }
        return false;
    }

    // This method is called by SDLControllerManager's API 26 Generic Motion Handler.
    public static View getContentView() {
        return mLayout;
    }

    static class ShowTextInputTask implements Runnable {
        /*
         * This is used to regulate the pan&scan method to have some offset from
         * the bottom edge of the input region and the top edge of an input
         * method (soft keyboard)
         */
        static final int HEIGHT_PADDING = 15;

        public int x, y, w, h;

        public ShowTextInputTask(int x, int y, int w, int h) {
            this.x = x;
            this.y = y;
            this.w = w;
            this.h = h;

            /* Minimum size of 1 pixel, so it takes focus. */
            if (this.w <= 0) {
                this.w = 1;
            }
            if (this.h + HEIGHT_PADDING <= 0) {
                this.h = 1 - HEIGHT_PADDING;
            }
        }

        @Override
        public void run() {
            RelativeLayout.LayoutParams params = new RelativeLayout.LayoutParams(w, h + HEIGHT_PADDING);
            params.leftMargin = x;
            params.topMargin = y;

            if (mTextEdit == null) {
                mTextEdit = new DummyEdit(SDL.getContext());

                mLayout.addView(mTextEdit, params);
            } else {
                mTextEdit.setLayoutParams(params);
            }

            mTextEdit.setVisibility(View.VISIBLE);
            mTextEdit.requestFocus();

            InputMethodManager imm = (InputMethodManager) SDL.getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
            imm.showSoftInput(mTextEdit, 0);

            mScreenKeyboardShown = true;
        }
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean showTextInput(int x, int y, int w, int h) {
        // Transfer the task to the main thread as a Runnable
        return mSingleton.commandHandler.post(new ShowTextInputTask(x, y, w, h));
    }

    /** DosBoxX: toggle the Android soft keyboard (bound to the BACK button).
     * Lets the user type into DOS games / the DOSBox shell on a touch device. */
    public static void toggleSoftKeyboard() {
        if (mSingleton == null) {
            return;
        }
        if (mScreenKeyboardShown) {
            mSingleton.sendCommand(COMMAND_TEXTEDIT_HIDE, null);
        } else {
            showTextInput(0, 0, 1, 1);
        }
    }

    public static boolean isTextInputEvent(KeyEvent event) {

        // Key pressed with Ctrl should be sent as SDL_KEYDOWN/SDL_KEYUP and not SDL_TEXTINPUT
        if (event.isCtrlPressed()) {
            return false;
        }

        return event.isPrintingKey() || event.getKeyCode() == KeyEvent.KEYCODE_SPACE;
    }

    public static boolean handleKeyEvent(View v, int keyCode, KeyEvent event, InputConnection ic) {
        int deviceId = event.getDeviceId();
        int source = event.getSource();

        if (source == InputDevice.SOURCE_UNKNOWN) {
            InputDevice device = InputDevice.getDevice(deviceId);
            if (device != null) {
                source = device.getSources();
            }
        }

//        if (event.getAction() == KeyEvent.ACTION_DOWN) {
//            Log.v("SDL", "key down: " + keyCode + ", deviceId = " + deviceId + ", source = " + source);
//        } else if (event.getAction() == KeyEvent.ACTION_UP) {
//            Log.v("SDL", "key up: " + keyCode + ", deviceId = " + deviceId + ", source = " + source);
//        }

        // Dispatch the different events depending on where they come from
        // Some SOURCE_JOYSTICK, SOURCE_DPAD or SOURCE_GAMEPAD are also SOURCE_KEYBOARD
        // So, we try to process them as JOYSTICK/DPAD/GAMEPAD events first, if that fails we try them as KEYBOARD
        //
        // Furthermore, it's possible a game controller has SOURCE_KEYBOARD and
        // SOURCE_JOYSTICK, while its key events arrive from the keyboard source
        // So, retrieve the device itself and check all of its sources
        if (SDLControllerManager.isDeviceSDLJoystick(deviceId)) {
            // Note that we process events with specific key codes here
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                if (SDLControllerManager.onNativePadDown(deviceId, keyCode) == 0) {
                    return true;
                }
            } else if (event.getAction() == KeyEvent.ACTION_UP) {
                if (SDLControllerManager.onNativePadUp(deviceId, keyCode) == 0) {
                    return true;
                }
            }
        }

        if ((source & InputDevice.SOURCE_MOUSE) == InputDevice.SOURCE_MOUSE) {
            // on some devices key events are sent for mouse BUTTON_BACK/FORWARD presses
            // they are ignored here because sending them as mouse input to SDL is messy
            if ((keyCode == KeyEvent.KEYCODE_BACK) || (keyCode == KeyEvent.KEYCODE_FORWARD)) {
                switch (event.getAction()) {
                case KeyEvent.ACTION_DOWN:
                case KeyEvent.ACTION_UP:
                    // mark the event as handled or it will be handled by system
                    // handling KEYCODE_BACK by system will call onBackPressed()
                    return true;
                }
            }
        }

        if (event.getAction() == KeyEvent.ACTION_DOWN) {
            if (isTextInputEvent(event)) {
                if (ic != null) {
                    ic.commitText(String.valueOf((char) event.getUnicodeChar()), 1);
                } else {
                    SDLInputConnection.nativeCommitText(String.valueOf((char) event.getUnicodeChar()), 1);
                }
            }
            onNativeKeyDown(keyCode);
            return true;
        } else if (event.getAction() == KeyEvent.ACTION_UP) {
            onNativeKeyUp(keyCode);
            return true;
        }

        return false;
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static Surface getNativeSurface() {
        if (SDLActivity.mSurface == null) {
            return null;
        }
        return SDLActivity.mSurface.getNativeSurface();
    }

    // Input

    /**
     * This method is called by SDL using JNI.
     */
    public static void initTouch() {
        int[] ids = InputDevice.getDeviceIds();

        for (int id : ids) {
            InputDevice device = InputDevice.getDevice(id);
            /* Allow SOURCE_TOUCHSCREEN and also Virtual InputDevices because they can send TOUCHSCREEN events */
            if (device != null && ((device.getSources() & InputDevice.SOURCE_TOUCHSCREEN) == InputDevice.SOURCE_TOUCHSCREEN
                    || device.isVirtual())) {

                int touchDevId = device.getId();
                /*
                 * Prevent id to be -1, since it's used in SDL internal for synthetic events
                 * Appears when using Android emulator, eg:
                 *  adb shell input mouse tap 100 100
                 *  adb shell input touchscreen tap 100 100
                 */
                if (touchDevId < 0) {
                    touchDevId -= 1;
                }
                nativeAddTouch(touchDevId, device.getName());
            }
        }
    }

    // Messagebox

    /** Result of current messagebox. Also used for blocking the calling thread. */
    protected final int[] messageboxSelection = new int[1];

    /**
     * This method is called by SDL using JNI.
     * Shows the messagebox from UI thread and block calling thread.
     * buttonFlags, buttonIds and buttonTexts must have same length.
     * @param buttonFlags array containing flags for every button.
     * @param buttonIds array containing id for every button.
     * @param buttonTexts array containing text for every button.
     * @param colors null for default or array of length 5 containing colors.
     * @return button id or -1.
     */
    public int messageboxShowMessageBox(
            final int flags,
            final String title,
            final String message,
            final int[] buttonFlags,
            final int[] buttonIds,
            final String[] buttonTexts,
            final int[] colors) {

        messageboxSelection[0] = -1;

        // sanity checks

        if ((buttonFlags.length != buttonIds.length) && (buttonIds.length != buttonTexts.length)) {
            return -1; // implementation broken
        }

        // collect arguments for Dialog

        final Bundle args = new Bundle();
        args.putInt("flags", flags);
        args.putString("title", title);
        args.putString("message", message);
        args.putIntArray("buttonFlags", buttonFlags);
        args.putIntArray("buttonIds", buttonIds);
        args.putStringArray("buttonTexts", buttonTexts);
        args.putIntArray("colors", colors);

        // trigger Dialog creation on UI thread

        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                messageboxCreateAndShow(args);
            }
        });

        // block the calling thread

        synchronized (messageboxSelection) {
            try {
                messageboxSelection.wait();
            } catch (InterruptedException ex) {
                ex.printStackTrace();
                return -1;
            }
        }

        // return selected value

        return messageboxSelection[0];
    }

    protected void messageboxCreateAndShow(Bundle args) {

        // TODO set values from "flags" to messagebox dialog

        // get colors

        int[] colors = args.getIntArray("colors");
        int backgroundColor;
        int textColor;
        int buttonBorderColor;
        int buttonBackgroundColor;
        int buttonSelectedColor;
        if (colors != null) {
            int i = -1;
            backgroundColor = colors[++i];
            textColor = colors[++i];
            buttonBorderColor = colors[++i];
            buttonBackgroundColor = colors[++i];
            buttonSelectedColor = colors[++i];
        } else {
            backgroundColor = Color.TRANSPARENT;
            textColor = Color.TRANSPARENT;
            buttonBorderColor = Color.TRANSPARENT;
            buttonBackgroundColor = Color.TRANSPARENT;
            buttonSelectedColor = Color.TRANSPARENT;
        }

        // create dialog with title and a listener to wake up calling thread

        final AlertDialog dialog = new AlertDialog.Builder(this).create();
        dialog.setTitle(args.getString("title"));
        dialog.setCancelable(false);
        dialog.setOnDismissListener(new DialogInterface.OnDismissListener() {
            @Override
            public void onDismiss(DialogInterface unused) {
                synchronized (messageboxSelection) {
                    messageboxSelection.notify();
                }
            }
        });

        // create text

        TextView message = new TextView(this);
        message.setGravity(Gravity.CENTER);
        message.setText(args.getString("message"));
        if (textColor != Color.TRANSPARENT) {
            message.setTextColor(textColor);
        }

        // create buttons

        int[] buttonFlags = args.getIntArray("buttonFlags");
        int[] buttonIds = args.getIntArray("buttonIds");
        String[] buttonTexts = args.getStringArray("buttonTexts");

        final SparseArray<Button> mapping = new SparseArray<Button>();

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setGravity(Gravity.CENTER);
        for (int i = 0; i < buttonTexts.length; ++i) {
            Button button = new Button(this);
            final int id = buttonIds[i];
            button.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    messageboxSelection[0] = id;
                    dialog.dismiss();
                }
            });
            if (buttonFlags[i] != 0) {
                // see SDL_messagebox.h
                if ((buttonFlags[i] & 0x00000001) != 0) {
                    mapping.put(KeyEvent.KEYCODE_ENTER, button);
                }
                if ((buttonFlags[i] & 0x00000002) != 0) {
                    mapping.put(KeyEvent.KEYCODE_ESCAPE, button); /* API 11 */
                }
            }
            button.setText(buttonTexts[i]);
            if (textColor != Color.TRANSPARENT) {
                button.setTextColor(textColor);
            }
            if (buttonBorderColor != Color.TRANSPARENT) {
                // TODO set color for border of messagebox button
            }
            if (buttonBackgroundColor != Color.TRANSPARENT) {
                Drawable drawable = button.getBackground();
                if (drawable == null) {
                    // setting the color this way removes the style
                    button.setBackgroundColor(buttonBackgroundColor);
                } else {
                    // setting the color this way keeps the style (gradient, padding, etc.)
                    drawable.setColorFilter(buttonBackgroundColor, PorterDuff.Mode.MULTIPLY);
                }
            }
            if (buttonSelectedColor != Color.TRANSPARENT) {
                // TODO set color for selected messagebox button
            }
            buttons.addView(button);
        }

        // create content

        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.addView(message);
        content.addView(buttons);
        if (backgroundColor != Color.TRANSPARENT) {
            content.setBackgroundColor(backgroundColor);
        }

        // add content to dialog and return

        dialog.setView(content);
        dialog.setOnKeyListener(new Dialog.OnKeyListener() {
            @Override
            public boolean onKey(DialogInterface d, int keyCode, KeyEvent event) {
                Button button = mapping.get(keyCode);
                if (button != null) {
                    if (event.getAction() == KeyEvent.ACTION_UP) {
                        button.performClick();
                    }
                    return true; // also for ignored actions
                }
                return false;
            }
        });

        dialog.show();
    }

    private final Runnable rehideSystemUi = new Runnable() {
        @Override
        public void run() {
            if (Build.VERSION.SDK_INT >= 19 /* Android 4.4 (KITKAT) */) {
                int flags = View.SYSTEM_UI_FLAG_FULLSCREEN |
                        View.SYSTEM_UI_FLAG_HIDE_NAVIGATION |
                        View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY |
                        View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN |
                        View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION |
                        View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.INVISIBLE;

                SDLActivity.this.getWindow().getDecorView().setSystemUiVisibility(flags);
            }
        }
    };

    public void onSystemUiVisibilityChange(int visibility) {
        if (SDLActivity.mFullscreenModeActive && ((visibility & View.SYSTEM_UI_FLAG_FULLSCREEN) == 0 || (visibility & View.SYSTEM_UI_FLAG_HIDE_NAVIGATION) == 0)) {

            Handler handler = getWindow().getDecorView().getHandler();
            if (handler != null) {
                handler.removeCallbacks(rehideSystemUi); // Prevent a hide loop.
                handler.postDelayed(rehideSystemUi, 2000);
            }

        }
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean clipboardHasText() {
        return mClipboardHandler.clipboardHasText();
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static String clipboardGetText() {
        return mClipboardHandler.clipboardGetText();
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static void clipboardSetText(String string) {
        mClipboardHandler.clipboardSetText(string);
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static int createCustomCursor(int[] colors, int width, int height, int hotSpotX, int hotSpotY) {
        Bitmap bitmap = Bitmap.createBitmap(colors, width, height, Bitmap.Config.ARGB_8888);
        ++mLastCursorID;

        if (Build.VERSION.SDK_INT >= 24 /* Android 7.0 (N) */) {
            try {
                mCursors.put(mLastCursorID, PointerIcon.create(bitmap, hotSpotX, hotSpotY));
            } catch (Exception e) {
                return 0;
            }
        } else {
            return 0;
        }
        return mLastCursorID;
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static void destroyCustomCursor(int cursorID) {
        if (Build.VERSION.SDK_INT >= 24 /* Android 7.0 (N) */) {
            try {
                mCursors.remove(cursorID);
            } catch (Exception e) {
            }
        }
        return;
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean setCustomCursor(int cursorID) {

        if (Build.VERSION.SDK_INT >= 24 /* Android 7.0 (N) */) {
            try {
                mSurface.setPointerIcon(mCursors.get(cursorID));
            } catch (Exception e) {
                return false;
            }
        } else {
            return false;
        }
        return true;
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static boolean setSystemCursor(int cursorID) {
        int cursor_type = 0; //PointerIcon.TYPE_NULL;
        switch (cursorID) {
        case SDL_SYSTEM_CURSOR_ARROW:
            cursor_type = 1000; //PointerIcon.TYPE_ARROW;
            break;
        case SDL_SYSTEM_CURSOR_IBEAM:
            cursor_type = 1008; //PointerIcon.TYPE_TEXT;
            break;
        case SDL_SYSTEM_CURSOR_WAIT:
            cursor_type = 1004; //PointerIcon.TYPE_WAIT;
            break;
        case SDL_SYSTEM_CURSOR_CROSSHAIR:
            cursor_type = 1007; //PointerIcon.TYPE_CROSSHAIR;
            break;
        case SDL_SYSTEM_CURSOR_WAITARROW:
            cursor_type = 1004; //PointerIcon.TYPE_WAIT;
            break;
        case SDL_SYSTEM_CURSOR_SIZENWSE:
            cursor_type = 1017; //PointerIcon.TYPE_TOP_LEFT_DIAGONAL_DOUBLE_ARROW;
            break;
        case SDL_SYSTEM_CURSOR_SIZENESW:
            cursor_type = 1016; //PointerIcon.TYPE_TOP_RIGHT_DIAGONAL_DOUBLE_ARROW;
            break;
        case SDL_SYSTEM_CURSOR_SIZEWE:
            cursor_type = 1014; //PointerIcon.TYPE_HORIZONTAL_DOUBLE_ARROW;
            break;
        case SDL_SYSTEM_CURSOR_SIZENS:
            cursor_type = 1015; //PointerIcon.TYPE_VERTICAL_DOUBLE_ARROW;
            break;
        case SDL_SYSTEM_CURSOR_SIZEALL:
            cursor_type = 1020; //PointerIcon.TYPE_GRAB;
            break;
        case SDL_SYSTEM_CURSOR_NO:
            cursor_type = 1012; //PointerIcon.TYPE_NO_DROP;
            break;
        case SDL_SYSTEM_CURSOR_HAND:
            cursor_type = 1002; //PointerIcon.TYPE_HAND;
            break;
        }
        if (Build.VERSION.SDK_INT >= 24 /* Android 7.0 (N) */) {
            try {
                mSurface.setPointerIcon(PointerIcon.getSystemIcon(SDL.getContext(), cursor_type));
            } catch (Exception e) {
                return false;
            }
        }
        return true;
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static void requestPermission(String permission, int requestCode) {
        if (Build.VERSION.SDK_INT < 23 /* Android 6.0 (M) */) {
            nativePermissionResult(requestCode, true);
            return;
        }

        Activity activity = (Activity)getContext();
        if (activity.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(new String[]{permission}, requestCode);
        } else {
            nativePermissionResult(requestCode, true);
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        boolean result = (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED);
        nativePermissionResult(requestCode, result);
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static int openURL(String url)
    {
        try {
            Intent i = new Intent(Intent.ACTION_VIEW);
            i.setData(Uri.parse(url));

            int flags = Intent.FLAG_ACTIVITY_NO_HISTORY | Intent.FLAG_ACTIVITY_MULTIPLE_TASK;
            if (Build.VERSION.SDK_INT >= 21 /* Android 5.0 (LOLLIPOP) */) {
                flags |= Intent.FLAG_ACTIVITY_NEW_DOCUMENT;
            } else {
                flags |= Intent.FLAG_ACTIVITY_CLEAR_WHEN_TASK_RESET;
            }
            i.addFlags(flags);

            mSingleton.startActivity(i);
        } catch (Exception ex) {
            return -1;
        }
        return 0;
    }

    /**
     * This method is called by SDL using JNI.
     */
    public static int showToast(String message, int duration, int gravity, int xOffset, int yOffset)
    {
        if(null == mSingleton) {
            return - 1;
        }

        try
        {
            class OneShotTask implements Runnable {
                String mMessage;
                int mDuration;
                int mGravity;
                int mXOffset;
                int mYOffset;

                OneShotTask(String message, int duration, int gravity, int xOffset, int yOffset) {
                    mMessage  = message;
                    mDuration = duration;
                    mGravity  = gravity;
                    mXOffset  = xOffset;
                    mYOffset  = yOffset;
                }

                public void run() {
                    try
                    {
                        Toast toast = Toast.makeText(mSingleton, mMessage, mDuration);
                        if (mGravity >= 0) {
                            toast.setGravity(mGravity, mXOffset, mYOffset);
                        }
                        toast.show();
                    } catch(Exception ex) {
                        Log.e(TAG, ex.getMessage());
                    }
                }
            }
            mSingleton.runOnUiThread(new OneShotTask(message, duration, gravity, xOffset, yOffset));
        } catch(Exception ex) {
            return -1;
        }
        return 0;
    }
}

/**
    Simple runnable to start the SDL application
*/
class SDLMain implements Runnable {
    @Override
    public void run() {
        // Runs SDL_main()
        String library = SDLActivity.mSingleton.getMainSharedObject();
        String function = SDLActivity.mSingleton.getMainFunction();
        String[] arguments = SDLActivity.mSingleton.getArguments();

        try {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_DISPLAY);
        } catch (Exception e) {
            Log.v("SDL", "modify thread properties failed " + e.toString());
        }

        Log.v("SDL", "Running main function " + function + " from library " + library);

        SDLActivity.nativeRunMain(library, function, arguments);

        Log.v("SDL", "Finished main function");

        if (SDLActivity.mSingleton != null && !SDLActivity.mSingleton.isFinishing()) {
            // Let's finish the Activity
            SDLActivity.mSDLThread = null;
            SDLActivity.mSingleton.finish();
        }  // else: Activity is already being destroyed

    }
}

/* This is a fake invisible editor view that receives the input and defines the
 * pan&scan region
 */
class DummyEdit extends View implements View.OnKeyListener {
    InputConnection ic;

    public DummyEdit(Context context) {
        super(context);
        setFocusableInTouchMode(true);
        setFocusable(true);
        setOnKeyListener(this);
    }

    @Override
    public boolean onCheckIsTextEditor() {
        return true;
    }

    @Override
    public boolean onKey(View v, int keyCode, KeyEvent event) {
        return SDLActivity.handleKeyEvent(v, keyCode, event, ic);
    }

    //
    @Override
    public boolean onKeyPreIme (int keyCode, KeyEvent event) {
        // As seen on StackOverflow: http://stackoverflow.com/questions/7634346/keyboard-hide-event
        // FIXME: Discussion at http://bugzilla.libsdl.org/show_bug.cgi?id=1639
        // FIXME: This is not a 100% effective solution to the problem of detecting if the keyboard is showing or not
        // FIXME: A more effective solution would be to assume our Layout to be RelativeLayout or LinearLayout
        // FIXME: And determine the keyboard presence doing this: http://stackoverflow.com/questions/2150078/how-to-check-visibility-of-software-keyboard-in-android
        // FIXME: An even more effective way would be if Android provided this out of the box, but where would the fun be in that :)
        if (event.getAction()==KeyEvent.ACTION_UP && keyCode == KeyEvent.KEYCODE_BACK) {
            if (SDLActivity.mTextEdit != null && SDLActivity.mTextEdit.getVisibility() == View.VISIBLE) {
                SDLActivity.onNativeKeyboardFocusLost();
            }
        }
        return super.onKeyPreIme(keyCode, event);
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        ic = new SDLInputConnection(this, true);

        outAttrs.inputType = InputType.TYPE_CLASS_TEXT |
                             InputType.TYPE_TEXT_FLAG_MULTI_LINE;
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI |
                              EditorInfo.IME_FLAG_NO_FULLSCREEN /* API 11 */;

        return ic;
    }
}

class SDLInputConnection extends BaseInputConnection {

    protected EditText mEditText;
    protected String mCommittedText = "";

    public SDLInputConnection(View targetView, boolean fullEditor) {
        super(targetView, fullEditor);
        mEditText = new EditText(SDL.getContext());
    }

    @Override
    public Editable getEditable() {
        return mEditText.getEditableText();
    }

    @Override
    public boolean sendKeyEvent(KeyEvent event) {
        /*
         * This used to handle the keycodes from soft keyboard (and IME-translated input from hardkeyboard)
         * However, as of Ice Cream Sandwich and later, almost all soft keyboard doesn't generate key presses
         * and so we need to generate them ourselves in commitText.  To avoid duplicates on the handful of keys
         * that still do, we empty this out.
         */

        /*
         * Return DOES still generate a key event, however.  So rather than using it as the 'click a button' key
         * as we do with physical keyboards, let's just use it to hide the keyboard.
         */

        if (event.getKeyCode() == KeyEvent.KEYCODE_ENTER) {
            if (SDLActivity.onNativeSoftReturnKey()) {
                return true;
            }
        }

        return super.sendKeyEvent(event);
    }

    @Override
    public boolean commitText(CharSequence text, int newCursorPosition) {
        if (!super.commitText(text, newCursorPosition)) {
            return false;
        }
        updateText();
        return true;
    }

    @Override
    public boolean setComposingText(CharSequence text, int newCursorPosition) {
        if (!super.setComposingText(text, newCursorPosition)) {
            return false;
        }
        updateText();
        return true;
    }

    @Override
    public boolean deleteSurroundingText(int beforeLength, int afterLength) {
        if (Build.VERSION.SDK_INT <= 29 /* Android 10.0 (Q) */) {
            // Workaround to capture backspace key. Ref: http://stackoverflow.com/questions>/14560344/android-backspace-in-webview-baseinputconnection
            // and https://bugzilla.libsdl.org/show_bug.cgi?id=2265
            if (beforeLength > 0 && afterLength == 0) {
                // backspace(s)
                while (beforeLength-- > 0) {
                    nativeGenerateScancodeForUnichar('\b');
                }
                return true;
           }
        }

        if (!super.deleteSurroundingText(beforeLength, afterLength)) {
            return false;
        }
        updateText();
        return true;
    }

    protected void updateText() {
        final Editable content = getEditable();
        if (content == null) {
            return;
        }

        String text = content.toString();
        int compareLength = Math.min(text.length(), mCommittedText.length());
        int matchLength, offset;

        /* Backspace over characters that are no longer in the string */
        for (matchLength = 0; matchLength < compareLength; ) {
            int codePoint = mCommittedText.codePointAt(matchLength);
            if (codePoint != text.codePointAt(matchLength)) {
                break;
            }
            matchLength += Character.charCount(codePoint);
        }
        /* FIXME: This doesn't handle graphemes, like '🌬️' */
        for (offset = matchLength; offset < mCommittedText.length(); ) {
            int codePoint = mCommittedText.codePointAt(offset);
            nativeGenerateScancodeForUnichar('\b');
            offset += Character.charCount(codePoint);
        }

        if (matchLength < text.length()) {
            String pendingText = text.subSequence(matchLength, text.length()).toString();
            for (offset = 0; offset < pendingText.length(); ) {
                int codePoint = pendingText.codePointAt(offset);
                if (codePoint == '\n') {
                    if (SDLActivity.onNativeSoftReturnKey()) {
                        return;
                    }
                }
                /* Higher code points don't generate simulated scancodes */
                if (codePoint < 128) {
                    nativeGenerateScancodeForUnichar((char)codePoint);
                }
                offset += Character.charCount(codePoint);
            }
            SDLInputConnection.nativeCommitText(pendingText, 0);
        }
        mCommittedText = text;
    }

    public static native void nativeCommitText(String text, int newCursorPosition);

    public static native void nativeGenerateScancodeForUnichar(char c);
}

class SDLClipboardHandler implements
    ClipboardManager.OnPrimaryClipChangedListener {

    protected ClipboardManager mClipMgr;

    SDLClipboardHandler() {
       mClipMgr = (ClipboardManager) SDL.getContext().getSystemService(Context.CLIPBOARD_SERVICE);
       mClipMgr.addPrimaryClipChangedListener(this);
    }

    public boolean clipboardHasText() {
       return mClipMgr.hasPrimaryClip();
    }

    public String clipboardGetText() {
        ClipData clip = mClipMgr.getPrimaryClip();
        if (clip != null) {
            ClipData.Item item = clip.getItemAt(0);
            if (item != null) {
                CharSequence text = item.getText();
                if (text != null) {
                    return text.toString();
                }
            }
        }
        return null;
    }

    public void clipboardSetText(String string) {
       mClipMgr.removePrimaryClipChangedListener(this);
       ClipData clip = ClipData.newPlainText(null, string);
       mClipMgr.setPrimaryClip(clip);
       mClipMgr.addPrimaryClipChangedListener(this);
    }

    @Override
    public void onPrimaryClipChanged() {
        SDLActivity.onNativeClipboardChanged();
    }
}
