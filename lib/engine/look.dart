import 'package:flutter/material.dart';
import '../theme.dart';
import 'upscale.dart';

/// A starting point for the controls. Changing anything afterwards leaves the preset.
enum LookPreset { photo, portrait, restore, screenshot, drawing }

const lookPresetLabels = <(LookPreset, String)>[
  (LookPreset.photo, 'Photo'),
  (LookPreset.portrait, 'Portrait'),
  (LookPreset.restore, 'Old photo'),
  (LookPreset.screenshot, 'Screenshot'),
  (LookPreset.drawing, 'Drawing'),
];

/// The knobs one preset turns at once.
class LookChoice {
  final UpModel model;
  final int scale;
  final bool natural, color, grain, cleanup, faces;
  final double sharpen;
  const LookChoice({
    required this.model,
    required this.scale,
    required this.natural,
    required this.color,
    required this.grain,
    required this.cleanup,
    required this.faces,
    required this.sharpen,
  });

  PostOptions get post => PostOptions(texture: natural ? .3 : .6, grain: grain, vibrance: color ? .12 : 0, cleanup: cleanup, sharpen: sharpen);
}

/// [ultraReady] lets Portrait use the slower face model when it is already on the phone.
LookChoice lookFor(LookPreset p, {bool ultraReady = false}) => switch (p) {
      LookPreset.photo => const LookChoice(model: UpModel.fast, scale: 4, natural: true, color: false, grain: false, cleanup: true, faces: false, sharpen: 0.22),
      LookPreset.portrait => LookChoice(model: ultraReady ? UpModel.ultra : UpModel.high, scale: 4, natural: true, color: false, grain: false, cleanup: true, faces: true, sharpen: 0.1),
      LookPreset.restore => const LookChoice(model: UpModel.fast, scale: 4, natural: true, color: true, grain: true, cleanup: true, faces: true, sharpen: 0.14),
      LookPreset.screenshot => const LookChoice(model: UpModel.high, scale: 2, natural: false, color: false, grain: false, cleanup: false, faces: false, sharpen: 0.55),
      LookPreset.drawing => const LookChoice(model: UpModel.art, scale: 4, natural: true, color: false, grain: false, cleanup: false, faces: false, sharpen: 0.18),
    };

String sharpenLabel(double v) {
  if (v < 0.04) return 'Off';
  if (v < 0.3) return 'Light';
  if (v < 0.6) return 'Medium';
  return 'Strong';
}

/// Horizontal preset chips in the app's black and white palette.
class LookPresetBar extends StatelessWidget {
  final LookPreset? value;
  final ValueChanged<LookPreset>? onChanged;
  const LookPresetBar({super.key, required this.value, this.onChanged});
  @override
  Widget build(BuildContext context) {
    final d = isDark(context);
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final (p, label) in lookPresetLabels)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: value == p ? Mono.ink(d) : Mono.fill(d),
                borderRadius: BorderRadius.circular(19),
                child: InkWell(
                  borderRadius: BorderRadius.circular(19),
                  onTap: onChanged == null ? null : () => onChanged!(p),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Center(child: Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: value == p ? Mono.bg(d) : Mono.ink(d)))),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
