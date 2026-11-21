import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('v61 header shows the logo icon', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // The header tile now renders the new icon asset (28x28 on a
    // phone since v83, when the hero card became a slim app bar).
    expect(find.image(const AssetImage('assets/logo.png')), findsOneWidget);
    // v111: the title/subtitle/version text left the bar (the
    // reference shows logo + icons only) — the version lives on
    // the Login screen and in the gear menu.
    expect(find.text('Zedge Studio'), findsNothing);
    expect(find.text('Wallpaper Set Designer'), findsNothing);
    expect(find.text('Version 2.5.72'), findsNothing);
    // The four function icons are there instead.
    expect(find.byTooltip('Import local set'), findsOneWidget);
    expect(find.byTooltip('Panel upload settings'), findsOneWidget);
    expect(find.byKey(const ValueKey('themeToggle')), findsOneWidget);
    expect(find.byTooltip('Account actions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('v61 launcher icon files exist on disk', () {
    for (final d in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      expect(
          File('android/app/src/main/res/mipmap-$d/ic_launcher.png')
              .existsSync(),
          isTrue,
          reason: 'legacy $d launcher icon missing');
      expect(
          File('android/app/src/main/res/mipmap-$d/ic_launcher_foreground.png')
              .existsSync(),
          isTrue,
          reason: 'adaptive foreground $d missing');
    }
    // v70/v71: the logo is the artwork from his Logo_ZEDGE_STUDIO-2.svg
    // (white 7-Z + light-blue dot + shadow + 'ZEDGE Studio' wordmark —
    // v71 restored the wordmark hubahu after v70 dropped it) on its
    // own #5B5EFF tile, replacing the v61 reference-violet vector mark.
    // Adaptive background is the logo's own blue, not white.
    final bg = File(
            'android/app/src/main/res/drawable/ic_launcher_background.xml')
        .readAsStringSync();
    expect(bg.contains('#5B5EFF'), isTrue);
    expect(bg.contains('#FFFFFF'), isFalse);
    // Windows icon.
    expect(File('windows/runner/resources/app_icon.ico').existsSync(), isTrue);
    // The in-app logo is the 512 #5B5EFF tile with the SVG mark.
    final logoBytes = File('assets/logo.png').readAsBytesSync();
    final logo = img.decodePng(logoBytes)!;
    expect(logo.width, 512);
    expect(logo.height, 512);
    // Rounded tile: corner is transparent, top-centre is #5B5EFF.
    expect(logo.getPixel(0, 0).a, 0);
    final top = logo.getPixel(256, 8);
    expect(top.r, 91);
    expect(top.g, 94);
    expect(top.b, 255);
  });
}
