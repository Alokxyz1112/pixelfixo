import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelfixo/engine/upscale.dart';
import 'package:image/image.dart' as img;

/// Nearest-neighbour 4x stand-in for the ONNX net (same tensor shapes).
Future<List<num>> fake4x(Float32List x, int s) async {
  final o = s * 4, out = Float32List(3 * o * o);
  for (var c = 0; c < 3; c++) {
    for (var y = 0; y < o; y++) {
      for (var xx = 0; xx < o; xx++) {
        out[c * o * o + y * o + xx] = x[c * s * s + (y ~/ 4) * s + xx ~/ 4];
      }
    }
  }
  return out;
}

Uint8List tinyJpeg() => img.encodeJpg(img.Image(width: 20, height: 14)..clear(img.ColorRgb8(10, 120, 200)));

void main() {
  test('isolate entries run through Isolate.run with plain data only', () async {
    final bytes = tinyJpeg();
    final d = await Isolate.run(() => decodeForUpscale((bytes, true)));
    expect([d.w, d.h], [20, 14]);
    final rgb4 = Uint8List(d.w * 4 * d.h * 4 * 3);
    final png = await Isolate.run(() => finishUpscale((rgb4, d.w * 4, d.h * 4, d.w * 3, d.h * 3)));
    expect(img.decodePng(png)!.width, 60);
  });

  test('the old pattern really is unsendable (a Completer in scope)', () async {
    final c = Completer<void>();
    void cb() => c.isCompleted;
    expect(() => Isolate.run(() { cb(); return 1; }), throwsA(anything));
  });

  for (final tile in [128, 96]) {
    for (final scale in [2, 3, 4]) {
      test('pipeline ${scale}x tile $tile works with a widget-like callback holding a Completer', () async {
        final unsendable = Completer<void>();
        var last = 0.0;
        final r = await upscalePipeline(tinyJpeg(), scale, fake4x, tile: tile,
            progress: (p) { last = p; if (unsendable.isCompleted) return; }, cancelled: () => unsendable.isCompleted);
        expect([r.w, r.h], [20 * scale, 14 * scale]);
        expect(last, 1.0);
        final out = img.decodePng(r.png)!;
        expect(out.width, 20 * scale);
        final p = out.getPixel(5, 5);
        expect((p.b - 200).abs() < 12 && (p.r - 10).abs() < 12, isTrue);
      });
    }
  }
}
