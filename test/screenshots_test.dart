// Renders the README screenshots. Run: flutter test --update-goldens test/screenshots_test.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixelfixo/editor.dart';
import 'package:pixelfixo/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _font(String family, String path) async {
  final l = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await l.load();
}

void main() {
  final before = File('test/fixtures/before.jpg').readAsBytesSync();
  final after = File('test/fixtures/after.jpg').readAsBytesSync();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await _font('Inter', 'assets/fonts/Inter.ttf');
    await _font('SpaceGrotesk', 'assets/fonts/SpaceGrotesk.ttf');
    await _font('MaterialIcons', '/workspace/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  });

  Future<void> shot(WidgetTester t, String name, Widget home, ThemeMode mode) async {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({'theme': mode.index});
    themeMode.value = mode;
    await t.pumpWidget(PixelfixoApp(home: home));
    await t.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        await precacheImage((e.widget as Image).image, e);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
  }

  testWidgets('home dark', (t) => shot(t, '01-home-dark', const HomeScreen(), ThemeMode.dark));
  testWidgets('home light', (t) => shot(t, '02-home-light', const HomeScreen(), ThemeMode.light));
  testWidgets('options', (t) => shot(t, '03-options', EditorScreen(source: before, demoPhase: Phase.setup, demoSize: const Size(220, 220)), ThemeMode.dark));
  testWidgets('compare', (t) => shot(t, '04-compare', EditorScreen(source: before, demoPhase: Phase.done, demoResult: after), ThemeMode.dark));
  testWidgets('compare light', (t) => shot(t, '05-compare-light', EditorScreen(source: before, demoPhase: Phase.done, demoResult: after), ThemeMode.light));
}
