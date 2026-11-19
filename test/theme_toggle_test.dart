// v93 — dark / light theme toggle: the light scheme, the
// persisted toggle, and the app-bar-strip button flipping the
// live app.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/main.dart';

Future<void> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  themeModeNotifier.value = ThemeMode.dark;
  tester.view.physicalSize = const Size(720, 1600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => themeModeNotifier.value = ThemeMode.dark);
  await tester.pumpWidget(const GeminiHdStudioApp());
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('v93: light theme is light, dark theme is dark', () {
    final dark = buildStudioTheme();
    final light = buildStudioTheme(light: true);
    expect(dark.brightness, Brightness.dark);
    expect(light.brightness, Brightness.light);
    expect(dark.colorScheme.primary, const Color(0xFFA89CFE));
    expect(light.colorScheme.primary, const Color(0xFF6C5CE7));
    expect(light.scaffoldBackgroundColor, const Color(0xFFF7F5FF));
    expect(dark.scaffoldBackgroundColor, const Color(0xFF0A0A0A));
  });

  test('v95: dark theme is neutral black 90% (no blue tint)', () {
    final dark = buildStudioTheme();
    expect(dark.colorScheme.surfaceContainerLowest,
        const Color(0xFF0A0A0A));
    expect(dark.colorScheme.surface, const Color(0xFF1A1A1A));
    expect(dark.colorScheme.surfaceContainer, const Color(0xFF1A1A1A));
    expect(dark.colorScheme.surfaceContainerHigh, const Color(0xFF212121));
    expect(dark.colorScheme.surfaceContainerHighest,
        const Color(0xFF2B2B2B));
  });

  test('v93: toggleTheme flips the notifier + persists the choice',
      () async {
    SharedPreferences.setMockInitialValues({});
    themeModeNotifier.value = ThemeMode.dark;
    await toggleTheme();
    expect(themeModeNotifier.value, ThemeMode.light);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kThemeModeKey), 'light');
    await toggleTheme();
    expect(themeModeNotifier.value, ThemeMode.dark);
    expect(prefs.getString(kThemeModeKey), 'dark');
  });

  testWidgets('v93: theme toggle button flips the live app',
      (tester) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey('themeToggle')), findsOneWidget);
    // Dark to start: the button offers the light theme.
    expect(find.byTooltip('Light theme'), findsOneWidget);
    final scaffoldBefore =
        tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffoldBefore.backgroundColor, const Color(0xFF0A0A0A));
    await tester.tap(find.byKey(const ValueKey('themeToggle')));
    // The MaterialApp animates the theme over 200ms
    // (AnimatedTheme), so pump past it before asserting colours.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Dark theme'), findsOneWidget);
    final scaffoldAfter =
        tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffoldAfter.backgroundColor, const Color(0xFFF7F5FF));
    await tester.tap(find.byKey(const ValueKey('themeToggle')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Light theme'), findsOneWidget);
  });
}
