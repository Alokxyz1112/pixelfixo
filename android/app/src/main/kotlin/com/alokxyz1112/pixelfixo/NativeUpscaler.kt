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
 * Flutter channel. Backends are tried in the order given (NNAPI fp16, XNNPACK, plain CPU). A backend that throws or
 * hands back garbage (NaN, or a tile that no longer looks like its input) is dropped and the next one takes over
 * from the same tile.
 *
 * The model always works on the full resolution input. Each 4x tile is finished right here:
 *  1. color anchor: broad brightness and color drift against the input is measured and undone (fine detail is kept),
 *  2. texture: a share of the input's own fine luma detail (grain, pores, hair) is added back, so the result is
 *     not waxy,
 *  3. the tile is area averaged down to the requested output size (any scale up to 4), so a big photo never has
 *     to be shrunk before the model sees it.
 */
class NativeUpscaler(private val progress: (Int, Int, String) -> Unit) {
    val cancel = AtomicBoolean(false)
    private val env = OrtEnvironment.getEnvironment()

    private fun open(model: String, backend: String, s: Int): OrtSession {
        val o = OrtSession.SessionOptions()
        val cores = Runtime.getRuntime().availableProcessors()
        // Phones have 4 or fewer fast cores. More threads than that make every tile wait for the slow cores.
        val threads = cores.coerceIn(1, 4)
        for (d in listOf("h", "w", "height", "width")) o.setSymbolicDimensionValue(d, s.toLong())
        o.setSymbolicDimensionValue("batch_size", 1)
        o.setSymbolicDimensionValue("batch", 1)
        o.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        when (backend) {
            "nnapi" -> { o.addNnapi(EnumSet.of(NNAPIFlags.USE_FP16, NNAPIFlags.CPU_DISABLED)); o.setIntraOpNumThreads(threads) }
            "xnnpack" -> { o.addXnnpack(mapOf("intra_op_num_threads" to threads.toString())); o.setIntraOpNumThreads(1) }
            else -> o.setIntraOpNumThreads(threads)
        }
        return env.createSession(model, o)
    }

