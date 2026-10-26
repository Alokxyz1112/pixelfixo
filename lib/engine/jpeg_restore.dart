import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Smarter JPEG decode for the upscaler.
///
/// A JPEG stores each 8x8 block as rounded (quantized) DCT numbers. The real picture could be anything that rounds
/// to those same numbers. A plain decoder picks the middle of every range, which is where the blocks, ringing and
/// smeared reds come from. Here we read those numbers straight from the file, smooth gently, and after every step
/// push each block back inside the ranges the file allows (projection onto the quantization intervals, the idea
/// behind Knusperli and jpeg2png). The result can never disagree with the file, so real grain and texture that
/// were actually stored stay put, only made up block edges go away.
///
/// Chroma (stored at half size in 4:2:0 files) is then brought to full size with a luma guided upsample instead
/// of the plain pixel doubling the Dart decoder does, so red edges follow the real edges instead of bleeding.

/// Orthonormal 8x8 DCT basis: _c[u*8+x].
final Float64List _c = () {
  final c = Float64List(64);
  for (var u = 0; u < 8; u++) {
    final a = u == 0 ? math.sqrt(1 / 8) : math.sqrt(2 / 8);
    for (var x = 0; x < 8; x++) {
      c[u * 8 + x] = a * math.cos((2 * x + 1) * u * math.pi / 16);
    }
  }
  return c;
}();

/// In place forward DCT of one 8x8 block (b) using tmp.
void _fdct(Float64List b, Float64List t) {
  for (var y = 0; y < 8; y++) {
    for (var u = 0; u < 8; u++) {
      var s = 0.0;
      for (var x = 0; x < 8; x++) {
        s += _c[u * 8 + x] * b[y * 8 + x];
      }
      t[y * 8 + u] = s;
    }
  }
  for (var u = 0; u < 8; u++) {
    for (var v = 0; v < 8; v++) {
      var s = 0.0;
      for (var y = 0; y < 8; y++) {
        s += _c[v * 8 + y] * t[y * 8 + u];
      }
      b[v * 8 + u] = s;
    }
  }
}

void _idct(Float64List b, Float64List t) {
  for (var v = 0; v < 8; v++) {
    for (var x = 0; x < 8; x++) {
      var s = 0.0;
      for (var u = 0; u < 8; u++) {
        s += _c[u * 8 + x] * b[v * 8 + u];
      }
      t[v * 8 + x] = s;
    }
  }
  for (var x = 0; x < 8; x++) {
    for (var y = 0; y < 8; y++) {
      var s = 0.0;
      for (var v = 0; v < 8; v++) {
        s += _c[v * 8 + y] * t[v * 8 + x];
      }
      b[y * 8 + x] = s;
    }
  }
}

/// One stored plane: quantized coefficients per block, the quant table and its size in pixels.
class _Plane {
  final int bw, bh; // blocks
  late final Int16List coef = Int16List(bw * bh * 64);
  final Int16List q;
  late final Float32List px = Float32List(bw * bh * 64);
  int get w => bw * 8;
  int get h => bh * 8;
  _Plane(this.bw, this.bh, this.q);

  /// Writes the block (bx,by) from DCT numbers d (natural order, dequantized) into px.
  void _put(int bx, int by, Float64List d) {
    for (var y = 0; y < 8; y++) {
      final o = (by * 8 + y) * w + bx * 8;
      for (var x = 0; x < 8; x++) {
        px[o + x] = d[y * 8 + x] + 128;
      }
    }
  }

  /// Reads the decoded 8 bit samples of this plane and works back to the exact stored DCT numbers: a forward DCT
  /// divided by the file's quant table and rounded lands on the integer the file holds (the decoder's 8 bit
  /// rounding is far smaller than half a quant step). Pixels clipped at pure black or white can be off by one step.
  void load(List<Uint8List?> lines) {
    final b = Float64List(64), t = Float64List(64);
    for (var by = 0; by < bh; by++) {
      for (var bx = 0; bx < bw; bx++) {
        for (var y = 0; y < 8; y++) {
          final line = lines[by * 8 + y]!;
          for (var x = 0; x < 8; x++) {
            b[y * 8 + x] = line[bx * 8 + x] - 128.0;
          }
        }
        _fdct(b, t);
        final o = (by * bw + bx) * 64;
        for (var i = 0; i < 64; i++) {
          final k = (b[i] / q[i]).round();
          coef[o + i] = k;
          b[i] = (k * q[i]).toDouble();
        }
        _idct(b, t);
        _put(bx, by, b);
      }
    }
  }

