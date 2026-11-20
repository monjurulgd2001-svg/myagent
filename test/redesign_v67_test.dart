import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('v67 desktop wide layout is back: rail, stat chips, no pill nav',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // Wide desktop: side rail, not the phone pill nav.
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    // v83: stat chips live in the Showcase header now (side by
    // side on wide, so they are visible on the Studio tab too).
    expect(find.text('0 sets'), findsOneWidget);
    expect(find.text('Version 2.5.34'), findsOneWidget);
  });

  testWidgets('v67 phone layout unchanged: pill nav, no rail',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('Version 2.5.34'), findsOneWidget);
  });
}
