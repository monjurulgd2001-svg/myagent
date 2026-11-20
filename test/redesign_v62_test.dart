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
    // Compact sizes: 28px logo, 16px title (v83 slim app bar).
    final logo = tester.widget<Image>(find.image(
        const AssetImage('assets/logo.png')));
    expect(logo.width, 28);
    expect(logo.height, 28);
    final title =
        tester.widget<Text>(find.text('Zedge Studio'));
    expect(title.style!.fontSize, 16);
    expect(find.text('Version 2.5.35'), findsOneWidget);
    expect(find.text('Wallpaper Set Designer'), findsOneWidget);
    // No overflow / layout error on the narrow screen.
    expect(tester.takeException(), isNull);
  });
}
