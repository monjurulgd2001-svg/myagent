// v93/v127 — dark / light theme toggle using the generate-main AppTheme
// design system (Inter font, layered surfaces, #A99CFF dark / #5B4BDB light).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gemini_hd_studio/app_theme.dart';
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
  test('v127: light theme is light, dark theme is dark with Inter font', () {
    final dark = buildStudioTheme();
    final light = buildStudioTheme(light: true);
    expect(dark.brightness, Brightness.dark);
    expect(light.brightness, Brightness.light);
    expect(dark.colorScheme.primary, const Color(0xFFA99CFF));
    expect(light.colorScheme.primary, const Color(0xFF5B4BDB));
    expect(light.scaffoldBackgroundColor, const Color(0xFFF7F7FB));
    expect(dark.scaffoldBackgroundColor, const Color(0xFF0E0F14));
    expect(dark.textTheme.bodyMedium?.fontFamily, AppTheme.font);
  });

  test('v127: dark theme uses layered slate surfaces from AppTheme', () {
    final dark = buildStudioTheme();
    expect(dark.colorScheme.surfaceContainerLowest, const Color(0xFF0B0C10));
    expect(dark.colorScheme.surface, const Color(0xFF0E0F14));
    expect(dark.colorScheme.surfaceContainerLow, const Color(0xFF15161D));
    expect(dark.colorScheme.surfaceContainer, const Color(0xFF1A1B23));
    expect(dark.colorScheme.surfaceContainerHigh, const Color(0xFF21222C));
    expect(dark.colorScheme.surfaceContainerHighest, const Color(0xFF2A2B36));
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
    expect(find.byTooltip('Light theme'), findsOneWidget);
    final scaffoldBefore =
        tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffoldBefore.backgroundColor, const Color(0xFF0E0F14));
    await tester.tap(find.byKey(const ValueKey('themeToggle')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Dark theme'), findsOneWidget);
    final scaffoldAfter =
        tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffoldAfter.backgroundColor, const Color(0xFFF7F7FB));
    await tester.tap(find.byKey(const ValueKey('themeToggle')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Light theme'), findsOneWidget);
  });

  test('v127: light theme fields are white with subtle border and dark chips',
      () {
    final light = buildStudioTheme(light: true);
    final scheme = light.colorScheme;
    expect(light.inputDecorationTheme.fillColor, scheme.surfaceContainerLowest);
    expect(light.inputDecorationTheme.labelStyle?.color,
        scheme.onSurfaceVariant);
    expect(light.inputDecorationTheme.floatingLabelStyle?.color,
        scheme.primary);
    final border =
        light.inputDecorationTheme.enabledBorder as OutlineInputBorder;
    expect(border.borderSide.color, scheme.outlineVariant);
    expect(light.chipTheme.labelStyle?.color, scheme.onSurface);
  });
}
