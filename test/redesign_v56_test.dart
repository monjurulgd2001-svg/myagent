import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gemini_hd_studio/main.dart';

void main() {
  testWidgets('v56 Showcase empty state offers Create your first set',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // v85: the empty gallery is inline below the designer on the
    // Studio screen — no Showcase tab to open any more.
    await tester.ensureVisible(find.text('No sets yet'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No sets yet'), findsOneWidget);
    expect(find.text('Create your first set'), findsOneWidget);
  });

  testWidgets('v56 Login screen shows the 3-step guide', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byIcon(Icons.account_circle_outlined)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('How sign-in works'), findsOneWidget);
  });
}
