import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pixelfixo/engine/upscale.dart';
import 'package:pixelfixo/engine/upscale_post.dart' show touchUp;

void main() {
  test('small photos get the full scale, big ones are capped but never shrunk before the model', () {
    expect(outputSize(1000, 800, 4), (4000, 3200));
    expect(outputSize(1000, 800, 2), (2000, 1600));
    final (w, h) = outputSize(4000, 3000, 4);
    expect(w * h, lessThanOrEqualTo(maxOutPixels));
    expect(w, greaterThan(4000 * 1.3));
  });

  test('touchUp leaves the image alone when grain and color are off', () {
    final o = Uint8List.fromList(List.generate(3 * 16 * 16, (i) => i % 251));
    expect(touchUp(o, 16, 16, 3, const PostOptions()), same(o));
    final g = touchUp(o, 16, 16, 3, const PostOptions(grain: true));
    expect(g.length, o.length);
  });

  test('default look keeps all model detail and adds some texture', () {
    const p = PostOptions();
    expect(p.natural, 0);
    expect(p.texture, greaterThan(0));
    expect(p.sharpen, 0);
    expect(p.forSource(40).texture, p.texture);
    expect(p.forSource(40).sharpen, 0);
  });

  test('sharpen is kept when a low quality JPEG turns grain off', () {
    const p = PostOptions(grain: true, sharpen: 0.4);
    expect(p.forSource(40).grain, isFalse);
    expect(p.forSource(40).sharpen, 0.4);
  });

  test('tile origins cover the edge without gaps', () {
    bool covers(int length, int tile, int overlap) {
      final starts = tileOrigins(length, tile, overlap);
      expect(starts.first, 0);
      var end = 0;
      for (final p in starts) {
        expect(p, lessThanOrEqualTo(end), reason: 'gap before $p');
        end = math.max(end, p + math.min(tile, length - p));
      }
      expect(end, greaterThanOrEqualTo(length));
      return true;
    }

    expect(tileOrigins(100, 256, 8), [0]);
    expect(tileOrigins(512, 256, 0), [0, 256]);
    expect(tileOrigins(1000, 256, 8), [0, 248, 496, 744]);
    for (final length in [1, 64, 256, 257, 300, 1000, 4000]) {
      for (final tile in [96, 160, 256]) {
        covers(length, tile, 0);
        covers(length, tile, 8);
      }
    }
  });

  test('encodeSaved keeps a png and can write a jpeg', () {
    final im = img.Image(width: 8, height: 8)..clear(img.ColorRgb8(10, 20, 30));
    final png = img.encodePng(im);
    expect(encodeSaved((png, 'png', 90)), same(png));
    final jpg = encodeSaved((png, 'jpeg', 90));
    expect(jpg[0], 0xFF);
    expect(jpg[1], 0xD8);
  });

  test('the phone engine never asks for NNAPI', () {
    for (final m in UpModel.values) {
      expect(backendsFor(m), ['xnnpack', 'cpu']);
    }
    final dart = File('lib/engine/upscale.dart').readAsStringSync();
    final kotlin = File('android/app/src/main/kotlin/com/alokxyz1112/pixelfixo/NativeUpscaler.kt').readAsStringSync();
    expect(dart.contains('nnapi'), isFalse);
    expect(kotlin.contains('addNnapi'), isFalse);
    expect(kotlin.contains('NNAPIFlags'), isFalse);
  });
}
