import 'dart:math' as math;
import 'dart:typed_data';

/// Finishing touches applied to a model's output so it still looks like the original photo, just bigger.
/// Everything here is plain math on RGB bytes, so it runs in a background isolate and is easy to test.

/// Standard JPEG luminance quantization table (Annex K), in zigzag order like the DQT segment stores it.
const _stdLuma = [
  16,
  11,
  12,
  14,
  12,
  10,
  16,
  14,
  13,
  14,
  18,
  17,
  16,
  19,
  24,
  40,
  26,
  24,
  22,
  22,
  24,
  49,
  35,
  37,
  29,
  40,
  58,
  51,
  61,
  60, //
  57,
  51,
  56,
  55,
  64,
  72,
  92,
  78,
  64,
  68,
  87,
  69,
  55,
  56,
  80,
  109,
  81,
  87,
  95,
  98,
  103,
  104,
  103,
  62,
  77,
  113,
  121,
  112, //
  100, 120, 92, 101, 103, 99,
];

/// Rough JPEG quality (1 to 100) read from the file's luminance quantization table, or null if it is not a JPEG
/// (PNG, WebP and so on). Uses the usual libjpeg scaling, so it matches what most encoders call "quality".
int? jpegQuality(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 4 < b.length) {
    if (b[i] != 0xFF) return null;
    final m = b[i + 1], len = (b[i + 2] << 8) | b[i + 3];
    if (m == 0xDA) break;
    if (m == 0xDB) {
      var p = i + 4;
      while (p < i + 2 + len) {
        final pq = b[p] >> 4, id = b[p] & 15;
        final n = pq == 0 ? 64 : 128;
        if (id == 0) {
          var sum = 0.0;
          for (var k = 0; k < 64; k++) {
            final v = pq == 0 ? b[p + 1 + k] : (b[p + 1 + 2 * k] << 8) | b[p + 2 + 2 * k];
            sum += v * 100 / _stdLuma[k];
          }
          final s = sum / 64;
          final q = s <= 100 ? (200 - s) / 2 : 5000 / s;
          return q.round().clamp(1, 100);
        }
        p += 1 + n;
      }
    }
    i += 2 + len;
  }
  return null;
}

/// Box blur on a float plane, run twice (close to a Gaussian). Radius 0 does nothing.
Float32List blurPlane(Float32List a, int w, int h, int r) {
  if (r <= 0) return Float32List.fromList(a);
  var src = Float32List.fromList(a);
  final tmp = Float32List(a.length);
  for (var pass = 0; pass < 2; pass++) {
    for (var y = 0; y < h; y++) {
      final o = y * w;
      var acc = 0.0;
      for (var k = -r; k <= r; k++) {
        acc += src[o + k.clamp(0, w - 1)];
      }
      for (var x = 0; x < w; x++) {
        tmp[o + x] = acc / (2 * r + 1);
        acc += src[o + (x + r + 1).clamp(0, w - 1)] - src[o + (x - r).clamp(0, w - 1)];
      }
    }
    for (var x = 0; x < w; x++) {
      var acc = 0.0;
      for (var k = -r; k <= r; k++) {
        acc += tmp[k.clamp(0, h - 1) * w + x];
      }
      for (var y = 0; y < h; y++) {
        src[y * w + x] = acc / (2 * r + 1);
        acc += tmp[(y + r + 1).clamp(0, h - 1) * w + x] - tmp[(y - r).clamp(0, h - 1) * w + x];
      }
    }
  }
  return src;
}

/// Is this YCbCr pixel in the usual skin range? Wide on purpose so every skin tone, light to very dark, counts.
bool isSkin(double y, double cb, double cr) => y > 40 && cr >= 135 && cr <= 172 && cb >= 80 && cb <= 125;

/// Options for [postProcess]. Plain values only so the record can cross isolates.
class PostOptions {
  final bool color; // pull tone and color back to the original's (fixes drift, whitening, orange shift)
  final double natural; // 0 = keep everything the model made, 0.25 = soften made-up detail by a quarter
  final bool grain; // add back fine grain matched to the original's noise
  final double vibrance; // 0 = off, 0.12 = gentle color restore (skin is mostly left alone)
  final bool lowQuality; // heavily compressed JPEG: smooth blocky color more, never bring back source detail
  const PostOptions({
    this.color = true,
    this.natural = 0.25,
    this.grain = false,
    this.vibrance = 0,
    this.lowQuality = false,
  });

