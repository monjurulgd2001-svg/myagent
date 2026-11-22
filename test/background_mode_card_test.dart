// v77: the Background generation card — one in-app switch
// instead of hunting through Settings.
// v84: the card moved out of the dashboard into the Login screen
// (it is a settings item, in the section where he signs in) —
// these tests open Login first instead of finding it on Studio.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _openLogin(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(720, 1600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const GeminiHdStudioApp());
  await tester.pump(const Duration(milliseconds: 300));
  // The dashboard no longer carries the card.
  expect(find.text('Background generation'), findsNothing);
  await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.byIcon(Icons.account_circle_outlined)));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('Background generation card lives in Login, ON by default',
      (tester) async {
    await _openLogin(tester);
    expect(find.text('Background generation'), findsOneWidget);
    // The card sits below the tall session card — scroll it into
    // view first, like a real user would (ensureVisible uses the
    // card's own scrollable ancestor).
    await tester.ensureVisible(find.byKey(const ValueKey('bgModeSwitch')));
    await tester.pump(const Duration(milliseconds: 100));
    final sw =
        tester.widget<Switch>(find.byKey(const ValueKey('bgModeSwitch')));
    expect(sw.value, isTrue);
    // Turning it OFF sticks and shows the OFF status line.
    await tester.tap(find.byKey(const ValueKey('bgModeSwitch')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('OFF — phone lock korle generation thambe.'),
        findsOneWidget);
  });

  testWidgets('Login screen still shows the session card above it',
      (tester) async {
    await _openLogin(tester);
    expect(find.text('Gemini web session'), findsOneWidget);
    expect(find.text('Background generation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // v153 — Windows has no Android foreground service, battery
  // exemption or Phone Master: a desktop process simply keeps
  // running while the app is open, so the card shows ON and
  // disabled with the honest desktop wording instead of the
  // phone's Allow flow.
  testWidgets('Windows shows the desktop wording, switch disabled',
      (tester) async {
    // Reset in the body (try/finally): the test binding verifies
    // foundation debug vars are unset right after the body, before
    // tearDowns run, so an addTearDown reset is too late.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _openLogin(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('bgModeSwitch')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
          find.text('ON — Windows-e app khula thakle generation cholbe '
              '(screen lock korleo thambe na).'),
          findsOneWidget);
      final sw =
          tester.widget<Switch>(find.byKey(const ValueKey('bgModeSwitch')));
      expect(sw.value, isTrue);
      expect(sw.onChanged, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
