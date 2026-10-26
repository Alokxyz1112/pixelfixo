package com.alokxyz1112.pixelfixo

import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.util.Log
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/**
 * Runs [NativeUpscaler] in a separate process (`:upscale`).
 *
 * ONNX Runtime backends (XNNPACK, some CPU paths, and the old NNAPI path) can abort the whole process with a
 * native SIGSEGV instead of throwing. Java try/catch cannot catch that. If it happens here, the UI process stays
 * up, we remember to skip XNNPACK, and the same photo is retried on plain CPU.
 */
class UpscaleService : Service() {
    companion object {
        const val MSG_RUN = 1
        const val MSG_CANCEL = 2
        const val MSG_PROGRESS = 3
        const val MSG_DONE = 4
        const val MSG_ERROR = 5
        private const val TAG = "Pixelfixo"
    }

    private lateinit var worker: HandlerThread
    private lateinit var messenger: Messenger
    private var upscaler: NativeUpscaler? = null

    override fun onCreate() {
        super.onCreate()
        worker = HandlerThread("upscale", Process.THREAD_PRIORITY_FOREGROUND)
        worker.start()
        messenger = Messenger(Incoming(worker.looper))
    }

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        upscaler?.cancel?.set(true)
        worker.quitSafely()
        super.onDestroy()
    }

    private inner class Incoming(looper: Looper) : Handler(looper) {
        override fun handleMessage(msg: Message) {
            when (msg.what) {
                MSG_CANCEL -> upscaler?.cancel?.set(true)
                MSG_RUN -> runJob(msg)
                else -> super.handleMessage(msg)
            }
        }

        private fun runJob(msg: Message) {
            val reply = msg.replyTo
            val b = msg.data
            try {
                val u = NativeUpscaler { d, t, be ->
                    val m = Message.obtain(null, MSG_PROGRESS)
                    m.data = Bundle().apply {
                        putInt("done", d)
                        putInt("total", t)
                        putString("backend", be)
                    }
                    try { reply.send(m) } catch (_: Throwable) {}
                }
                upscaler = u
                val r = u.run(
                    b.getString("model")!!,
                    b.getString("input")!!,
                    b.getInt("w"),
                    b.getInt("h"),
                    b.getInt("scale"),
                    b.getInt("tile"),
                    b.getInt("pad"),
                    b.getString("output")!!,
                    b.getStringArrayList("backends") ?: arrayListOf("cpu"),
                    b.getInt("outW"),
                    b.getInt("outH"),
                    b.getBoolean("post"),
                    b.getBoolean("lowQuality"),
                    b.getFloat("texture"),
                    b.getInt("skin"),
                )
                val m = Message.obtain(null, MSG_DONE)
                m.data = Bundle().apply {
                    putString("backend", r["backend"] as String)
                    putLong("ms", (r["ms"] as Number).toLong())
                    putInt("tiles", (r["tiles"] as Number).toInt())
                }
                reply.send(m)
            } catch (e: InterruptedException) {
                sendErr(reply, "CANCELLED", "cancelled")
            } catch (e: Throwable) {
                Log.w(TAG, "engine error", e)
                sendErr(reply, "ERR", e.toString())
            } finally {
                upscaler = null
            }
        }

        private fun sendErr(reply: Messenger?, code: String, message: String) {
            if (reply == null) return
            val m = Message.obtain(null, MSG_ERROR)
            m.data = Bundle().apply {
                putString("code", code)
                putString("message", message)
            }
            try { reply.send(m) } catch (_: Throwable) {}
        }
    }
}

internal object UpscaleClient {
    private const val TAG = "Pixelfixo"
    private const val PREFS = "pixelfixo"
    private const val SKIP_XNNPACK = "skip_xnnpack"

    @Volatile private var engine: Messenger? = null

    fun cancel() {
        try { engine?.send(Message.obtain(null, UpscaleService.MSG_CANCEL)) } catch (_: Throwable) {}
    }

    fun run(ctx: Context, args: Bundle, onProgress: (Int, Int, String) -> Unit): Map<String, Any> {
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        var backends = args.getStringArrayList("backends") ?: arrayListOf("xnnpack", "cpu")
        if (prefs.getBoolean(SKIP_XNNPACK, false)) {
            backends = ArrayList(backends.filter { it.lowercase() != "xnnpack" })
            if (backends.isEmpty()) backends.add("cpu")
            Log.i(TAG, "skipping XNNPACK after an earlier native crash")
        }
        onProgress(0, 1, "load")
        val first = runOnce(ctx, args, backends, onProgress)
        if (first != null) return first
        prefs.edit().putBoolean(SKIP_XNNPACK, true).apply()
        Log.w(TAG, "engine process died, retrying on CPU")
        onProgress(0, 1, "cpu")
        return runOnce(ctx, args, arrayListOf("cpu"), onProgress)
            ?: throw IllegalStateException("The upscaler closed while working. Try 2x or a smaller photo.")
    }

    private fun runOnce(ctx: Context, args: Bundle, backends: ArrayList<String>, onProgress: (Int, Int, String) -> Unit): Map<String, Any>? {
        val done = CompletableFuture<Map<String, Any>?>()
        val reply = Messenger(Handler(Looper.getMainLooper()) { msg ->
            when (msg.what) {
                UpscaleService.MSG_PROGRESS -> onProgress(
                    msg.data.getInt("done"),
                    msg.data.getInt("total"),
                    msg.data.getString("backend") ?: "",
                )
                UpscaleService.MSG_DONE -> {
                    val d = msg.data
                    done.complete(mapOf(
                        "backend" to (d.getString("backend") ?: "cpu"),
                        "ms" to d.getLong("ms"),
                        "tiles" to d.getInt("tiles"),
                    ))
                }
                UpscaleService.MSG_ERROR -> {
                    val code = msg.data.getString("code") ?: "ERR"
                    val message = msg.data.getString("message") ?: "error"
                    if (code == "CANCELLED") done.completeExceptionally(InterruptedException("cancelled"))
                    else done.completeExceptionally(IllegalStateException(message))
                }
            }
            true
        })
        val conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                val outgoing = Messenger(binder)
                engine = outgoing
                val m = Message.obtain(null, UpscaleService.MSG_RUN)
                m.data = Bundle(args).apply { putStringArrayList("backends", backends) }
                m.replyTo = reply
                try {
                    outgoing.send(m)
                } catch (e: Throwable) {
                    done.complete(null)
                }
            }
            override fun onServiceDisconnected(name: ComponentName?) {
                engine = null
                done.complete(null)
            }
        }
        val app = ctx.applicationContext
        val ok = app.bindService(Intent(app, UpscaleService::class.java), conn, Context.BIND_AUTO_CREATE)
        if (!ok) throw IllegalStateException("Could not start the upscaler")
        try {
            return done.get(30, TimeUnit.MINUTES)
        } catch (e: java.util.concurrent.TimeoutException) {
            throw IllegalStateException("The upscaler took too long. Try 2x or a smaller photo.")
        } catch (e: java.util.concurrent.ExecutionException) {
            val c = e.cause
            if (c is InterruptedException) throw c
            if (c is RuntimeException) throw c
            throw IllegalStateException(c?.message ?: e.message)
        } finally {
            engine = null
            try { app.unbindService(conn) } catch (_: Throwable) {}
        }
    }
}
