import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelfixo/engine/jpeg_restore.dart';
import 'package:image/image.dart' as img;

double _psnr(Uint8List a, Uint8List b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = a[i] - b[i];
    s += d * d;
  }
  return 10 * math.log(255 * 255 / (s / a.length)) / math.ln10;
}

void main() {
  test('restored decode stays close to the source and beats the plain decode on a blocky JPEG', () {
    // Smooth gradient with a red disc: classic block and chroma bleed case.
    final src = img.Image(width: 96, height: 80);
    for (var y = 0; y < 80; y++) {
      for (var x = 0; x < 96; x++) {
        final inDisc = (x - 48) * (x - 48) + (y - 40) * (y - 40) < 400;
        src.setPixelRgb(x, y, inDisc ? 200 : 60 + x, inDisc ? 30 : 90 + y ~/ 2, inDisc ? 40 : 120);
      }
    }
    final jpg = img.encodeJpg(src, quality: 30, chroma: img.JpegChroma.yuv420);
    final plain = img.decodeJpg(jpg)!.convert(numChannels: 3).getBytes(order: img.ChannelOrder.rgb);
    final r = restoreJpeg(jpg)!;
    expect(r.w, 96);
    expect(r.h, 80);
    final ref = src.convert(numChannels: 3).getBytes(order: img.ChannelOrder.rgb);
    expect(_psnr(r.rgb, ref), greaterThan(_psnr(plain, ref)));
  });

  test('not a JPEG gives null', () {
    expect(restoreJpeg(img.encodePng(img.Image(width: 8, height: 8))), isNull);
  });

  // Demo on real files: HOBEE_SAMPLES=dir writes plain/restored PNGs next to the inputs.
  final dir = Platform.environment['HOBEE_SAMPLES'];
  test('samples', () {
    if (dir == null) return;
    for (final f in Directory(dir).listSync().whereType<File>().where((f) => f.path.endsWith('.jpeg'))) {
      final b = f.readAsBytesSync();
      final sw = Stopwatch()..start();
      final plain = img.decodeJpg(b)!;
      final tp = sw.elapsedMilliseconds;
      sw.reset();
      final r = restoreJpeg(b)!;
      final tr = sw.elapsedMilliseconds;
      File('${f.path}.plain.png').writeAsBytesSync(img.encodePng(plain));
      File('${f.path}.restored.png').writeAsBytesSync(img.encodePng(restoredImage(r)));
      // ignore: avoid_print
      print('${f.path} ${r.w}x${r.h} plain ${tp}ms restored ${tr}ms');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
