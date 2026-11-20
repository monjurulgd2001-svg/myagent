// v85: the Showcase tab is gone — the generated sets live inline
// below the designer on the Studio screen, and the gallery
// scrolls into view after a generation finishes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  testWidgets('v85 phone: 4 nav destinations, no Showcase tab',
      (tester) async {
    await _pump(tester, const Size(720, 1600), 2.0);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations.length, 4);
    expect(find.text('Studio'), findsOneWidget);
    // v86: the Animation section sits between Studio and Search.
    expect(find.text('Animation'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Login'), findsOneWidget);
    // 'Showcase' survives only as the gallery header title.
    expect(find.text('Showcase'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v85 phone: designer on top, gallery below, one screen',
      (tester) async {
    await _pump(tester, const Size(720, 1600), 2.0);
    expect(find.text('Set Designer'), findsOneWidget);
    // The gallery header sits below the designer title, and the
    // empty state is on the same screen (scroll to it).
    expect(tester.getTopLeft(find.text('Showcase')).dy,
        greaterThan(tester.getBottomLeft(find.text('Set Designer')).dy));
    await tester.ensureVisible(find.text('Create your first set'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('No sets yet'), findsOneWidget);
    expect(find.text('Metadata (all)'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v85 desktop: rail has 4 destinations, panels side by side',
      (tester) async {
    await _pump(tester, const Size(1280, 800), 1.0);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations.length, 4);
    expect(find.text('Set Designer'), findsOneWidget);
    expect(find.text('Showcase'), findsOneWidget);
    expect(find.text('0 sets'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
