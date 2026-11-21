// v65 (rewritten for v111): the version label left the app bar
// (the reference shows logo + icons only) — it still shows on
// the Login screen, which is how a build is identified now.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('v65 version lives on Login, not the app bar',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // No version text on the Studio screen itself.
    expect(find.text('Version 2.5.67'), findsNothing);
    await tester.tap(find.text('Login'));
    await tester.pump(const Duration(milliseconds: 300));
    // The route transition needs a second frame before the new
    // screen's content is in the tree.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('App v2.5.67'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('v65 app version matches the displayed label', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.contains('version: 2.5.67+132'), isTrue);
  });
}
