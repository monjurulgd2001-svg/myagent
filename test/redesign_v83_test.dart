// v83, rewritten for v111: professional redesign — slim flat app
// bar (logo + four icons, no title text), no hero card, and the
// account strip is gone (its functions moved to the app-bar gear
// menu + theme icon); stat chips in the Showcase header.
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
  testWidgets('v83 phone: slim app bar, no hero card, no account strip',
      (tester) async {
    await _pump(tester, const Size(720, 1600), 2.0);

    // The old gradient hero card is gone.
    expect(_heroCard(), findsNothing);
    // App bar: logo + four icons, one row (48px gear tap target
    // + 16 padding + 1 divider = 65px measured).
    expect(tester.getSize(find.byKey(const ValueKey('appBar'))).height,
        lessThanOrEqualTo(72));
    expect(find.image(const AssetImage('assets/logo.png')), findsOneWidget);
    expect(find.text('Zedge Studio'), findsNothing);
    expect(find.text('Wallpaper Set Designer'), findsNothing);
    expect(find.text('Version 2.5.52'), findsNothing);
    // v83: no Gemini Login icon in the app bar — Login is a nav
    // destination, and the third icon squeezed the title.
    expect(find.byTooltip('Gemini Login'), findsNothing);
    // v111: the account strip is gone — its functions moved to
    // the app-bar gear menu + theme icon.
    expect(find.byKey(const ValueKey('accountStrip')), findsNothing);
    expect(find.text('Not connected'), findsNothing);
    // v84: the Background generation card left the dashboard for
    // the Login screen — the Studio tab carries no trace of it.
    expect(find.text('Background generation'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v83 phone: stat chips live in Showcase, not the header',
      (tester) async {
    await _pump(tester, const Size(720, 1600), 2.0);
    // v85: the chips sit in the inline gallery below the designer,
    // not in the top chrome — they are below the app bar.
    final barBottom =
        tester.getBottomLeft(find.byKey(const ValueKey('appBar'))).dy;
    expect(tester.getTopLeft(find.text('0 sets')).dy,
        greaterThan(barBottom));
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
    expect(find.text('Version 2.5.52'), findsNothing);
    // Showcase is side by side on wide, so its chips are visible.
    expect(find.text('0 sets'), findsOneWidget);
    expect(find.text('Not connected'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
