package com.dosboxx.dosboxx_launcher

import android.content.ComponentName
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// The launcher's half of the door. Flutter writes dosbox-x.conf and asks
/// for a start; everything else the emulator needs it reads from that conf,
/// which is the same contract the Java launcher spoke.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dosboxx/emulator")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Where the conf lives and the emulator reads it.
                    "confPath" -> result.success(
                        File(getExternalFilesDir(null), "dosbox-x.conf").absolutePath)
                    // Where games live: one subfolder or bootable image each.
                    "gamesDir" -> {
                        val dir = File(getExternalFilesDir(null), "games")
                        if (!dir.exists()) dir.mkdirs()
                        result.success(dir.absolutePath)
                    }
                    "filesDir" -> result.success(
                        getExternalFilesDir(null)?.absolutePath ?: filesDir.absolutePath)
                    "launch" -> {
                        // The conf is already on disk - Dart wrote it. Start
                        // the emulator in its own process and stand back.
                        val intent = Intent()
                        intent.component = ComponentName(
                            packageName, "org.libsdl.app.SDLActivity")
                        startActivity(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
