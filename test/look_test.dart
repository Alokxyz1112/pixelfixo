import 'package:flutter_test/flutter_test.dart';
import 'package:pixelfixo/engine/look.dart';
import 'package:pixelfixo/engine/upscale.dart';
import 'package:pixelfixo/gallery_save.dart';

void main() {
  test('presets pick a model, a scale and a finish', () {
    final photo = lookFor(LookPreset.photo);
    expect(photo.model, UpModel.fast);
    expect(photo.scale, 4);
    expect(photo.post.sharpen, greaterThan(0));
    expect(photo.faces, isFalse);

    expect(lookFor(LookPreset.portrait).model, UpModel.high);
    expect(lookFor(LookPreset.portrait, ultraReady: true).model, UpModel.ultra);
    expect(lookFor(LookPreset.portrait).faces, isTrue);

    final shot = lookFor(LookPreset.screenshot);
    expect(shot.model, UpModel.high);
    expect(shot.scale, 2);
    expect(shot.sharpen, greaterThan(0.4));
    expect(shot.cleanup, isFalse);

    final drawing = lookFor(LookPreset.drawing);
    expect(drawing.model, UpModel.art);
    expect(drawing.faces, isFalse);
    expect(lookFor(LookPreset.restore).color, isTrue);
    expect(lookFor(LookPreset.restore).grain, isTrue);
  });

  test('save name is a timestamp and nothing else', () {
    expect(saveName(DateTime(2026, 10, 26, 4, 5, 6)), '20261026_040506.png');
    expect(saveName(DateTime(2026, 10, 26, 4, 5, 6), ext: 'jpg'), '20261026_040506.jpg');
  });

  test('sharpen labels', () {
    expect(sharpenLabel(0), 'Off');
    expect(sharpenLabel(0.2), 'Light');
    expect(sharpenLabel(0.4), 'Medium');
    expect(sharpenLabel(0.8), 'Strong');
  });
}
