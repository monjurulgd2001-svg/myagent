// v83: professional redesign — slim flat app bar, no hero card;
// account strip below it; stat chips in the Showcase header.
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
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('v83 phone: slim app bar, account strip, no hero card',
      (tester) async {
    await _pump(tester, const Size(720, 1600), 2.0);

    // The old gradient hero card is gone.
    expect(_heroCard(), findsNothing);
    // App bar: logo + title + subtitle + actions + version, one row.
    // (The 48px Material tap target of the action icons sets the
    // height: 48 + 16 padding + 1 divider = 65px measured.)
    expect(tester.getSize(find.byKey(const ValueKey('appBar'))).height,
        lessThanOrEqualTo(72));
    expect(find.image(const AssetImage('assets/logo.png')), findsOneWidget);
    expect(find.text('Zedge Studio'), findsOneWidget);
    expect(find.text('Wallpaper Set Designer'), findsOneWidget);
    expect(find.text('Version 2.5.31'), findsOneWidget);
    // v83: no Gemini Login icon in the app bar — Login is a nav
    // destination, and the third icon squeezed the title.
    expect(find.byTooltip('Gemini Login'), findsNothing);
    // Account strip sits directly below the app bar and is one
    // row tall: the status lives inside it, not below it.
    final barBottom =
        tester.getBottomLeft(find.byKey(const ValueKey('appBar'))).dy;
    final stripTop =
        tester.getTopLeft(find.byKey(const ValueKey('accountStrip'))).dy;
    expect(stripTop, moreOrLessEquals(barBottom, epsilon: 1.0));
    expect(tester.getSize(find.byKey(const ValueKey('accountStrip'))).height,
        lessThanOrEqualTo(56));
    expect(find.text('Not connected'), findsOneWidget);
    // v84: the Background generation card left the dashboard for
    // the Login screen — the Studio tab carries no trace of it.
    expect(find.text('Background generation'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v83 phone: stat chips live in Showcase, not the header',
      (tester) async {
    await _pump(tester, const Size(720, 1600), 2.0);
    // v85: the chips sit in the inline gallery below the designer,
    // not in the top chrome — they are below the account strip.
    final stripBottom =
        tester.getBottomLeft(find.byKey(const ValueKey('accountStrip'))).dy;
    expect(tester.getTopLeft(find.text('0 sets')).dy,
        greaterThan(stripBottom));
    expect(find.text('0 sets'), findsOneWidget);
    expect(find.text('0 Gmail'), findsOneWidget);
    expect(find.text('1620x2880 JPG'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v83 desktop: rail + slim bar + chips in Showcase',
      (tester) async {
    await _pump(tester, const Size(1280, 800), 1.0);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(_heroCard(), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('appBar'))).height,
        lessThanOrEqualTo(64));
    expect(find.text('Version 2.5.31'), findsOneWidget);
    // Showcase is side by side on wide, so its chips are visible.
    expect(find.text('0 sets'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
