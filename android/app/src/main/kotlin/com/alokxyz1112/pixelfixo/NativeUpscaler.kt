package com.alokxyz1112.pixelfixo

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.util.Log
import java.io.File
import java.nio.FloatBuffer
import java.util.Arrays
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Runs an upscale model over a raw RGB file tile by tile, in native code, so tile data never crosses the Flutter
 * channel. Backends are XNNPACK, then plain CPU.
 *
 * NNAPI is intentionally not used. On a lot of phones its driver aborts the process (a native crash) instead of
 * throwing, which closed the app the moment Fast mode started. A Java try/catch cannot catch that.
 *
 * The model always sees the full-resolution input. Each 4x tile is finished here:
 *  1. color anchor: broad brightness and color drift against the input is measured and undone,
 *  2. texture: a share of the input's own fine luma (grain, pores, hair) is added back,
 *  3. the tile is area-averaged to the requested output size (any scale up to 4).
 * Neighboring tiles overlap by a few pixels and are blended, so the joins do not show.
 */
class NativeUpscaler(private val progress: (Int, Int, String) -> Unit) {
    val cancel = AtomicBoolean(false)
    private val env = OrtEnvironment.getEnvironment()

    private fun open(model: String, backend: String, s: Int): OrtSession {
        val o = OrtSession.SessionOptions()
        try {
            val cores = Runtime.getRuntime().availableProcessors()
            // Phones have 4 or fewer fast cores. More threads than that make every tile wait on the slow cores.
            val threads = cores.coerceIn(1, 4)
            for (d in listOf("h", "w", "height", "width")) {
                try { o.setSymbolicDimensionValue(d, s.toLong()) } catch (_: Throwable) {}
            }
            for (d in listOf("batch_size", "batch")) {
                try { o.setSymbolicDimensionValue(d, 1L) } catch (_: Throwable) {}
            }
            o.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            o.setInterOpNumThreads(1)
            when (backend) {
                "xnnpack" -> {
                    o.addXnnpack(mapOf("intra_op_num_threads" to threads.toString()))
                    o.setIntraOpNumThreads(1)
                }
                else -> o.setIntraOpNumThreads(threads)
            }
            Log.i(TAG, "loading $backend tile $s")
            return env.createSession(model, o)
        } finally {
            try { o.close() } catch (_: Throwable) {}
        }
    }

    /** Keeps the last good session so a second run with the same model does not reload it. */
    private fun takeSession(model: String, backend: String, s: Int): OrtSession {
        val key = "$model|$backend|$s"
        val warm = kept
        if (warm != null && keptKey == key) return warm
        closeKept()
        val ses = open(model, backend, s)
        kept = ses
        keptKey = key
        return ses
    }

    private fun closeSession(ses: OrtSession?) {
        if (ses == null) return
        try { ses.close() } catch (_: Throwable) {}
        if (kept == ses) {
            kept = null
            keptKey = null
        }
    }

    /** Returns the backend that did the work. Output is outW x outH RGB (outW <= w*scale). */
    fun run(model: String, inPath: String, w: Int, h: Int, scale: Int, tile: Int, pad: Int, outPath: String,
            backends: List<String>, outW: Int = w * scale, outH: Int = h * scale, post: Boolean = false,
            lowQuality: Boolean = false, texture: Float = 0f, skin: Int = 0): Map<String, Any> {
        return synchronized(gate) {
        cancel.set(false)
        skinOk = true
        val rgb = File(inPath).readBytes()
        if (w < 1 || h < 1 || rgb.size < w * h * 3) throw IllegalArgumentException("bad input")
        val out = ByteArray(outW * outH * 3)
        var core = safeCore(tile, w, h)
        var attempt = 0
        var result: Map<String, Any>? = null
        while (result == null) {
            try {
                result = runTiles(model, rgb, w, h, scale, core, pad, outPath, backends, out, outW, outH, post, lowQuality, texture, skin)
            } catch (e: InterruptedException) {
                throw e
            } catch (e: OutOfMemoryError) {
                closeKept()
                System.gc()
                attempt++
                if (attempt >= 2 || core <= 96) {
                    throw IllegalStateException("OutOfMemory: not enough memory for this photo at this size. Try 2x or a smaller photo.")
                }
                core = (core / 2).coerceAtLeast(96)
                Arrays.fill(out, 0.toByte())
                Log.w(TAG, "out of memory, retrying at tile $core")
            }
        }
        checkNotNull(result)
        }
    }

