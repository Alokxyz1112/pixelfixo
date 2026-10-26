package com.alokxyz1112.pixelfixo

import android.content.ContentValues
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private var upscaler: NativeUpscaler? = null
    private var shareCh: MethodChannel? = null
    private var pendingShare: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val up = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pixelfixo/upscale")
        up.setMethodCallHandler { call, result ->
            when (call.method) {
                "cancel" -> { upscaler?.cancel?.set(true); result.success(true) }
                "run" -> Thread {
                    try {
                        val u = NativeUpscaler { d, t, b -> runOnUiThread { up.invokeMethod("progress", mapOf("done" to d, "total" to t, "backend" to b)) } }
                        upscaler = u
                        val r = u.run(call.argument<String>("model")!!, call.argument<String>("input")!!,
                            call.argument<Int>("w")!!, call.argument<Int>("h")!!, call.argument<Int>("scale")!!,
                            call.argument<Int>("tile")!!, call.argument<Int>("pad")!!, call.argument<String>("output")!!,
                            call.argument<List<String>>("backends")!!,
                            call.argument<Int>("outW") ?: (call.argument<Int>("w")!! * call.argument<Int>("scale")!!),
                            call.argument<Int>("outH") ?: (call.argument<Int>("h")!! * call.argument<Int>("scale")!!),
                            call.argument<Boolean>("post") ?: false, call.argument<Boolean>("lowQuality") ?: false,
                            (call.argument<Double>("texture") ?: 0.0).toFloat(), call.argument<Int>("skin") ?: 0)
                        runOnUiThread { result.success(r) }
                    } catch (e: InterruptedException) {
                        runOnUiThread { result.error("CANCELLED", "cancelled", null) }
                    } catch (e: Throwable) {
                        runOnUiThread { result.error("ERR", e.toString(), null) }
                    } finally { upscaler = null }
                }.start()
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pixelfixo/media").setMethodCallHandler { call, result ->
            when (call.method) {
                "save" -> Thread {
                    try {
                        val u = save(call.argument<String>("path")!!, call.argument<String>("name")!!, call.argument<String>("mime")!!)
                        runOnUiThread { result.success(u) }
                    } catch (e: Throwable) { runOnUiThread { result.error("ERR", e.toString(), null) } }
                }.start()
                else -> result.notImplemented()
            }
        }
        shareCh = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pixelfixo/share").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "initial") { result.success(pendingShare); pendingShare = null } else result.notImplemented()
            }
        }
        pendingShare = sharedFile(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Thread {
            val p = sharedFile(intent) ?: return@Thread
            runOnUiThread { shareCh?.invokeMethod("shared", p) }
        }.start()
    }

    /** Copies a shared image into the cache and returns its path. */
    private fun sharedFile(i: Intent?): String? {
        if (i?.action != Intent.ACTION_SEND) return null
        @Suppress("DEPRECATION")
        val uri: Uri = (if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                        else i.getParcelableExtra(Intent.EXTRA_STREAM)) ?: return null
        return try {
            val f = File(cacheDir, "shared_${System.currentTimeMillis()}")
            contentResolver.openInputStream(uri)!!.use { s -> f.outputStream().use { s.copyTo(it) } }
            i.action = null
            f.absolutePath
        } catch (e: Throwable) { null }
    }

    private fun taken(coll: Uri, dir: String, name: String): Boolean {
        contentResolver.query(coll, arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?",
            arrayOf(name, "$dir/"), null)?.use { return it.count > 0 }
        return false
    }

    private fun freeName(base: String, exists: (String) -> Boolean): String {
        if (!exists(base)) return base
        val dot = base.lastIndexOf('.')
        val stem = if (dot > 0) base.substring(0, dot) else base
        val ext = if (dot > 0) base.substring(dot) else ""
        var n = 1
        while (exists("${stem}_$n$ext")) n++
        return "${stem}_$n$ext"
    }

    /** Saves into Pictures/Pixelfixo. Only a name and type are set, no title, description or location. */
    private fun save(path: String, base: String, mime: String): String {
        val dir = "${Environment.DIRECTORY_PICTURES}/Pixelfixo"
        if (Build.VERSION.SDK_INT >= 29) {
            val coll = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val name = freeName(base) { taken(coll, dir, it) }
            val v = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$dir/")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(coll, v) ?: throw Exception("MediaStore insert failed")
            contentResolver.openOutputStream(uri)!!.use { o -> FileInputStream(path).use { it.copyTo(o) } }
            v.clear(); v.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, v, null, null)
            return uri.toString()
        } else {
            @Suppress("DEPRECATION")
            val d = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "Pixelfixo").apply { mkdirs() }
            val f = File(d, freeName(base) { File(d, it).exists() })
            File(path).copyTo(f, overwrite = true)
            MediaScannerConnection.scanFile(this, arrayOf(f.absolutePath), arrayOf(mime), null)
            return f.absolutePath
        }
    }
}