    /** Returns the backend that did the work. Output is outW x outH RGB (outW <= w*scale). */
    fun run(model: String, inPath: String, w: Int, h: Int, scale: Int, tile: Int, pad: Int, outPath: String,
            backends: List<String>, outW: Int = w * scale, outH: Int = h * scale, post: Boolean = false,
            lowQuality: Boolean = false, texture: Float = 0f): Map<String, Any> {
        cancel.set(false)
        val rgb = File(inPath).readBytes()
        val out = ByteArray(outW * outH * 3)
        val fx = outW.toDouble() / w; val fy = outH.toDouble() / h // output pixels per input pixel
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
            if (post) finishTile(res, arr, s, scale, lowQuality, texture)
            writeTile(res, s, scale, pad, t, out, w, h, outW, outH, fx, fy)
            i++
            progress(i, tiles.size, name)
        }
        ses?.close()
        File(outPath).writeBytes(out)
        return mapOf("backend" to name, "ms" to (System.nanoTime() - t0) / 1000000, "tiles" to tiles.size)
    }

    /** Copies the tile's core into the output, area averaging when the output is smaller than scale x. */
    private fun writeTile(res: FloatArray, s: Int, scale: Int, pad: Int, t: IntArray, out: ByteArray, w: Int, h: Int, outW: Int, outH: Int,
                          fx: Double, fy: Double) {
        val so = s * scale; val po = so * so
        val x0 = Math.floor(t[0] * fx).toInt(); val x1 = if (t[0] + t[2] >= w) outW else Math.floor((t[0] + t[2]) * fx).toInt()
        val y0 = Math.floor(t[1] * fy).toInt(); val y1 = if (t[1] + t[3] >= h) outH else Math.floor((t[1] + t[3]) * fy).toInt()
        val kx = scale / fx; val ky = scale / fy // 4x pixels per output pixel (>= 1)
        // Position in tile-local 4x coordinates (including pad) of global 4x coordinate g.
        val offX = (t[0] - pad) * scale; val offY = (t[1] - pad) * scale
        for (oy in y0 until minOf(y1, outH)) {
            val sy0 = oy * ky - offY; val sy1 = (oy + 1) * ky - offY
            for (ox in x0 until minOf(x1, outW)) {
                val sx0 = ox * kx - offX; val sx1 = (ox + 1) * kx - offX
                var r = 0.0; var g = 0.0; var b = 0.0; var wsum = 0.0
                var yy = Math.floor(sy0).toInt()
                while (yy < sy1) {
                    val wy = minOf(yy + 1.0, sy1) - maxOf(yy.toDouble(), sy0)
                    val cy = yy.coerceIn(0, so - 1)
                    var xx = Math.floor(sx0).toInt()
                    while (xx < sx1) {
                        val wx = minOf(xx + 1.0, sx1) - maxOf(xx.toDouble(), sx0)
                        val k = cy * so + xx.coerceIn(0, so - 1); val wgt = wx * wy
                        r += res[k] * wgt; g += res[po + k] * wgt; b += res[2 * po + k] * wgt; wsum += wgt
                        xx++
                    }
                    yy++
                }
                val o = (oy * outW + ox) * 3
                out[o] = q((r / wsum).toFloat()); out[o + 1] = q((g / wsum).toFloat()); out[o + 2] = q((b / wsum).toFloat())
            }
        }
    }

    /** Color anchor and texture on one padded tile, in place on the model output (planes, 0..1). */
    private fun finishTile(res: FloatArray, inp: FloatArray, s: Int, scale: Int, lowQuality: Boolean, texture: Float) {
        val so = s * scale; val po = so * so; val n = s * s
        val dy = FloatArray(n); val dcb = FloatArray(n); val dcr = FloatArray(n); val luma = FloatArray(n)
        val inv = 1f / (scale * scale)
        for (y in 0 until s) for (x in 0 until s) {
            var r = 0f; var g = 0f; var b = 0f
            for (yy in y * scale until (y + 1) * scale) for (xx in x * scale until (x + 1) * scale) {
                val k = yy * so + xx; r += res[k]; g += res[po + k]; b += res[2 * po + k]
            }
            val j = y * s + x
            val er = inp[j] - r * inv; val eg = inp[n + j] - g * inv; val eb = inp[2 * n + j] - b * inv
            dy[j] = 0.299f * er + 0.587f * eg + 0.114f * eb
            dcb[j] = -0.168736f * er - 0.331264f * eg + 0.5f * eb
            dcr[j] = 0.5f * er - 0.418688f * eg - 0.081312f * eb
            luma[j] = 0.299f * inp[j] + 0.587f * inp[n + j] + 0.114f * inp[2 * n + j]
        }
        val by = blur(dy, s, if (lowQuality) 3 else 2)
        val bcb = blur(dcb, s, if (lowQuality) 2 else 1)
        val bcr = blur(dcr, s, if (lowQuality) 2 else 1)
        val tex = if (lowQuality) texture * 0.4f else texture
        val hf = FloatArray(n)
        if (tex > 0f) { val lb = blur(luma, s, 1); for (j in 0 until n) {
            // Coring: drop tiny ripples (JPEG noise and block edges), keep real detail.
            val d = luma[j] - lb[j]; val m = Math.abs(d) - CORE
            hf[j] = if (m > 0f) Math.copySign(m, d) * tex else 0f
        } }
        for (y in 0 until so) {
            val fy = ((y + .5f) / scale - .5f).coerceIn(0f, s - 1f)
            val y0 = fy.toInt(); val y1 = minOf(y0 + 1, s - 1); val ty = fy - y0
            for (x in 0 until so) {
                val fx = ((x + .5f) / scale - .5f).coerceIn(0f, s - 1f)
                val x0 = fx.toInt(); val x1 = minOf(x0 + 1, s - 1); val tx = fx - x0
                val a = y0 * s + x0; val b2 = y0 * s + x1; val c = y1 * s + x0; val d = y1 * s + x1
                val w00 = (1 - tx) * (1 - ty); val w01 = tx * (1 - ty); val w10 = (1 - tx) * ty; val w11 = tx * ty
                val ly = by[a] * w00 + by[b2] * w01 + by[c] * w10 + by[d] * w11 + hf[a] * w00 + hf[b2] * w01 + hf[c] * w10 + hf[d] * w11
                val lcb = bcb[a] * w00 + bcb[b2] * w01 + bcb[c] * w10 + bcb[d] * w11
                val lcr = bcr[a] * w00 + bcr[b2] * w01 + bcr[c] * w10 + bcr[d] * w11
                val k = y * so + x
                res[k] += ly + 1.402f * lcr
                res[po + k] += ly - 0.344136f * lcb - 0.714136f * lcr
                res[2 * po + k] += ly + 1.772f * lcb
            }
        }
    }

    private val CORE = 2f / 255f

    /** Box blur run twice (close to a Gaussian), edges repeat. */
    private fun blur(a: FloatArray, s: Int, r: Int): FloatArray {
        var src = a.copyOf(); val tmp = FloatArray(a.size); val d = 2f * r + 1
        repeat(2) {
            for (y in 0 until s) { val o = y * s; var acc = 0f
                for (k in -r..r) acc += src[o + k.coerceIn(0, s - 1)]
                for (x in 0 until s) { tmp[o + x] = acc / d; acc += src[o + (x + r + 1).coerceIn(0, s - 1)] - src[o + (x - r).coerceIn(0, s - 1)] } }
            val nx = FloatArray(a.size)
            for (x in 0 until s) { var acc = 0f
                for (k in -r..r) acc += tmp[k.coerceIn(0, s - 1) * s + x]
                for (y in 0 until s) { nx[y * s + x] = acc / d; acc += tmp[(y + r + 1).coerceIn(0, s - 1) * s + x] - tmp[(y - r).coerceIn(0, s - 1) * s + x] } }
            src = nx
        }
        return src
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