  /// Every block back inside the ranges the file allows.
  void project() {
    final b = Float64List(64), t = Float64List(64);
    for (var by = 0; by < bh; by++) {
      for (var bx = 0; bx < bw; bx++) {
        for (var y = 0; y < 8; y++) {
          final o = (by * 8 + y) * w + bx * 8;
          for (var x = 0; x < 8; x++) {
            b[y * 8 + x] = px[o + x] - 128;
          }
        }
        _fdct(b, t);
        final o = (by * bw + bx) * 64;
        for (var i = 0; i < 64; i++) {
          final qq = q[i], lo = (coef[o + i] - .5) * qq, hi = (coef[o + i] + .5) * qq;
          if (b[i] < lo) {
            b[i] = lo;
          } else if (b[i] > hi) {
            b[i] = hi;
          }
        }
        _idct(b, t);
        _put(bx, by, b);
      }
    }
  }

  /// Edge aware smoothing step: neighbours that differ by much more than [sigma] (a real edge) barely count.
  void smooth(double sigma, double lambda) {
    final src = Float32List.fromList(px);
    final inv = 1 / (sigma * sigma);
    for (var y = 0; y < h; y++) {
      final up = y > 0 ? -w : 0, dn = y < h - 1 ? w : 0;
      for (var x = 0; x < w; x++) {
        final i = y * w + x, v = src[i];
        final l = src[i + (x > 0 ? -1 : 0)] - v, r = src[i + (x < w - 1 ? 1 : 0)] - v;
        final u = src[i + up] - v, d = src[i + dn] - v;
        final wl = 1 / (1 + l * l * inv), wr = 1 / (1 + r * r * inv), wu = 1 / (1 + u * u * inv), wd = 1 / (1 + d * d * inv);
        px[i] = v + lambda * (wl * l + wr * r + wu * u + wd * d) / 4;
      }
    }
  }

  /// Typical step size of the low frequencies, used to tell block edges (small) from real edges (big).
  double get lowQ => (q[1] + q[8] + q[9] + q[2] + q[16]) / 5;
}

class RestoredRgb {
  final Uint8List rgb;
  final int w, h;
  final int orientation;
  const RestoredRgb(this.rgb, this.w, this.h, this.orientation);
}

/// Constrained decode of a baseline or progressive JPEG into RGB. Returns null for anything it does not handle
/// (CMYK, odd sampling, broken files), so the caller can fall back to the normal decoder.
/// [iterations] is the number of smooth+project rounds for luma (chroma gets twice as many, it is cheap).
/// Files over [maxPixels] are skipped (memory on phones); bigger files also get fewer rounds.
RestoredRgb? restoreJpeg(Uint8List bytes, {int? iterations, int maxPixels = 16000000}) {
  try {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
    final info = img.JpegData().readInfo(bytes);
    if (info == null) return null;
    final px = info.width * info.height;
    if (px > maxPixels) return null;
    iterations ??= px > 8000000 ? 1 : px > 4000000 ? 2 : 4;
    final jd = img.JpegData()..read(bytes);
    final f = jd.frame!;
    final n = f.componentsOrder.length;
    if (n != 1 && n != 3) return null;
    if (jd.adobe != null && jd.adobe!.transformCode == 0 && n == 3) return null; // RGB stored JPEG, rare
    final W = f.samplesPerLine!, H = f.scanLines!;
    final planes = <_Plane>[];
    final sh = <int>[], sv = <int>[];
    for (var k = 0; k < n; k++) {
      final c = f.components[f.componentsOrder[k]]!;
      final p = _Plane(c.blocksPerLine, c.blocksPerColumn, c.quantizationTable!)..load(jd.components[k].lines);
      planes.add(p);
      if (f.maxHSamples % c.hSamples != 0 || f.maxVSamples % c.vSamples != 0) return null;
      sh.add(f.maxHSamples ~/ c.hSamples);
      sv.add(f.maxVSamples ~/ c.vSamples);
    }
    if (sh[0] != 1 || sv[0] != 1) return null; // luma must be full size
    for (var k = 0; k < planes.length; k++) {
      final p = planes[k];
      final its = k == 0 ? iterations : iterations * 2;
      final sigma = math.max(2.0, p.lowQ * (k == 0 ? .6 : 1.0));
      for (var i = 0; i < its; i++) {
        p.smooth(sigma, 1.0);
        p.project();
      }
    }
    final yP = planes[0];
    final out = Uint8List(W * H * 3);
    if (n == 1) {
      for (var y = 0; y < H; y++) {
        for (var x = 0; x < W; x++) {
          final v = yP.px[y * yP.w + x].round().clamp(0, 255);
          final o = (y * W + x) * 3;
          out[o] = out[o + 1] = out[o + 2] = v;
        }
      }
    } else {
      final cb = _chromaUp(planes[1], sh[1], sv[1], yP, W, H);
      final cr = _chromaUp(planes[2], sh[2], sv[2], yP, W, H);
      for (var y = 0; y < H; y++) {
        for (var x = 0; x < W; x++) {
          final i = y * W + x, yy = yP.px[y * yP.w + x], b = cb[i] - 128, r = cr[i] - 128;
          final o = i * 3;
          out[o] = (yy + 1.402 * r).round().clamp(0, 255);
          out[o + 1] = (yy - .344136 * b - .714136 * r).round().clamp(0, 255);
          out[o + 2] = (yy + 1.772 * b).round().clamp(0, 255);
        }
      }
    }
    return RestoredRgb(out, W, H, jd.exif.imageIfd.orientation ?? 1);
  } catch (_) {
    return null;
  }
}

