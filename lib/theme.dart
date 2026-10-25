import 'package:flutter/material.dart';

/// Monochrome palette. Black, white and greys only.
class Mono {
  static Color bg(bool d) => d ? Colors.black : Colors.white;
  static Color card(bool d) => d ? const Color(0xFF0B0B0B) : Colors.white;
  static Color fill(bool d) => d ? const Color(0xFF161616) : const Color(0xFFF4F4F4);
  static Color line(bool d) => d ? const Color(0xFF262626) : const Color(0xFFE6E6E6);
  static Color muted(bool d) => d ? const Color(0xFF8C8C8C) : const Color(0xFF6E6E6E);
  static Color ink(bool d) => d ? Colors.white : Colors.black;
}

bool isDark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;

/// Variable fonts need the weight as a font variation, so every style gets one that matches its weight.
TextStyle? _v(TextStyle? s) {
  if (s == null) return null;
  final w = (s.fontWeight ?? FontWeight.w400).value.toDouble();
  return s.copyWith(fontFamily: 'Inter', fontVariations: [FontVariation('wght', w)]);
}

ThemeData buildTheme(Brightness b) {
  final d = b == Brightness.dark;
  final ink = Mono.ink(d), bg = Mono.bg(d);
  final scheme = ColorScheme(
    brightness: b,
    primary: ink,
    onPrimary: bg,
    secondary: ink,
    onSecondary: bg,
    error: ink,
    onError: bg,
    errorContainer: Mono.fill(d),
    onErrorContainer: ink,
    surface: bg,
    onSurface: ink,
    onSurfaceVariant: Mono.muted(d),
    surfaceContainerHighest: Mono.fill(d),
    surfaceContainerHigh: Mono.fill(d),
    surfaceContainer: Mono.card(d),
    outline: Mono.line(d),
    outlineVariant: Mono.line(d),
    inverseSurface: ink,
    onInverseSurface: bg,
    surfaceTint: Colors.transparent,
    shadow: Colors.black,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: b, splashFactory: InkSparkle.constantTurbulenceSeedSplashFactory);
  final t = base.textTheme;
  TextStyle? h(TextStyle? s, FontWeight w, [double ls = -0.6]) => _v(s?.copyWith(fontWeight: w, letterSpacing: ls));
  final text = t.copyWith(
    displaySmall: h(t.displaySmall, FontWeight.w700, -1.2),
    headlineMedium: h(t.headlineMedium, FontWeight.w700, -0.8),
    headlineSmall: h(t.headlineSmall, FontWeight.w600),
    titleLarge: h(t.titleLarge, FontWeight.w600, -0.3),
    titleMedium: h(t.titleMedium, FontWeight.w600, -0.2),
    titleSmall: h(t.titleSmall, FontWeight.w600, 0),
    bodyLarge: _v(t.bodyLarge),
    bodyMedium: _v(t.bodyMedium),
    bodySmall: _v(t.bodySmall?.copyWith(fontSize: 12.5, height: 1.35)),
    labelLarge: h(t.labelLarge, FontWeight.w600, 0),
    labelMedium: h(t.labelMedium, FontWeight.w500, 0),
    labelSmall: h(t.labelSmall?.copyWith(fontSize: 11), FontWeight.w600, 0.8),
  ).apply(bodyColor: ink, displayColor: ink);
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(28));
  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    dividerTheme: DividerThemeData(color: Mono.line(d), thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleMedium?.copyWith(color: ink),
      shape: Border(bottom: BorderSide(color: Mono.line(d))),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Mono.card(d),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Mono.line(d))),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ink,
        foregroundColor: bg,
        disabledBackgroundColor: Mono.fill(d),
        disabledForegroundColor: Mono.muted(d),
        minimumSize: const Size(64, 56),
        shape: pill,
        elevation: 0,
        textStyle: text.labelLarge?.copyWith(fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(64, 56),
        shape: pill,
        side: BorderSide(color: Mono.line(d)),
        textStyle: text.labelLarge?.copyWith(fontSize: 16),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: ink)),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? bg : Mono.muted(d)),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? ink : Mono.fill(d)),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? ink : Mono.line(d)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: ink, linearTrackColor: Mono.fill(d), circularTrackColor: Mono.fill(d)),
    snackBarTheme: SnackBarThemeData(backgroundColor: ink, contentTextStyle: text.bodyMedium?.copyWith(color: bg), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.android: FadeForwardsPageTransitionsBuilder(), TargetPlatform.linux: FadeForwardsPageTransitionsBuilder()}),
  );
}

/// Segmented control: a grey track with the chosen option as a solid chip.
class Segmented<T> extends StatelessWidget {
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T>? onChanged;
  const Segmented({super.key, required this.items, required this.value, this.onChanged});
  @override
  Widget build(BuildContext context) {
    final d = isDark(context), t = Theme.of(context).textTheme;
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Mono.fill(d), borderRadius: BorderRadius.circular(22)),
      child: Row(children: [
        for (final (v, label) in items)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onChanged == null ? null : () => onChanged!(v),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: v == value ? Mono.ink(d) : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(label, style: t.labelLarge?.copyWith(color: v == value ? Mono.bg(d) : Mono.ink(d))),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Small uppercase heading above a group.
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: Row(children: [
          Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Mono.muted(isDark(context)))),
          const Spacer(),
          ?trailing,
        ]),
      );
}
