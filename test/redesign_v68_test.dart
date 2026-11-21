// v68, rewritten for v111: the gradient hero card is gone, and so
// are the title/subtitle/version/status from the top chrome — the
// header is now logo + four icons, like the reference's main
// screen, and the stat chips live in the Showcase header.
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
    // The app bar is one slim row (48px gear tap target + 12
    // padding + divider = 61px measured on wide).
    expect(tester.getSize(find.byKey(const ValueKey('appBar'))).height,
        lessThanOrEqualTo(64));

    // v111: title/subtitle/version/status left the top chrome.
    expect(find.text('0 sets'), findsOneWidget);
    expect(find.text('Zedge Studio'), findsNothing);
    expect(find.text('Wallpaper Set Designer'), findsNothing);
    expect(find.text('Version 2.5.59'), findsNothing);
    expect(find.text('Not connected'), findsNothing);
    expect(find.byTooltip('Account actions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v68 phone header is a slim app bar, no hero card',
      (tester) async {
    await _pump(tester, const Size(720, 1600), 2.0);

    expect(_heroCard(), findsNothing);
    // One slim row (48px gear tap target + 16 padding + divider
    // = 65px measured on a phone).
    expect(tester.getSize(find.byKey(const ValueKey('appBar'))).height,
        lessThanOrEqualTo(72));
    expect(find.text('Version 2.5.59'), findsNothing);
    expect(find.text('Wallpaper Set Designer'), findsNothing);
    expect(find.text('Not connected'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
