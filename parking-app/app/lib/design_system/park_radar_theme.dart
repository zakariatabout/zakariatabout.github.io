import 'package:flutter/material.dart';

import 'park_radar_tokens.dart';

abstract final class ParkRadarTheme {
  static final ThemeData light = _build(
    brightness: Brightness.light,
    semanticColors: ParkRadarColors.light,
  );

  static final ThemeData dark = _build(
    brightness: Brightness.dark,
    semanticColors: ParkRadarColors.dark,
  );

  static ThemeData _build({
    required Brightness brightness,
    required ParkRadarColors semanticColors,
  }) {
    final isDark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D47A1),
          brightness: brightness,
        ).copyWith(
          primary: isDark ? const Color(0xFFA8C7FA) : const Color(0xFF0D47A1),
          onPrimary: isDark ? const Color(0xFF062E6F) : Colors.white,
          primaryContainer: isDark
              ? const Color(0xFF123A73)
              : const Color(0xFFD8E6FF),
          onPrimaryContainer: isDark
              ? const Color(0xFFD7E3FF)
              : const Color(0xFF001A41),
          secondary: isDark ? const Color(0xFF7EE7D1) : const Color(0xFF00695C),
          onSecondary: isDark ? const Color(0xFF003731) : Colors.white,
          secondaryContainer: isDark
              ? const Color(0xFF074C43)
              : const Color(0xFFDDF7F0),
          onSecondaryContainer: isDark
              ? const Color(0xFFA7F2E2)
              : const Color(0xFF00201B),
          error: isDark ? const Color(0xFFFFB4AB) : const Color(0xFFB42318),
          onError: isDark ? const Color(0xFF690005) : Colors.white,
          errorContainer: isDark
              ? const Color(0xFF5A1A17)
              : const Color(0xFFFDECEC),
          onErrorContainer: isDark
              ? const Color(0xFFFFDAD6)
              : const Color(0xFF601410),
          surface: isDark ? const Color(0xFF111827) : Colors.white,
          onSurface: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF101828),
          onSurfaceVariant: isDark
              ? const Color(0xFFD0D5DD)
              : const Color(0xFF475467),
          outline: isDark ? const Color(0xFF98A2B3) : const Color(0xFF667085),
          outlineVariant: isDark
              ? const Color(0xFF475467)
              : const Color(0xFFD0D5DD),
          inverseSurface: isDark
              ? const Color(0xFFF8FAFC)
              : const Color(0xFF1D2939),
          onInverseSurface: isDark
              ? const Color(0xFF1D2939)
              : const Color(0xFFF8FAFC),
          inversePrimary: isDark
              ? const Color(0xFF0D47A1)
              : const Color(0xFFA8C7FA),
        );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'Roboto',
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      extensions: [semanticColors],
    );
    final textTheme = _textTheme(base.textTheme, scheme);

    return base.copyWith(
      scaffoldBackgroundColor: isDark
          ? const Color(0xFF0B1220)
          : const Color(0xFFF4F7FB),
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(color: scheme.onSurface, size: 24),
      cardTheme: CardThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: isDark ? 0.40 : 0.16),
        elevation: 2,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: ParkRadarRadii.card),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: ParkRadarSpacing.md,
          vertical: ParkRadarSpacing.md,
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        floatingLabelStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w500,
        ),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
        border: OutlineInputBorder(
          borderRadius: ParkRadarRadii.card,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: ParkRadarRadii.card,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: ParkRadarRadii.card,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: ParkRadarRadii.card,
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: ParkRadarRadii.card,
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(
            Size(
              ParkRadarSizes.minimumTouchTarget,
              ParkRadarSizes.primaryControlHeight,
            ),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: ParkRadarSpacing.lg),
          ),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: ParkRadarRadii.control),
          ),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(
            Size(
              ParkRadarSizes.minimumTouchTarget,
              ParkRadarSizes.primaryControlHeight,
            ),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: ParkRadarSpacing.md),
          ),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: ParkRadarRadii.control),
          ),
          side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(
            Size(
              ParkRadarSizes.minimumTouchTarget,
              ParkRadarSizes.minimumTouchTarget,
            ),
          ),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: ParkRadarRadii.control),
          ),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
        ),
      ),
      iconButtonTheme: const IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(
            Size.square(ParkRadarSizes.minimumTouchTarget),
          ),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: semanticColors.mapControlSurface,
        foregroundColor: semanticColors.brand,
        elevation: 3,
        focusElevation: 4,
        hoverElevation: 4,
        shape: const CircleBorder(),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: semanticColors.neutral.background,
        selectedColor: scheme.primaryContainer,
        disabledColor: scheme.surfaceContainerHighest,
        side: BorderSide(color: semanticColors.neutral.border),
        shape: const RoundedRectangleBorder(borderRadius: ParkRadarRadii.pill),
        labelStyle: textTheme.labelMedium,
        padding: const EdgeInsets.symmetric(horizontal: ParkRadarSpacing.xs),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surface,
        modalBarrierColor: semanticColors.mapScrim,
        showDragHandle: true,
        dragHandleColor: scheme.outline,
        shape: const RoundedRectangleBorder(
          borderRadius: ParkRadarRadii.topPanel,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: ParkRadarRadii.panel),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.inversePrimary,
        shape: const RoundedRectangleBorder(
          borderRadius: ParkRadarRadii.control,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: ParkRadarRadii.control,
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onInverseSurface,
        ),
        waitDuration: const Duration(milliseconds: 500),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.primaryContainer,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
        showValueIndicator: ShowValueIndicator.onlyForDiscrete,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.primaryContainer,
        circularTrackColor: scheme.primaryContainer,
      ),
      focusColor: scheme.primary.withValues(alpha: 0.16),
      hoverColor: scheme.primary.withValues(alpha: 0.08),
      highlightColor: scheme.primary.withValues(alpha: 0.10),
    );
  }

  static TextTheme _textTheme(TextTheme base, ColorScheme scheme) {
    return base.copyWith(
      displayLarge: base.displayLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 32,
        height: 1.20,
        fontWeight: FontWeight.w700,
      ),
      headlineLarge: base.headlineLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 28,
        height: 1.25,
        fontWeight: FontWeight.w700,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        color: scheme.onSurface,
        fontSize: 24,
        height: 1.30,
        fontWeight: FontWeight.w700,
      ),
      titleLarge: base.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 22,
        height: 1.30,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: base.titleMedium?.copyWith(
        color: scheme.onSurface,
        fontSize: 18,
        height: 1.35,
        fontWeight: FontWeight.w700,
      ),
      titleSmall: base.titleSmall?.copyWith(
        color: scheme.onSurface,
        fontSize: 16,
        height: 1.40,
        fontWeight: FontWeight.w500,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 17,
        height: 1.50,
        fontWeight: FontWeight.w400,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        color: scheme.onSurface,
        fontSize: 16,
        height: 1.50,
        fontWeight: FontWeight.w400,
      ),
      bodySmall: base.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
        fontSize: 14,
        height: 1.45,
        fontWeight: FontWeight.w400,
      ),
      labelLarge: base.labelLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 15,
        height: 1.35,
        fontWeight: FontWeight.w700,
      ),
      labelMedium: base.labelMedium?.copyWith(
        color: scheme.onSurface,
        fontSize: 14,
        height: 1.35,
        fontWeight: FontWeight.w500,
      ),
      labelSmall: base.labelSmall?.copyWith(
        color: scheme.onSurfaceVariant,
        fontSize: 12,
        height: 1.35,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
