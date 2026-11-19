import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('v65 header shows Version 2.5.31, not a BUILD tag',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // The label still fits in the slim app bar on a 360px phone.
    expect(find.text('Version 2.5.31'), findsOneWidget);
    expect(find.text('Wallpaper Set Designer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('v65 app version matches the displayed label', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.contains('version: 2.5.31+96'), isTrue);
  });
}
