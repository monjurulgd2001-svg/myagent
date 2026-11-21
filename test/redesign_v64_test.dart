// v64 (rewritten for v111): the app bar keeps 32px action icons;
// the title/subtitle/version text left the bar.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gemini_hd_studio/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('v64 app bar keeps 32px action icons',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const GeminiHdStudioApp());
    await tester.pump(const Duration(milliseconds: 300));
    // v83: the Gemini Login icon left the app bar (Login is already
    // a nav destination, and the third icon squeezed the title).
    // The two remaining header actions are still 32px.
    for (final tip in [
      'Import local set',
      'Panel upload settings',
    ]) {
      final btn = tester.widget<IconButton>(find.ancestor(
          of: find.byTooltip(tip), matching: find.byType(IconButton)));
      expect(btn.constraints!.maxWidth, 32);
      expect(btn.constraints!.maxHeight, 32);
      expect(btn.iconSize, 18);
    }
    // v111: no title/subtitle/version text in the bar; the theme
    // toggle and the gear menu sit beside the two actions.
    expect(find.text('Zedge Studio'), findsNothing);
    expect(find.text('Wallpaper Set Designer'), findsNothing);
    expect(find.text('Version 2.5.55'), findsNothing);
    expect(find.byKey(const ValueKey('themeToggle')), findsOneWidget);
    expect(find.byTooltip('Account actions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
