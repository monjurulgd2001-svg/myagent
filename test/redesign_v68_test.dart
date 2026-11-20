// v68, rewritten for v83: the gradient hero card is gone — the
// header is now a slim flat app bar with the account strip below
// it, and the stat chips live in the Showcase header.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Finder _heroCard() => find.byWidgetPredicate((w) =>
    w is Container &&
    w.decoration is BoxDecoration &&
    (w.decoration as BoxDecoration).gradient != null &&
    (w.decoration as BoxDecoration).borderRadius ==
        BorderRadius.circular(24));

Future<void> _pump(WidgetTester tester, Size size, double dpr) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const GeminiHdStudioApp());
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('v68 desktop header is a slim app bar, no hero card',
      (tester) async {
    await _pump(tester, const Size(1280, 800), 1.0);

    // The old gradient hero card is gone.
    expect(_heroCard(), findsNothing);
    // The app bar is one slim row (48px icon tap targets + 12
    // padding + divider = 61px measured on wide).
    expect(tester.getSize(find.byKey(const ValueKey('appBar'))).height,
        lessThanOrEqualTo(64));

    // Everything still there, just moved: chips in Showcase,
    // subtitle under the title, status in the account strip.
    expect(find.text('0 sets'), findsOneWidget);
    expect(find.text('Wallpaper Set Designer'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Version 2.5.42'), findsOneWidget);

    // Subtitle still sits directly under the title text (v63).
    final titleLeft = tester.getTopLeft(find.text('Zedge Studio')).dx;
    final subtitleLeft =
        tester.getTopLeft(find.text('Wallpaper Set Designer')).dx;
    expect(subtitleLeft, moreOrLessEquals(titleLeft, epsilon: 1.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('v68 phone header is a slim app bar, no hero card',
      (tester) async {
    await _pump(tester, const Size(720, 1600), 2.0);

    expect(_heroCard(), findsNothing);
    // One slim row (48px icon tap targets + 16 padding + divider
    // = 65px measured on a phone).
    expect(tester.getSize(find.byKey(const ValueKey('appBar'))).height,
        lessThanOrEqualTo(72));
    expect(find.text('Version 2.5.42'), findsOneWidget);
    expect(find.text('Wallpaper Set Designer'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
