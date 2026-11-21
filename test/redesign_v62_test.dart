// v62 (rewritten for v111): the header is logo + icons only now
// (the reference's main screen has no title text) and still fits
// a 360px phone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('v62 header is compact and fits a 360px phone',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    // Narrow phone, like the user's screenshot device.
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // Compact sizes: 28px logo (v83 slim app bar).
    final logo = tester.widget<Image>(find.image(
        const AssetImage('assets/logo.png')));
    expect(logo.width, 28);
    expect(logo.height, 28);
    // v111: no title column — logo + four function icons only.
    expect(find.text('Zedge Studio'), findsNothing);
    expect(find.text('Wallpaper Set Designer'), findsNothing);
    expect(find.text('Version 2.5.52'), findsNothing);
    expect(find.byTooltip('Import local set'), findsOneWidget);
    expect(find.byTooltip('Panel upload settings'), findsOneWidget);
    expect(find.byKey(const ValueKey('themeToggle')), findsOneWidget);
    expect(find.byTooltip('Account actions'), findsOneWidget);
    // No overflow / layout error on the narrow screen.
    expect(tester.takeException(), isNull);
  });
}
