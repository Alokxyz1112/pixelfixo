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
      ('4xNomosWebPhoto_RealPLKSR (Philip Hofmann)', 'assets/models/LICENSE-CC-BY-4.0.txt'),
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
    final t = Theme.of(context).textTheme, d = isDark(context);
    return Scaffold(
      appBar: AppBar(
        shape: const Border(),
        titleSpacing: 20,
        title: Row(children: [
          ClipRRect(borderRadius: BorderRadius.circular(7), child: Image.asset(d ? 'assets/logo_dark.png' : 'assets/logo.png', width: 26, height: 26)),
          const SizedBox(width: 10),
          const Text('Pixelfixo'),
        ]),
        actions: [
          ValueListenableBuilder(
            valueListenable: themeMode,
            builder: (_, m, _) => IconButton(
              tooltip: 'Theme: ${m.name}',
              onPressed: cycleTheme,
              icon: Icon(switch (m) { ThemeMode.light => Icons.light_mode_outlined, ThemeMode.dark => Icons.dark_mode_outlined, _ => Icons.brightness_auto_outlined }),
            ),
          ),
          PopupMenuButton<int>(
            tooltip: 'More',
            icon: const Icon(Icons.more_horiz),
            onSelected: (_) => showAbout(context),
            itemBuilder: (_) => const [PopupMenuItem(value: 0, child: Text('Open source licenses'))],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 24),
            Text('Bigger, sharper\nphotos.', style: t.displaySmall?.copyWith(height: 1.05)),
            const SizedBox(height: 12),
            Text('Upscale any photo up to 4x on your phone. Nothing leaves the device.', style: t.bodyLarge?.copyWith(color: Mono.muted(d), height: 1.4)),
            const SizedBox(height: 28),
            Expanded(
              child: Material(
                color: Mono.card(d),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Mono.line(d))),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => pickPhoto(context),
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Mono.line(d))),
                        child: Icon(Icons.add_photo_alternate_outlined, color: Mono.ink(d)),
                      ),
                      const SizedBox(height: 16),
                      Text('Choose a photo', style: t.titleMedium),
                      const SizedBox(height: 4),
                      Text('JPG, PNG or WebP from your gallery', style: t.bodySmall?.copyWith(color: Mono.muted(d))),
                    ]),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const _Fact(Icons.open_in_full, 'Up to 4x', 'Three modes'),
            const _Fact(Icons.cloud_off_outlined, 'Works offline', 'No uploads'),
            const _Fact(Icons.all_inclusive, 'No limits', 'No ads or account', last: true),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => pickPhoto(context), child: const Text('Choose photo')),
            const SizedBox(height: 12),
            Text('You can also share a photo to Pixelfixo from any app', textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: Mono.muted(d))),
          ]),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final IconData icon;
  final String title, sub;
  final bool last;
  const _Fact(this.icon, this.title, this.sub, {this.last = false});
  @override
  Widget build(BuildContext context) {
    final d = isDark(context), t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: Mono.line(d)), bottom: last ? BorderSide(color: Mono.line(d)) : BorderSide.none)),
      child: Row(children: [
        Icon(icon, size: 18, color: Mono.ink(d)),
        const SizedBox(width: 14),
        Text(title, style: t.titleSmall),
        const Spacer(),
        Text(sub, style: t.bodySmall?.copyWith(color: Mono.muted(d))),
      ]),
    );
  }
}

void showAbout(BuildContext context) => showLicensePage(
      context: context,
      applicationName: 'Pixelfixo',
      applicationVersion: '1.0.2',
      applicationIcon: Padding(padding: const EdgeInsets.all(12), child: ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.asset('assets/logo.png', width: 64))),
      applicationLegalese: 'MIT license. Upscaling models: Real-ESRGAN general x4v3 and anime 6B by Xintao Wang et al. (BSD-3-Clause), '
          '4xNomosWebPhoto_RealPLKSR by Philip Hofmann (CC BY 4.0). Runs on ONNX Runtime (MIT).',
    );
