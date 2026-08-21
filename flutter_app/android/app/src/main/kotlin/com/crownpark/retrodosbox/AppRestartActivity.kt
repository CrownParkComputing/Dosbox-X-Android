package com.crownpark.retrodosbox

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper

/**
 * Foreground hand-off used to replace the one-shot DOSBox process.
 *
 * This activity runs in the manifest's private `:restart` process. The main
 * process starts it before killing itself; once that process is gone, this
 * still-foreground activity launches MainActivity into a fresh process and
 * removes its own temporary task.
 */
class AppRestartActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        Handler(Looper.getMainLooper()).postDelayed({
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                ?: Intent(this, MainActivity::class.java)
            launchIntent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
            )
            startActivity(launchIntent)
            finishAndRemoveTask()

            // MainActivity belongs to the default process, so ending this
            // short-lived helper cannot take the fresh Flutter process down.
            Handler(Looper.getMainLooper()).postDelayed({
                android.os.Process.killProcess(android.os.Process.myPid())
            }, HELPER_EXIT_DELAY_MS)
        }, RELAUNCH_DELAY_MS)
    }

    companion object {
        private const val RELAUNCH_DELAY_MS = 400L
        private const val HELPER_EXIT_DELAY_MS = 150L
    }
}
