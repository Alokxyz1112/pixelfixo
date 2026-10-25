package com.alokxyz1112.pixelfixo

import ai.onnxruntime.providers.NNAPIFlags
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.File
import java.nio.FloatBuffer
import java.util.EnumSet
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Runs an upscale model over a raw RGB file tile by tile, all in native code, so tile data never has to cross the
 * Flutter channel. Tries NNAPI (fp16 allowed) first, then XNNPACK on every core, then plain CPU. A backend that
 * throws or hands back garbage (NaN, or a tile that no longer looks like its input) is dropped and the next one
 * takes over from the same tile.
 */
class NativeUpscaler(private val progress: (Int, Int, String) -> Unit) {
    val cancel = AtomicBoolean(false)
    private val env = OrtEnvironment.getEnvironment()

    private fun open(model: String, backend: String, s: Int): OrtSession {
        val o = OrtSession.SessionOptions()
        val cores = Runtime.getRuntime().availableProcessors().coerceIn(1, 8)
        o.setSymbolicDimensionValue("h", s.toLong())
        o.setSymbolicDimensionValue("w", s.toLong())
        o.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        when (backend) {
            "nnapi" -> { o.addNnapi(EnumSet.of(NNAPIFlags.USE_FP16)); o.setIntraOpNumThreads(cores) }
            "xnnpack" -> { o.addXnnpack(mapOf("intra_op_num_threads" to cores.toString())); o.setIntraOpNumThreads(1) }
            else -> o.setIntraOpNumThreads(cores)
        }
        return env.createSession(model, o)
    }

    /** Returns the backend that did the work. */
    fun run(model: String, inPath: String, w: Int, h: Int, scale: Int, tile: Int, pad: Int, outPath: String,
            backends: List<String>): Map<String, Any> {
        cancel.set(false)
        val rgb = File(inPath).readBytes()
        val out = ByteArray(w * scale * h * scale * 3)
        val core = minOf(tile, maxOf(w, h))
        val s = core + 2 * pad
        val tiles = ArrayList<IntArray>()
        var y = 0
        while (y < h) { var x = 0; while (x < w) { tiles.add(intArrayOf(x, y, minOf(core, w - x), minOf(core, h - y))); x += core }; y += core }
        val queue = ArrayDeque(backends)
        var name = queue.removeFirst()
        var ses: OrtSession? = null
        val t0 = System.nanoTime()
        val input = FloatBuffer.allocate(3 * s * s)
        val plane = s * s
        var i = 0
        var checked = false
        while (i < tiles.size) {
            if (cancel.get()) { ses?.close(); throw InterruptedException("cancelled") }
            val t = tiles[i]
            input.clear()
            val arr = input.array()
            for (yy in 0 until s) {
                val sy = (t[1] - pad + yy).coerceIn(0, h - 1)
                for (xx in 0 until s) {
                    val sx = (t[0] - pad + xx).coerceIn(0, w - 1)
                    val p = (sy * w + sx) * 3; val o = yy * s + xx
                    arr[o] = (rgb[p].toInt() and 255) / 255f
                    arr[plane + o] = (rgb[p + 1].toInt() and 255) / 255f
                    arr[2 * plane + o] = (rgb[p + 2].toInt() and 255) / 255f
                }
            }
            val res: FloatArray
            try {
                if (ses == null) ses = open(model, name, s)
                OnnxTensor.createTensor(env, input, longArrayOf(1, 3, s.toLong(), s.toLong())).use { x ->
                    ses!!.run(mapOf(ses!!.inputNames.first() to x)).use { r ->
                        val fb = (r[0] as OnnxTensor).floatBuffer
                        res = FloatArray(fb.remaining()); fb.get(res)
                    }
                }
                if (res.size != 3 * s * s * scale * scale) throw IllegalStateException("bad output size")
                if (!checked) { sane(res, arr, s, scale); checked = true }
            } catch (e: Exception) {
                ses?.close(); ses = null
                if (e is InterruptedException || queue.isEmpty()) throw e
                name = queue.removeFirst(); checked = false
                continue // same tile again on the next backend
            }
            val so = s * scale; val po = so * so; val px = pad * scale; val ow = w * scale
            for (yy in 0 until t[3] * scale) {
                val row = ((t[1] * scale + yy) * ow + t[0] * scale) * 3
                val src = (yy + px) * so + px
                for (xx in 0 until t[2] * scale) {
                    val o = row + xx * 3; val k = src + xx
                    out[o] = q(res[k]); out[o + 1] = q(res[po + k]); out[o + 2] = q(res[2 * po + k])
                }
            }
            i++
            progress(i, tiles.size, name)
        }
        ses?.close()
        File(outPath).writeBytes(out)
        return mapOf("backend" to name, "ms" to (System.nanoTime() - t0) / 1000000, "tiles" to tiles.size)
    }

    private fun q(v: Float): Byte { val x = (v * 255f + .5f).toInt(); return (if (x < 0) 0 else if (x > 255) 255 else x).toByte() }

    /** NaN, or an output that drifted far from its own input once shrunk back, means the backend is broken here. */
    private fun sane(res: FloatArray, inp: FloatArray, s: Int, scale: Int) {
        val so = s * scale; var err = 0.0; var n = 0
        for (c in 0 until 3) for (yy in 0 until s step 4) for (xx in 0 until s step 4) {
            val v = res[c * so * so + (yy * scale + scale / 2) * so + xx * scale + scale / 2]
            if (v.isNaN()) throw IllegalStateException("NaN")
            err += Math.abs(v - inp[c * s * s + yy * s + xx]); n++
        }
        if (err / n > 0.12) throw IllegalStateException("garbage output")
    }
}
