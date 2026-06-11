package com.dosboxx.app;

/** Bridge to DOSBox-X's status line (FPS / real-time speed), which the native
 * code caches from what it would otherwise put in the window title. */
public class DosStatus {
    public static native String getStatusLine();
}