    private fun runTiles(model: String, rgb: ByteArray, w: Int, h: Int, scale: Int, core: Int, pad: Int, outPath: String,
                         backends: List<String>, out: ByteArray, outW: Int, outH: Int, post: Boolean, lowQuality: Boolean,
                         texture: Float, skin: Int): Map<String, Any> {
        val fx = outW.toDouble() / w
        val fy = outH.toDouble() / h
        val s = core + 2 * pad
        var overlap = if (core >= 64 && (w > core || h > core)) minOf(8, core / 8) else 0
        // One byte of blend weight per output pixel. If that allocation fails, tiles still meet, they just are not blended.
        val weights: ByteArray? = if (overlap > 0) {
            try { ByteArray(outW * outH) } catch (e: OutOfMemoryError) { overlap = 0; null }
        } else null
        val tiles = buildTiles(w, h, core, overlap)
        val allowed = backends.map { it.lowercase() }.filter { it == "xnnpack" || it == "cpu" }
        val queue = ArrayDeque(if (allowed.isEmpty()) listOf("xnnpack", "cpu") else allowed)
        var name = queue.removeFirst()
        var ses: OrtSession? = null
        val t0 = System.nanoTime()
        val input = FloatBuffer.allocate(3 * s * s)
        val plane = s * s
        var i = 0
        var checked = false
        while (i < tiles.size) {
            if (cancel.get()) throw InterruptedException("cancelled")
            val t = tiles[i]
            input.clear()
            val arr = input.array()
            for (yy in 0 until s) {
                val sy = (t[1] - pad + yy).coerceIn(0, h - 1)
                for (xx in 0 until s) {
                    val sx = (t[0] - pad + xx).coerceIn(0, w - 1)
                    val p = (sy * w + sx) * 3
                    val o = yy * s + xx
                    arr[o] = (rgb[p].toInt() and 255) / 255f
                    arr[plane + o] = (rgb[p + 1].toInt() and 255) / 255f
                    arr[2 * plane + o] = (rgb[p + 2].toInt() and 255) / 255f
                }
            }
            val res: FloatArray
            try {
                if (ses == null) ses = takeSession(model, name, s)
                OnnxTensor.createTensor(env, input, longArrayOf(1, 3, s.toLong(), s.toLong())).use { x ->
                    ses!!.run(mapOf(ses!!.inputNames.first() to x)).use { r ->
                        val fb = (r[0] as OnnxTensor).floatBuffer
                        res = FloatArray(fb.remaining())
                        fb.get(res)
                    }
                }
                if (res.size != 3 * s * s * scale * scale) throw IllegalStateException("bad output size")
                if (!checked) {
                    sane(res, arr, s, scale)
                    checked = true
                }
            } catch (e: OutOfMemoryError) {
                closeSession(ses)
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "$name failed: ${e.message}")
                closeSession(ses)
                ses = null
                if (e is InterruptedException || queue.isEmpty()) throw e
                name = queue.removeFirst()
                checked = false
                continue
            }
            if (post) {
                // A failed finish still leaves a valid model tile, so one bad tile cannot blank the photo.
                try { finishTile(res, arr, s, scale, lowQuality, texture, skin) } catch (e: Throwable) { skinOk = false }
            }
            writeTile(res, s, scale, pad, t, out, w, h, outW, outH, fx, fy, weights, overlap)
            i++
            report(i, tiles.size, name)
        }
        File(outPath).writeBytes(out)
        return mapOf("backend" to name, "ms" to (System.nanoTime() - t0) / 1000000, "tiles" to tiles.size)
    }

    private fun report(done: Int, total: Int, backend: String) {
        try { progress(done, total, backend) } catch (_: Throwable) {}
    }

    /** Copies the tile's core into the output, area-averaging when the output is smaller than scale x, blending overlaps. */
    private fun writeTile(res: FloatArray, s: Int, scale: Int, pad: Int, t: IntArray, out: ByteArray, w: Int, h: Int, outW: Int, outH: Int,
                          fx: Double, fy: Double, weights: ByteArray?, overlap: Int) {
        val so = s * scale
        val po = so * so
        val x0 = Math.floor(t[0] * fx).toInt()
        val x1 = if (t[0] + t[2] >= w) outW else Math.floor((t[0] + t[2]) * fx).toInt()
        val y0 = Math.floor(t[1] * fy).toInt()
        val y1 = if (t[1] + t[3] >= h) outH else Math.floor((t[1] + t[3]) * fy).toInt()
        val kx = scale / fx
        val ky = scale / fy
        val offX = (t[0] - pad) * scale
        val offY = (t[1] - pad) * scale
        val ovX = (overlap * fx).toFloat().coerceAtLeast(1f)
        val ovY = (overlap * fy).toFloat().coerceAtLeast(1f)
        for (oy in y0 until minOf(y1, outH)) {
            val sy0 = oy * ky - offY
            val sy1 = (oy + 1) * ky - offY
            for (ox in x0 until minOf(x1, outW)) {
                val sx0 = ox * kx - offX
                val sx1 = (ox + 1) * kx - offX
                var r = 0.0
                var g = 0.0
                var b = 0.0
                var wsum = 0.0
                var yy = Math.floor(sy0).toInt()
                while (yy < sy1) {
                    val wy = minOf(yy + 1.0, sy1) - maxOf(yy.toDouble(), sy0)
                    val cy = yy.coerceIn(0, so - 1)
                    var xx = Math.floor(sx0).toInt()
                    while (xx < sx1) {
                        val wx = minOf(xx + 1.0, sx1) - maxOf(xx.toDouble(), sx0)
                        val k = cy * so + xx.coerceIn(0, so - 1)
                        val wgt = wx * wy
                        r += res[k] * wgt
                        g += res[po + k] * wgt
                        b += res[2 * po + k] * wgt
                        wsum += wgt
                        xx++
                    }
                    yy++
                }
                if (wsum <= 1e-6) continue
                val nr = (r / wsum).toFloat()
                val ng = (g / wsum).toFloat()
                val nb = (b / wsum).toFloat()
                val o = (oy * outW + ox) * 3
                if (weights == null) {
                    out[o] = q(nr)
                    out[o + 1] = q(ng)
                    out[o + 2] = q(nb)
                    continue
                }
                var feather = 1f
                if (t[0] > 0) feather = minOf(feather, ((ox - x0 + 0.5f) / ovX).coerceIn(0f, 1f))
                if (t[0] + t[2] < w) feather = minOf(feather, ((x1 - ox - 0.5f) / ovX).coerceIn(0f, 1f))
                if (t[1] > 0) feather = minOf(feather, ((oy - y0 + 0.5f) / ovY).coerceIn(0f, 1f))
                if (t[1] + t[3] < h) feather = minOf(feather, ((y1 - oy - 0.5f) / ovY).coerceIn(0f, 1f))
                val fresh = (feather.coerceAtLeast(0.02f) * 255f).toInt().coerceIn(1, 255)
                val idx = oy * outW + ox
                val old = weights[idx].toInt() and 255
                if (old == 0) {
                    out[o] = q(nr)
                    out[o + 1] = q(ng)
                    out[o + 2] = q(nb)
                } else {
                    val a = fresh.toFloat()
                    val bw = old.toFloat()
                    val sum = a + bw
                    out[o] = mix(out[o], nr, a, bw, sum)
                    out[o + 1] = mix(out[o + 1], ng, a, bw, sum)
                    out[o + 2] = mix(out[o + 2], nb, a, bw, sum)
                }
                weights[idx] = minOf(255, old + fresh).toByte()
            }
        }
    }

    private fun mix(prev: Byte, neu: Float, a: Float, b: Float, sum: Float): Byte {
        val pv = prev.toInt() and 255
        val nv = (neu * 255f + 0.5f).toInt().coerceIn(0, 255)
        return ((pv * b + nv * a) / sum).toInt().coerceIn(0, 255).toByte()
    }

    /** Color anchor and texture on one padded tile, in place on the model output (planes, 0..1). */
    private fun finishTile(res: FloatArray, inp: FloatArray, s: Int, scale: Int, lowQuality: Boolean, texture: Float, skin: Int = 0) {
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
        // Skin zones (any skin tone, from the input's own chroma): get a bit more of the real texture back.
        // The skin pass is a nice to have: if it ever fails (memory, a bad tile), the tile is finished without it.
        val sw = if (skin > 0 && skinOk) try { skinWeight(inp, s) } catch (e: Throwable) { skinOk = false; null } else null
        if (tex > 0f) { val lb = blur(luma, s, 1); for (j in 0 until n) {
            // Coring: drop tiny ripples (JPEG noise and block edges), keep real detail.
            val d = luma[j] - lb[j]; val m = Math.abs(d) - CORE
            val t = if (sw != null) tex * (1f + SKIN_BOOST * sw[j]) else tex
            hf[j] = if (m > 0f) Math.copySign(m, d) * t else 0f
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
        if (skin >= 2 && sw != null && skinOk) {
            // Edits are only applied in the last loop, so a failure part way leaves a normal finished tile.
            try { softenSkinEdges(res, luma, sw, s, scale) } catch (e: Throwable) { skinOk = false }
        }
    }

    /** Soft 0..1 skin weight per input pixel. BT.601 8-bit Cb 80..125, Cr 133..173 with a Gaussian falloff
     *  (sigma 6), which covers light, brown and dark skin. Very dark pixels fade out. */
    private fun skinWeight(inp: FloatArray, s: Int): FloatArray {
        val n = s * s; val w = FloatArray(n)
        fun soft(v: Float, lo: Float, hi: Float): Float { val d = maxOf(lo - v, 0f) + maxOf(v - hi, 0f); return Math.exp((-d * d / 72f).toDouble()).toFloat() }
        for (j in 0 until n) {
            val r = inp[j] * 255f; val g = inp[n + j] * 255f; val b = inp[2 * n + j] * 255f
            val y = 0.299f * r + 0.587f * g + 0.114f * b
            val cb = 128f - 0.168736f * r - 0.331264f * g + 0.5f * b
            val cr = 128f + 0.5f * r - 0.418688f * g - 0.081312f * b
            w[j] = soft(cb, 80f, 125f) * soft(cr, 133f, 173f) * ((y - 12f) / 20f).coerceIn(0f, 1f)
        }
        return blur(w, s, 1)
    }

    /** On skin, pulls a small share of the plain (bicubic) input luma back in on strong edges only, so lashes,
     *  brows and beard outlines stop looking inked on. Flat skin and its texture are left alone. */
    private fun softenSkinEdges(res: FloatArray, luma: FloatArray, sw: FloatArray, s: Int, scale: Int) {
        val so = s * scale; val po = so * so
        val y = FloatArray(po); for (k in 0 until po) y[k] = 0.299f * res[k] + 0.587f * res[po + k] + 0.114f * res[2 * po + k]
        val e = FloatArray(po)
        for (yy in 1 until so - 1) for (xx in 1 until so - 1) {
            val k = yy * so + xx
            val gx = y[k + 1] - y[k - 1]; val gy = y[k + so] - y[k - so]
            var t = ((Math.sqrt((gx * gx + gy * gy).toDouble()).toFloat() * 0.5f - EDGE_LO) / (EDGE_HI - EDGE_LO)).coerceIn(0f, 1f)
            e[k] = t * t * (3f - 2f * t)
        }
        val eb = blur(e, so, 1)
        // Catmull-Rom weights for the 4 phases of a 4x upscale.
        val cw = Array(scale) { p -> val t = ((p + .5f) / scale - .5f).let { it - Math.floor(it.toDouble()).toFloat() }
            fun k(x0: Float): Float { val x = Math.abs(x0); return if (x < 1) 1.5f * x * x * x - 2.5f * x * x + 1 else if (x < 2) -.5f * x * x * x + 2.5f * x * x - 4 * x + 2 else 0f }
            floatArrayOf(k(t + 1), k(t), k(1 - t), k(2 - t)) }
        val rows = FloatArray(so * s) // vertical pass: so rows x s cols
        for (yy in 0 until so) { val f = (yy + .5f) / scale - .5f; val i = Math.floor(f.toDouble()).toInt(); val w = cw[yy % scale]
            for (x in 0 until s) { var a = 0f; for (d in 0..3) a += w[d] * luma[(i + d - 1).coerceIn(0, s - 1) * s + x]; rows[yy * s + x] = a } }
        for (yy in 0 until so) {
            val fy = ((yy + .5f) / scale - .5f).coerceIn(0f, s - 1f); val y0 = fy.toInt(); val y1 = minOf(y0 + 1, s - 1); val ty = fy - y0
            for (xx in 0 until so) {
                val k = yy * so + xx; if (eb[k] <= 0f) continue
                val fx = ((xx + .5f) / scale - .5f).coerceIn(0f, s - 1f); val x0 = fx.toInt(); val x1 = minOf(x0 + 1, s - 1); val tx = fx - x0
                val wk = (sw[y0 * s + x0] * (1 - tx) + sw[y0 * s + x1] * tx) * (1 - ty) + (sw[y1 * s + x0] * (1 - tx) + sw[y1 * s + x1] * tx) * ty
                val a = EDGE_BLEND * wk * eb[k]; if (a <= 0f) continue
                val f = (xx + .5f) / scale - .5f; val i = Math.floor(f.toDouble()).toInt(); val w = cw[xx % scale]
                var ref = 0f; for (d in 0..3) ref += w[d] * rows[yy * s + (i + d - 1).coerceIn(0, s - 1)]
                val dl = a * (ref - y[k]); res[k] += dl; res[po + k] += dl; res[2 * po + k] += dl
            }
        }
    }

    @Volatile private var skinOk = true
    private val SKIN_BOOST = 0.25f // 1.25x texture on skin
    private val EDGE_BLEND = 0.15f
    private val EDGE_LO = 0.015f; private val EDGE_HI = 0.05f

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

    companion object {
        private const val TAG = "Pixelfixo"
        private val gate = Any()
        private var kept: OrtSession? = null
        private var keptKey: String? = null

        private fun closeKept() {
            val s = kept
            kept = null
            keptKey = null
            try { s?.close() } catch (_: Throwable) {}
        }

        /** Largest tile edge that should fit the process heap. Big heaps keep the model's own tile. */
        fun safeCore(tile: Int, w: Int, h: Int): Int {
            var core = minOf(tile.coerceAtLeast(1), maxOf(w, h)).coerceAtLeast(1)
            val budget = Runtime.getRuntime().maxMemory()
            if (budget < 192L * 1024 * 1024) core = minOf(core, 96)
            else if (budget < 320L * 1024 * 1024) core = minOf(core, 160)
            return core
        }

        /** Tile starts along one axis. The last tile is pulled back so the far edge is covered. Same rule as tileOrigins in Dart. */
        fun origins(length: Int, tile: Int, overlap: Int): IntArray {
            if (length <= tile) return intArrayOf(0)
            val step = (tile - overlap).coerceAtLeast(1)
            val out = ArrayList<Int>()
            var p = 0
            while (p + tile < length) {
                out.add(p)
                p += step
            }
            val last = length - tile
            if (out.isEmpty() || out.last() != last) out.add(last)
            return out.toIntArray()
        }

        fun buildTiles(w: Int, h: Int, core: Int, overlap: Int): ArrayList<IntArray> {
            val tiles = ArrayList<IntArray>()
            if (overlap <= 0) {
                var y = 0
                while (y < h) {
                    var x = 0
                    while (x < w) {
                        tiles.add(intArrayOf(x, y, minOf(core, w - x), minOf(core, h - y)))
                        x += core
                    }
                    y += core
                }
                return tiles
            }
            for (yy in origins(h, core, overlap)) {
                for (xx in origins(w, core, overlap)) {
                    tiles.add(intArrayOf(xx, yy, minOf(core, w - xx), minOf(core, h - yy)))
                }
            }
            return tiles
        }
    }
}