  /// Adjusts for the source: a badly compressed JPEG gets stronger color cleanup and no grain, since its own
  /// "texture" is mostly compression noise.
  PostOptions forSource(int? jpegQ) => (jpegQ != null && jpegQ < 70)
      ? PostOptions(color: true, natural: natural, grain: false, vibrance: vibrance, lowQuality: true)
      : this;
}

/// Fixes up the raw model output [o] (ow x oh RGB, [scale] times the source) using the source [s] (w x h RGB).
///
/// 1. Color anchor: shrink the output back to the source size, measure how its brightness and color drifted from
///    the source (blurred, so only broad drift counts, not detail), and undo that drift at full size. Brightness is
///    matched over a wider area than color. The model keeps its sharp edges, the photo keeps its real colors.
/// 2. Natural: pull a share of the model's fine high frequency detail back toward a smooth version, which takes the
///    edge off crunchy or plastic looking texture.
/// 3. Grain and vibrance, both optional and mild.
Uint8List postProcess((Uint8List, int, int, Uint8List, int, int, int, PostOptions, int) a) {
  final (o, ow, oh, s, w, h, scale, opt, seed) = a;
  final n = ow * oh;
  final r = Float32List(n), g = Float32List(n), b = Float32List(n);
  for (var i = 0; i < n; i++) {
    r[i] = o[3 * i].toDouble();
    g[i] = o[3 * i + 1].toDouble();
    b[i] = o[3 * i + 2].toDouble();
  }
  if (opt.color) {
    // Area shrink of the output to source size, in YCbCr.
    final sn = w * h;
    final dy = Float32List(sn), dcb = Float32List(sn), dcr = Float32List(sn);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var rr = 0.0, gg = 0.0, bb = 0.0, c = 0;
        for (var yy = y * scale; yy < math.min((y + 1) * scale, oh); yy++) {
          for (var xx = x * scale; xx < math.min((x + 1) * scale, ow); xx++) {
            final k = yy * ow + xx;
            rr += r[k];
            gg += g[k];
            bb += b[k];
            c++;
          }
        }
        rr /= c;
        gg /= c;
        bb /= c;
        final j = y * w + x;
        final sr = s[3 * j].toDouble(), sg = s[3 * j + 1].toDouble(), sb = s[3 * j + 2].toDouble();
        dy[j] = (0.299 * (sr - rr) + 0.587 * (sg - gg) + 0.114 * (sb - bb));
        dcb[j] = (-0.168736 * (sr - rr) - 0.331264 * (sg - gg) + 0.5 * (sb - bb));
        dcr[j] = (0.5 * (sr - rr) - 0.418688 * (sg - gg) - 0.081312 * (sb - bb));
      }
    }
    final by = blurPlane(dy, w, h, opt.lowQuality ? 3 : 2),
        bcb = blurPlane(dcb, w, h, opt.lowQuality ? 2 : 1),
        bcr = blurPlane(dcr, w, h, opt.lowQuality ? 2 : 1);
    // Bilinear upsample of the drift, back to RGB, added on.
    for (var y = 0; y < oh; y++) {
      final fy = ((y + .5) / scale - .5).clamp(0.0, h - 1.0);
      final y0 = fy.floor(), y1 = math.min(y0 + 1, h - 1), ty = fy - y0;
      for (var x = 0; x < ow; x++) {
        final fx = ((x + .5) / scale - .5).clamp(0.0, w - 1.0);
        final x0 = fx.floor(), x1 = math.min(x0 + 1, w - 1), tx = fx - x0;
        double lerp(Float32List p) {
          final a0 = p[y0 * w + x0] * (1 - tx) + p[y0 * w + x1] * tx;
          final a1 = p[y1 * w + x0] * (1 - tx) + p[y1 * w + x1] * tx;
          return a0 * (1 - ty) + a1 * ty;
        }

        final ly = lerp(by), lcb = lerp(bcb), lcr = lerp(bcr);
        final k = y * ow + x;
        r[k] += ly + 1.402 * lcr;
        g[k] += ly - 0.344136 * lcb - 0.714136 * lcr;
        b[k] += ly + 1.772 * lcb;
      }
    }
  }
  if (opt.natural > 0) {
    final rad = math.max(1, (scale * 0.6).round());
    for (final p in [r, g, b]) {
      final bl = blurPlane(p, ow, oh, rad);
      for (var i = 0; i < n; i++) {
        p[i] -= opt.natural * (p[i] - bl[i]);
      }
    }
  }
  if (opt.vibrance > 0) {
    for (var i = 0; i < n; i++) {
      final y = 0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i];
      final cb = 128 - 0.168736 * r[i] - 0.331264 * g[i] + 0.5 * b[i];
      final cr = 128 + 0.5 * r[i] - 0.418688 * g[i] - 0.081312 * b[i];
      final c = math.sqrt((cb - 128) * (cb - 128) + (cr - 128) * (cr - 128));
      var f = opt.vibrance * (1 - math.min(c / 60, 1)); // dull colors get the most, already strong ones none
      if (isSkin(y, cb, cr)) f *= 0.25;
      final k = 1 + f;
      final ncb = (cb - 128) * k, ncr = (cr - 128) * k;
      r[i] = y + 1.402 * ncr;
      g[i] = y - 0.344136 * ncb - 0.714136 * ncr;
      b[i] = y + 1.772 * ncb;
    }
  }
  if (opt.grain) {
    final sigma = math.min(sourceNoise(s, w, h), 4.0) * 0.6;
    if (sigma > 0.2) {
      final rnd = math.Random(seed);
      final z = Float32List(n);
      for (var i = 0; i < n; i++) {
        z[i] = (rnd.nextDouble() + rnd.nextDouble() + rnd.nextDouble() - 1.5) * 2;
      }
      final zb = blurPlane(z, ow, oh, 1);
      for (var i = 0; i < n; i++) {
        final v = zb[i] * sigma * 2.2;
        r[i] += v;
        g[i] += v;
        b[i] += v;
      }
    }
  }
  final out = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    out[3 * i] = (r[i] + .5).clamp(0, 255).toInt();
    out[3 * i + 1] = (g[i] + .5).clamp(0, 255).toInt();
    out[3 * i + 2] = (b[i] + .5).clamp(0, 255).toInt();
  }
  return out;
}

