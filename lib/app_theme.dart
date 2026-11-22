import 'package:flutter/material.dart';

/// Design system of the studio: one font (Inter), one accent, calm
/// layered surfaces, 48 dp touch targets and a single shape language
/// (12 dp controls, 20 dp cards). Every screen gets its look from here,
/// so buttons, chips, fields and cards stay consistent.
class AppTheme {
  static const seed = Color(0xFF6C5CE7);
  static const font = 'Inter';

  /// Status colours used across the app.
  static const success = Color(0xFF22C55E);
  static const warning = Color(0xFFF59E0B);

  static ThemeData light() {
    final base =
        ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light);
    final scheme = base.copyWith(
      primary: const Color(0xFF5B4BDB),
      surface: const Color(0xFFF7F7FB),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Colors.white,
      surfaceContainer: const Color(0xFFF1F1F7),
      surfaceContainerHigh: const Color(0xFFEBEBF3),
      surfaceContainerHighest: const Color(0xFFE4E4EE),
      outlineVariant: const Color(0xFFE0E0EA),
    );
    return _build(scheme);
  }

  static ThemeData dark() {
    final base =
        ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
    final scheme = base.copyWith(
      primary: const Color(0xFFA99CFF),
      onPrimary: const Color(0xFF1B1050),
      primaryContainer: const Color(0xFF3A2F8F),
      onPrimaryContainer: const Color(0xFFE7E2FF),
      secondaryContainer: const Color(0xFF2A2740),
      onSecondaryContainer: const Color(0xFFE2DEFA),
      surface: const Color(0xFF0E0F14),
      onSurface: const Color(0xFFECECF3),
      onSurfaceVariant: const Color(0xFFA3A4B5),
      surfaceContainerLowest: const Color(0xFF0B0C10),
      surfaceContainerLow: const Color(0xFF15161D),
      surfaceContainer: const Color(0xFF1A1B23),
      surfaceContainerHigh: const Color(0xFF21222C),
      surfaceContainerHighest: const Color(0xFF2A2B36),
      outline: const Color(0xFF6E6F80),
      outlineVariant: const Color(0xFF2B2C38),
      error: const Color(0xFFFF8A80),
    );
    return _build(scheme);
  }

  static ThemeData _build(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    final radius = BorderRadius.circular(12);
    final shape = RoundedRectangleBorder(borderRadius: radius);
    const btnText = TextStyle(
        fontFamily: font,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1);
    const btnPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 12);
    const btnMin = Size(64, 48);

    final baseText = ThemeData(brightness: scheme.brightness).textTheme;
    final text = baseText
        .copyWith(
          headlineSmall: baseText.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
          titleLarge: baseText.titleLarge?.copyWith(
              fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.2),
          titleMedium: baseText.titleMedium
              ?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
          titleSmall: baseText.titleSmall
              ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
          bodyLarge: baseText.bodyLarge?.copyWith(fontSize: 15.5, height: 1.4),
          bodyMedium: baseText.bodyMedium?.copyWith(fontSize: 14, height: 1.4),
          bodySmall: baseText.bodySmall?.copyWith(fontSize: 12.5, height: 1.4),
          labelLarge: baseText.labelLarge
              ?.copyWith(fontSize: 14.5, fontWeight: FontWeight.w600),
        )
        .apply(
          fontFamily: font,
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        );

    final fieldBorder = OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: scheme.outlineVariant),
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: font,
      textTheme: text,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 4,
        titleTextStyle: TextStyle(
            fontFamily: font,
            fontSize: 19,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(
          color: scheme.outlineVariant, thickness: 1, space: 24),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? scheme.surfaceContainer : scheme.surfaceContainerLowest,
        border: fieldBorder,
        enabledBorder: fieldBorder,
        disabledBorder: fieldBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.error),
        ),
        isDense: false,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.8)),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        floatingLabelStyle: TextStyle(color: scheme.primary),
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: btnMin,
          padding: btnPadding,
          shape: shape,
          textStyle: btnText,
          iconSize: 20,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: btnMin,
          padding: btnPadding,
          shape: shape,
          textStyle: btnText,
          iconSize: 20,
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outlineVariant, width: 1.2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: shape,
          textStyle: btnText,
          iconSize: 20,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: btnMin,
          padding: btnPadding,
          shape: shape,
          textStyle: btnText,
          elevation: 0,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: shape,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(48, 44),
          shape: shape,
          textStyle: const TextStyle(
              fontFamily: font, fontSize: 13.5, fontWeight: FontWeight.w600),
          side: BorderSide(color: scheme.outlineVariant),
          selectedBackgroundColor: scheme.secondaryContainer,
          selectedForegroundColor: scheme.onSecondaryContainer,
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: dark ? scheme.surfaceContainer : scheme.surfaceContainerLowest,
        selectedColor: scheme.secondaryContainer,
        labelStyle: TextStyle(
            fontFamily: font,
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            color: scheme.onSurface),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        iconTheme: IconThemeData(size: 18, color: scheme.primary),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        side: BorderSide(color: scheme.outline, width: 1.6),
      ),
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith((s) => s
                .contains(WidgetState.selected)
            ? const Icon(Icons.check, size: 16)
            : null),
      ),
      listTileTheme: ListTileThemeData(
        shape: shape,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        subtitleTextStyle:
            text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        iconColor: scheme.onSurfaceVariant,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        shape: const RoundedRectangleBorder(side: BorderSide.none),
        collapsedShape: const RoundedRectangleBorder(side: BorderSide.none),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        iconColor: scheme.primary,
        collapsedIconColor: scheme.onSurfaceVariant,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        linearMinHeight: 4,
        borderRadius: BorderRadius.circular(4),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 2,
        insetPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(
            fontFamily: font, fontSize: 14, color: scheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: text.titleLarge,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: text.bodyMedium,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14))),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
            color: scheme.inverseSurface,
            borderRadius: BorderRadius.circular(8)),
        textStyle: TextStyle(
            fontFamily: font, fontSize: 12.5, color: scheme.onInverseSurface),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 2,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: const TextStyle(
            fontFamily: font, fontSize: 14, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(
            fontFamily: font, fontSize: 14, fontWeight: FontWeight.w500),
        dividerColor: scheme.outlineVariant,
      ),
    );
  }
}

/// Scroll-view padding that also clears the Android system navigation bar.
///
/// Android 15+ renders edge-to-edge, so the gesture / 3-button bar overlays
/// the app. Adding the [MediaQuery] bottom inset keeps the last widgets
/// (e.g. the Generate button) fully visible on every screen size, while
/// desktop (Windows) is unaffected because the inset is zero there.
EdgeInsets screenScrollPadding(BuildContext context,
    [double base = 16, double maxWidth = 1200]) {
  final bottom = MediaQuery.paddingOf(context).bottom;
  final w = MediaQuery.sizeOf(context).width;
  // Phones: 12-16 dp side margins. Tablets / desktop windows: 24 dp, and
  // content is centred once the window is wider than [maxWidth].
  final double side;
  if (w > maxWidth + 48) {
    side = (w - maxWidth) / 2;
  } else if (w >= 600) {
    side = 24;
  } else {
    side = w < 400 ? 12.0 : base;
  }
  return EdgeInsets.fromLTRB(side, base - 4, side, base + 8 + bottom);
}
