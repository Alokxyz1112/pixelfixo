import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'editor.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final (pkg, file) in [
      ('4xLSDIRCompactC and 4xNomosWebPhoto_RealPLKSR (Philip Hofmann)', 'assets/models/LICENSE-CC-BY-4.0.txt'),
      ('Real-ESRGAN', 'assets/models/LICENSE-Real-ESRGAN.txt'),
      ('Inter font', 'assets/fonts/OFL-Inter.txt'),
      ('Space Grotesk font', 'assets/fonts/OFL-SpaceGrotesk.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([pkg], await rootBundle.loadString(file));
    }
  });
  runApp(const PixelfixoApp());
}

final themeMode = ValueNotifier(ThemeMode.system);
final navKey = GlobalKey<NavigatorState>();

class PixelfixoApp extends StatefulWidget {
  final Widget? home; // for tests and screenshots
  const PixelfixoApp({super.key, this.home});
  @override
  State<PixelfixoApp> createState() => _PixelfixoAppState();
}

class _PixelfixoAppState extends State<PixelfixoApp> {
  static const _share = MethodChannel('pixelfixo/share');

  @override
  void initState() {
    super.initState();
    if (widget.home != null) return;
    SharedPreferences.getInstance().then((p) => themeMode.value = ThemeMode.values[p.getInt('theme') ?? 0]).ignore();
    _share.setMethodCallHandler((c) async {
      if (c.method == 'shared') openEditor(File(c.arguments as String));
    });
    _share.invokeMethod<String>('initial').then((p) {
      if (p != null) openEditor(File(p));
    }).catchError((_) => null);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: themeMode,
        builder: (_, mode, _) => MaterialApp(
          title: 'Pixelfixo',
          navigatorKey: navKey,
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: mode,
          home: widget.home ?? const HomeScreen(),
        ),
      );
}

Future<void> openEditor(File f) async {
  final bytes = await f.readAsBytes();
  navKey.currentState?.push(MaterialPageRoute(builder: (_) => EditorScreen(source: bytes)));
}

Future<void> pickPhoto(BuildContext context) async {
  final x = await ImagePicker().pickImage(source: ImageSource.gallery, requestFullMetadata: false);
  if (x == null) return;
  await openEditor(File(x.path));
}

void cycleTheme() async {
  final next = ThemeMode.values[(themeMode.value.index + 1) % 3];
  themeMode.value = next;
  (await SharedPreferences.getInstance()).setInt('theme', next.index);
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme, c = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(actions: [
        ValueListenableBuilder(
          valueListenable: themeMode,
          builder: (_, m, _) => IconButton(
            tooltip: 'Theme: ${m.name}',
            onPressed: cycleTheme,
            icon: Icon(switch (m) { ThemeMode.light => Icons.light_mode_rounded, ThemeMode.dark => Icons.dark_mode_rounded, _ => Icons.brightness_auto_rounded }),
          ),
        ),
        IconButton(tooltip: 'About', onPressed: () => showAbout(context), icon: const Icon(Icons.info_outline_rounded)),
      ]),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Spacer(),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutBack,
              builder: (_, v, child) => Transform.scale(scale: .7 + .3 * v, alignment: Alignment.centerLeft, child: Opacity(opacity: v.clamp(0, 1), child: child)),
              child: Container(
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(28), boxShadow: [BoxShadow(color: brandA.withValues(alpha: .35), blurRadius: 40, offset: const Offset(0, 12))]),
                child: ClipRRect(borderRadius: BorderRadius.circular(28), child: Image.asset('assets/logo.png', width: 96, height: 96)),
              ),
            ),
            const SizedBox(height: 28),
            Text('Pixelfixo', style: t.displaySmall),
            const SizedBox(height: 8),
            Text('Make small photos big and sharp, right on your phone.', style: t.titleMedium?.copyWith(color: c.onSurfaceVariant, fontWeight: FontWeight.w400)),
            const SizedBox(height: 24),
            Wrap(spacing: 8, runSpacing: 8, children: const [
              _Pill(Icons.bolt_rounded, 'Up to 4x'),
              _Pill(Icons.wifi_off_rounded, 'Works offline'),
              _Pill(Icons.all_inclusive_rounded, 'No limits'),
              _Pill(Icons.palette_outlined, 'True colors'),
            ]),
            const Spacer(flex: 2),
            GradientButton(label: 'Pick a photo', icon: Icons.add_photo_alternate_rounded, onPressed: () => pickPhoto(context)),
            const SizedBox(height: 14),
            Center(child: Text('Or share a photo to Pixelfixo from any app', style: t.bodySmall?.copyWith(color: c.onSurfaceVariant))),
          ]),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Pill(this.icon, this.text);
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: c.primary.withValues(alpha: .1), borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: c.primary),
        const SizedBox(width: 6),
        Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: c.primary)),
      ]),
    );
  }
}

void showAbout(BuildContext context) => showLicensePage(
      context: context,
      applicationName: 'Pixelfixo',
      applicationVersion: '1.0.0',
      applicationIcon: Padding(padding: const EdgeInsets.all(12), child: ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.asset('assets/logo.png', width: 64))),
      applicationLegalese: 'MIT license. Upscaling models: 4xLSDIRCompactC and 4xNomosWebPhoto_RealPLKSR by Philip Hofmann (CC BY 4.0), '
          'Real-ESRGAN anime 6B by Xintao Wang et al. (BSD-3-Clause). Runs on ONNX Runtime (MIT).',
    );