/// Noise level of the source in 0..255 units (median absolute Laplacian, a common quick estimator).
double sourceNoise(Uint8List s, int w, int h) {
  if (w < 3 || h < 3) return 0;
  final v = <double>[];
  final step = math.max(1, (w * h / 40000).floor());
  var c = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      if (c++ % step != 0) continue;
      double l(int xx, int yy) {
        final k = (yy * w + xx) * 3;
        return 0.299 * s[k] + 0.587 * s[k + 1] + 0.114 * s[k + 2];
      }

      v.add((4 * l(x, y) - l(x - 1, y) - l(x + 1, y) - l(x, y - 1) - l(x, y + 1)).abs());
    }
  }
  v.sort();
  return v[v.length ~/ 2] / 2.5;
}

/// [postProcess] over horizontal bands so a 20 MP result never needs more than a few MB of float buffers.
/// Bands overlap by a margin wider than every blur, so the seams are invisible.
Uint8List postProcessBands(
  Uint8List o,
  int ow,
  int oh,
  Uint8List s,
  int w,
  int h,
  int scale,
  PostOptions opt, {
  int band = 48,
  int margin = 8,
}) {
  final out = Uint8List(o.length);
  for (var y0 = 0; y0 < h; y0 += band) {
    final y1 = math.min(h, y0 + band), a = math.max(0, y0 - margin), b = math.min(h, y1 + margin);
    final oa = a * scale, ob = math.min(oh, b * scale);
    final src = Uint8List.sublistView(s, a * w * 3, b * w * 3);
    final part = Uint8List.sublistView(o, oa * ow * 3, ob * ow * 3);
    final r = postProcess((part, ow, ob - oa, src, w, b - a, scale, opt, y0 + 1));
    final from = (y0 - a) * scale * ow * 3, to = (math.min(oh, y1 * scale) - oa) * ow * 3;
    out.setRange(y0 * scale * ow * 3, y0 * scale * ow * 3 + (to - from), r, from);
  }
  return out;
}