/// Chroma plane c (sx by sy smaller) to full W*H. Bilinear with JPEG's centred sample positions, then a joint
/// bilateral pass: each full size pixel takes its colour mostly from the low res samples whose brightness matches
/// its own, so colour stops at the same edges as brightness does (no red halo past a lip or a sign).
Float32List _chromaUp(_Plane c, int sx, int sy, _Plane yP, int W, int H) {
  final out = Float32List(W * H);
  if (sx == 1 && sy == 1) {
    for (var y = 0; y < H; y++) {
      for (var x = 0; x < W; x++) {
        out[y * W + x] = c.px[y * c.w + x];
      }
    }
    return out;
  }
  final cw = (W + sx - 1) ~/ sx, ch = (H + sy - 1) ~/ sy;
  // Luma averaged down to the chroma grid, to compare against.
  final yl = Float32List(cw * ch);
  for (var y = 0; y < ch; y++) {
    for (var x = 0; x < cw; x++) {
      var s = 0.0, k = 0;
      for (var dy = 0; dy < sy; dy++) {
        for (var dx = 0; dx < sx; dx++) {
          final py = y * sy + dy, px = x * sx + dx;
          if (py < H && px < W) {
            s += yP.px[py * yP.w + px];
            k++;
          }
        }
      }
      yl[y * cw + x] = s / k;
    }
  }
  const sr = 1 / (12.0 * 12.0);
  for (var y = 0; y < H; y++) {
    final fy = (y + .5) / sy - .5;
    final y0 = fy.floor();
    for (var x = 0; x < W; x++) {
      final fx = (x + .5) / sx - .5;
      final x0 = fx.floor();
      final yv = yP.px[y * yP.w + x];
      var acc = 0.0, ws = 0.0;
      for (var j = -1; j <= 2; j++) {
        final cy = (y0 + j).clamp(0, ch - 1);
        final wy = math.max(0.0, 1.5 - (fy - (y0 + j)).abs()) ;
        if (wy == 0) continue;
        for (var i = -1; i <= 2; i++) {
          final cx = (x0 + i).clamp(0, cw - 1);
          final wx = math.max(0.0, 1.5 - (fx - (x0 + i)).abs());
          if (wx == 0) continue;
          final d = yl[cy * cw + cx] - yv;
          final wgt = wx * wy / (1 + d * d * sr);
          acc += wgt * c.px[cy * c.w + cx];
          ws += wgt;
        }
      }
      out[y * W + x] = acc / ws;
    }
  }
  return out;
}

/// Restored RGB as an image with EXIF orientation applied, so rotated phone photos come out upright.
img.Image restoredImage(RestoredRgb r) {
  final im = img.Image.fromBytes(width: r.w, height: r.h, bytes: r.rgb.buffer, numChannels: 3, order: img.ChannelOrder.rgb);
  if (r.orientation == 1) return im;
  im.exif.imageIfd.orientation = r.orientation;
  return img.bakeOrientation(im);
}
