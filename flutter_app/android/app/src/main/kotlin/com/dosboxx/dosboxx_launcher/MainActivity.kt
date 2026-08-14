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
    override fun onResume() {
        super.onResume()
        // Integration-test door (tools/boot-test.sh): boot plain DOS with an
        // autoexec that writes C:\BOOTOK.TXT. The file appearing on the
        // Android side proves conf parse, mount, DOS boot and shell
        // execution end to end - no screenshot judgement involved.
        if (intent?.getBooleanExtra("boottest", false) == true) {
            intent.removeExtra("boottest")
            val files = getExternalFilesDir(null) ?: filesDir
            val cdir = File(files, "boottest")
            cdir.mkdirs()
            File(cdir, "BOOTOK.TXT").delete()
            File(files, "dosbox-x.conf").writeText(
                """
                [sdl]
                fullscreen=true
                autolock=true
                output=surface
                showmenu=false
                showdetails=false

                [autoexec]
                mount c "${cdir.absolutePath}"
                c:
                echo OK > C:\BOOTOK.TXT
                """.trimIndent() + "\n")
            startActivity(Intent().setComponent(
                ComponentName(packageName, "org.libsdl.app.SDLActivity")))
        }
    }

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
