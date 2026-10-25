import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelfixo/engine/upscale.dart';
import 'package:pixelfixo/engine/upscale_post.dart';
import 'package:image/image.dart' as img;

Uint8List _photo(int w, int h) {
  final r = math.Random(3), b = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 3;
      b[i] = (120 + 60 * math.sin(x / 7) + r.nextInt(20)).clamp(0, 255).toInt();
      b[i + 1] = (90 + 40 * math.cos(y / 5) + r.nextInt(20)).clamp(0, 255).toInt();
      b[i + 2] = (70 + r.nextInt(30)).clamp(0, 255).toInt();
    }
  }
  return b;
}

Uint8List _nearest4(Uint8List s, int w, int h, {int shift = 0}) {
  final o = Uint8List(w * h * 48);
  for (var y = 0; y < h * 4; y++) {
    for (var x = 0; x < w * 4; x++) {
      for (var c = 0; c < 3; c++) {
        o[(y * w * 4 + x) * 3 + c] = (s[((y ~/ 4) * w + x ~/ 4) * 3 + c] + (c == 0 ? shift : 0)).clamp(0, 255);
      }
    }
  }
  return o;
}

double _meanChannel(Uint8List a, int c) {
  var s = 0.0;
  for (var i = c; i < a.length; i += 3) {
    s += a[i];
  }
  return s / (a.length / 3);
}

void main() {
  test('jpegQuality reads the encoder quality and ignores PNG', () {
    final im = img.Image.fromBytes(width: 32, height: 32, bytes: _photo(32, 32).buffer, numChannels: 3);
    for (final q in [30, 60, 90]) {
      expect(jpegQuality(img.encodeJpg(im, quality: q))!, closeTo(q, 3));
    }
    expect(jpegQuality(img.encodePng(im)), isNull);
  });

  test('color anchor removes a color cast the model added', () {
    const w = 24, h = 24;
    final s = _photo(w, h);
    final o = _nearest4(s, w, h, shift: 25); // model made it redder
    final f = postProcess((o, w * 4, h * 4, s, w, h, 4, const PostOptions(natural: 0), 1));
    expect((_meanChannel(f, 0) - _meanChannel(s, 0)).abs(), lessThan(2));
    expect((_meanChannel(o, 0) - _meanChannel(s, 0)).abs(), greaterThan(20));
  });

  test('banded processing matches one big pass', () {
    const w = 40, h = 70;
    final s = _photo(w, h), o = _nearest4(s, w, h, shift: 10);
    const opt = PostOptions();
    final one = postProcess((o, w * 4, h * 4, s, w, h, 4, opt, 1));
    final bands = postProcessBands(o, w * 4, h * 4, s, w, h, 4, opt, band: 16, margin: 8);
    var maxd = 0;
    for (var i = 0; i < one.length; i++) {
      maxd = math.max(maxd, (one[i] - bands[i]).abs());
    }
    expect(maxd, lessThanOrEqualTo(3));
  });

  test('low quality JPEG turns off grain and turns on extra cleanup', () {
    const p = PostOptions(grain: true);
    expect(p.forSource(40).lowQuality, isTrue);
    expect(p.forSource(40).grain, isFalse);
    expect(p.forSource(95).grain, isTrue);
    expect(p.forSource(null).lowQuality, isFalse);
  });

  test('skin range covers light and dark skin', () {
    double cb(int r, int g, int b) => 128 - 0.168736 * r - 0.331264 * g + 0.5 * b;
    double cr(int r, int g, int b) => 128 + 0.5 * r - 0.418688 * g - 0.081312 * b;
    double y(int r, int g, int b) => 0.299 * r + 0.587 * g + 0.114 * b;
    for (final c in [(224, 172, 140), (198, 134, 66), (141, 85, 36), (110, 70, 50)]) {
      expect(isSkin(y(c.$1, c.$2, c.$3), cb(c.$1, c.$2, c.$3), cr(c.$1, c.$2, c.$3)), isTrue, reason: '$c');
    }
  });

  test('finishWithPost runs in a background isolate with plain data', () async {
    const w = 16, h = 12;
    final s = _photo(w, h), o = _nearest4(s, w, h);
    final png = await Isolate.run(() => finishWithPost((o, w, h, s, w * 2, h * 2, const PostOptions(grain: true, vibrance: 0.12))));
    final d = img.decodePng(png)!;
    expect((d.width, d.height), (32, 24));
  });

  test('estimate grows with size and is human readable', () {
    expect(estimateSeconds(UpModel.ultra, 1000, 1000), greaterThan(estimateSeconds(UpModel.fast, 1000, 1000)));
    expect(estimateText(12), 'About 10 s');
    expect(estimateText(150), 'About 2.5 min');
  });
}
