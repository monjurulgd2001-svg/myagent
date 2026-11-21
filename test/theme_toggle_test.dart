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

  test('v99: light theme fields are white with a visible border, '
      'chip labels are explicitly dark', () {
    final light = buildStudioTheme(light: true);
    final scheme = light.colorScheme;
    expect(light.inputDecorationTheme.fillColor, scheme.surface);
    expect(light.inputDecorationTheme.labelStyle?.color,
        scheme.onSurfaceVariant);
    expect(light.inputDecorationTheme.floatingLabelStyle?.color,
        scheme.primary);
    final border = light.inputDecorationTheme.enabledBorder
        as OutlineInputBorder;
    expect(border.borderSide.color, scheme.outline);
    expect(light.chipTheme.labelStyle?.color, scheme.onSurface);
    expect(light.chipTheme.secondaryLabelStyle?.color, scheme.onSurface);
  });

  testWidgets('v99: the selected mode chip is solid primary with an '
      'onPrimary label in light mode', (tester) async {
    await _pump(tester);
    themeModeNotifier.value = ThemeMode.light;
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final chip = tester.widget<ChoiceChip>(find.ancestor(
      of: find.text('24-Hour Set (4)').first,
      matching: find.byType(ChoiceChip),
    ));
    expect(chip.selected, isTrue);
    expect(chip.selectedColor, const Color(0xFF6C5CE7));
    final label = tester.widget<Text>(find.text('24-Hour Set (4)').first);
    expect(label.style?.color, Colors.white);
    // An unselected mode chip keeps the pale surface + dark label.
    final plain = tester.widget<ChoiceChip>(find.ancestor(
      of: find.text('Single 9:16').first,
      matching: find.byType(ChoiceChip),
    ));
    expect(plain.selected, isFalse);
    expect(plain.backgroundColor, const Color(0xFFEDEAFF));
    final plainLabel =
        tester.widget<Text>(find.text('Single 9:16').first);
    expect(plainLabel.style?.color, const Color(0xFF17171F));
  });
}
