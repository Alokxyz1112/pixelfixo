import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
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
    expect(p.forSource(40).texture, p.texture);
  });
}
