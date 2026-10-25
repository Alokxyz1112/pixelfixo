import 'package:flutter/material.dart';

const brandA = Color(0xFF7C3AED);
const brandB = Color(0xFF06B6D4);
const brandGradient = LinearGradient(colors: [brandA, brandB], begin: Alignment.topLeft, end: Alignment.bottomRight);

/// Variable fonts need the weight as a font variation, so every style gets one that matches its weight.
TextStyle? _v(TextStyle? s, String family) {
  if (s == null) return null;
  final w = (s.fontWeight ?? FontWeight.w400).value.toDouble();
  return s.copyWith(fontFamily: family, fontVariations: [FontVariation('wght', w)]);
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: brandA,
    brightness: b,
    primary: dark ? const Color(0xFFA78BFA) : brandA,
    secondary: brandB,
    surface: dark ? const Color(0xFF0E0C17) : const Color(0xFFFAF9FE),
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: b);
  final t = base.textTheme;
  TextStyle? h(TextStyle? s, FontWeight w) => _v(s?.copyWith(fontWeight: w, letterSpacing: -0.5), 'SpaceGrotesk');
  final text = t.copyWith(
    displayLarge: h(t.displayLarge, FontWeight.w700),
    displayMedium: h(t.displayMedium, FontWeight.w700),
    displaySmall: h(t.displaySmall, FontWeight.w700),
    headlineLarge: h(t.headlineLarge, FontWeight.w700),
    headlineMedium: h(t.headlineMedium, FontWeight.w700),
    headlineSmall: h(t.headlineSmall, FontWeight.w600),
    titleLarge: h(t.titleLarge, FontWeight.w600),
    titleMedium: _v(t.titleMedium?.copyWith(fontWeight: FontWeight.w600), 'Inter'),
    titleSmall: _v(t.titleSmall?.copyWith(fontWeight: FontWeight.w600), 'Inter'),
    bodyLarge: _v(t.bodyLarge, 'Inter'),
    bodyMedium: _v(t.bodyMedium, 'Inter'),
    bodySmall: _v(t.bodySmall, 'Inter'),
    labelLarge: _v(t.labelLarge?.copyWith(fontWeight: FontWeight.w600), 'Inter'),
    labelMedium: _v(t.labelMedium?.copyWith(fontWeight: FontWeight.w500), 'Inter'),
    labelSmall: _v(t.labelSmall?.copyWith(fontWeight: FontWeight.w500), 'Inter'),
  );
  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0, titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface)),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xFF181525) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? .35 : .6))),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size(64, 54), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), textStyle: text.labelLarge?.copyWith(fontSize: 16))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: const Size(64, 54), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)))),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(textStyle: text.labelLarge)),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.android: FadeForwardsPageTransitionsBuilder(), TargetPlatform.linux: FadeForwardsPageTransitionsBuilder()}),
  );
}

/// A button filled with the brand gradient.
class GradientButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  const GradientButton({super.key, required this.label, required this.icon, this.onPressed});
  @override
  Widget build(BuildContext context) {
    final on = onPressed != null;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: on ? 1 : .5,
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: brandGradient, borderRadius: BorderRadius.circular(16), boxShadow: [
          if (on) BoxShadow(color: brandA.withValues(alpha: .35), blurRadius: 24, offset: const Offset(0, 8)),
        ]),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onPressed,
            child: SizedBox(
              height: 56,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, color: Colors.white),
                const SizedBox(width: 10),
                Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Colors.white, fontSize: 16)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
