package com.dosboxx.dosboxx_launcher

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// The launcher's half of the door. Flutter writes dosbox-x.conf and asks
/// for a start; everything else the emulator needs it reads from that conf,
/// which is the same contract the Java launcher spoke.
class MainActivity : FlutterActivity() {
    private var pendingPick: MethodChannel.Result? = null

    private fun prefs() = getSharedPreferences("launcher", MODE_PRIVATE)

    private fun sourceUri(): Uri? =
        prefs().getString("source_tree", null)?.let(Uri::parse)

    /// Human name for a picked tree ("primary:Games" -> "Games").
    private fun folderLabel(uri: Uri): String {
        val seg = uri.lastPathSegment ?: return "collection"
        val name = seg.substringAfterLast(':').substringAfterLast('/')
        return if (name.isEmpty()) "collection" else name
    }

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
                fullscreen=false
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
                    // --- the game collection: a user-chosen SAF folder of
                    // thousands of zips, browsed inside the app. Same SAF
                    // approach the Java launcher shipped with.
                    "sourceFolder" -> {
                        val uri = sourceUri()
                        result.success(uri?.let {
                            mapOf("uri" to it.toString(), "name" to folderLabel(it))
                        })
                    }
                    "pickSourceFolder" -> {
                        if (pendingPick != null) {
                            result.error("busy", "picker already open", null)
                        } else {
                            pendingPick = result
                            startActivityForResult(
                                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_TREE)
                        }
                    }
                    "listSource" -> {
                        val uri = sourceUri()
                        if (uri == null) {
                            result.success(null)
                        } else {
                            // One cursor over the tree's children: fast even
                            // for thousands of entries (DocumentFile would
                            // re-query per file).
                            Thread {
                                try {
                                    val out = ArrayList<Map<String, Any>>()
                                    val children =
                                        DocumentsContract.buildChildDocumentsUriUsingTree(
                                            uri, DocumentsContract.getTreeDocumentId(uri))
                                    contentResolver.query(children, arrayOf(
                                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                                        DocumentsContract.Document.COLUMN_SIZE,
                                        DocumentsContract.Document.COLUMN_MIME_TYPE),
                                        null, null, null)?.use { c ->
                                        while (c.moveToNext()) {
                                            out.add(mapOf(
                                                "id" to c.getString(0),
                                                "name" to (c.getString(1) ?: ""),
                                                "size" to c.getLong(2),
                                                "dir" to (c.getString(3) ==
                                                    DocumentsContract.Document.MIME_TYPE_DIR)))
                                        }
                                    }
                                    runOnUiThread { result.success(out) }
                                } catch (e: Exception) {
                                    runOnUiThread {
                                        result.error("list", e.message, null)
                                    }
                                }
                            }.start()
                        }
                    }
                    "importFromSource" -> {
                        val uri = sourceUri()
                        val id = call.argument<String>("id")
                        val name = call.argument<String>("name")
                        if (uri == null || id == null || name == null) {
                            result.error("args", "missing source/id/name", null)
                        } else {
                            Thread {
                                val dest = File(cacheDir, name)
                                try {
                                    val doc = DocumentsContract
                                        .buildDocumentUriUsingTree(uri, id)
                                    contentResolver.openInputStream(doc).use { input ->
                                        if (input == null) throw Exception("unreadable")
                                        dest.outputStream().use { o ->
                                            input.copyTo(o, 1 shl 16)
                                        }
                                    }
                                    runOnUiThread { result.success(dest.absolutePath) }
                                } catch (e: Exception) {
                                    dest.delete()
                                    runOnUiThread { result.error("copy", e.message, null) }
                                }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_TREE) {
            val res = pendingPick
            pendingPick = null
            val uri = data?.data
            if (resultCode == Activity.RESULT_OK && uri != null) {
                contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                prefs().edit().putString("source_tree", uri.toString()).apply()
                res?.success(mapOf("uri" to uri.toString(), "name" to folderLabel(uri)))
            } else {
                res?.success(null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    companion object {
        private const val REQ_TREE = 7001
    }
}
