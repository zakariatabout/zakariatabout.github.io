import 'package:flutter/foundation.dart' show kIsWeb;
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
          seedColor: const Color(0xFF2563EB),
          brightness: brightness,
        ).copyWith(
          primary: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
          onPrimary: isDark ? const Color(0xFF172554) : Colors.white,
          primaryContainer: isDark
              ? const Color(0xFF1E3A8A)
              : const Color(0xFFDBEAFE),
          onPrimaryContainer: isDark
              ? const Color(0xFFDBEAFE)
              : const Color(0xFF1E3A8A),
          secondary: isDark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A),
          onSecondary: isDark ? const Color(0xFF052E16) : Colors.white,
          secondaryContainer: isDark
              ? const Color(0xFF14532D)
              : const Color(0xFFDCFCE7),
          onSecondaryContainer: isDark
              ? const Color(0xFFBBF7D0)
              : const Color(0xFF14532D),
          error: isDark ? const Color(0xFFF97066) : const Color(0xFFD92D20),
          onError: isDark ? const Color(0xFF450A0A) : Colors.white,
          errorContainer: isDark
              ? const Color(0xFF4C1512)
              : const Color(0xFFFEE4E2),
          onErrorContainer: isDark
              ? const Color(0xFFFECDCA)
              : const Color(0xFF7A271A),
          surface: isDark ? const Color(0xFF0F172A) : Colors.white,
          onSurface: isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A),
          onSurfaceVariant: isDark
              ? const Color(0xFFCBD5E1)
              : const Color(0xFF475569),
          // Rampe ardoise complète : map_screen lit surfaceContainer et le
          // chipTheme lit surfaceContainerHighest — sans overrides, fromSeed
          // injecte des gris M3 teintés hors palette.
          surfaceDim: isDark ? const Color(0xFF0B1220) : const Color(0xFFEDE9E1),
          surfaceBright: isDark ? const Color(0xFF334155) : Colors.white,
          surfaceContainerLowest: isDark
              ? const Color(0xFF0B1220)
              : Colors.white,
          surfaceContainerLow: isDark
              ? const Color(0xFF131E33)
              : const Color(0xFFFAF7F2),
          surfaceContainer: isDark
              ? const Color(0xFF16223A)
              : const Color(0xFFF4F0E9),
          surfaceContainerHigh: isDark
              ? const Color(0xFF1E293B)
              : const Color(0xFFEDE9E1),
          surfaceContainerHighest: isDark
              ? const Color(0xFF243247)
              : const Color(0xFFE6E1D8),
          // Outline plus clair en sombre : #64748B fixe ferait chuter les
          // bordures à 3,7:1 la nuit (6:1 avec #94A3B8).
          outline: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
          outlineVariant: isDark
              ? const Color(0xFF334155)
              : const Color(0xFFCBD5E1),
          inverseSurface: isDark
              ? const Color(0xFFF8FAFC)
              : const Color(0xFF1E293B),
          onInverseSurface: isDark
              ? const Color(0xFF0F172A)
              : const Color(0xFFF8FAFC),
          inversePrimary: isDark
              ? const Color(0xFF2563EB)
              : const Color(0xFF60A5FA),
          surfaceTint: Colors.transparent,
        );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      // iOS/Android : null => police système (.SF Pro Text/Display sur iOS).
      // Web : garder la Roboto embarquée pour éviter le fallback réseau
      // fonts.gstatic.com.
      fontFamily: kIsWeb ? 'Roboto' : null,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      extensions: [semanticColors],
    );
    final textTheme = _textTheme(base.textTheme, scheme);

    return base.copyWith(
      scaffoldBackgroundColor: isDark
          ? const Color(0xFF0B1220) // cran le plus profond de la rampe
          : const Color(0xFFFAF7F2), // crème de marque
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
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          elevation: const WidgetStatePropertyAll(0),
          textStyle: WidgetStatePropertyAll(
            textTheme.labelLarge?.copyWith(fontSize: 16, letterSpacing: 0.2),
          ),
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
          shape: const WidgetStatePropertyAll(StadiumBorder()),
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
        fontSize: 34,
        height: 1.15,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.7,
      ),
      headlineLarge: base.headlineLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 28,
        height: 1.20,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        color: scheme.onSurface,
        fontSize: 24,
        height: 1.25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      titleLarge: base.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 22,
        height: 1.25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.35,
      ),
      titleMedium: base.titleMedium?.copyWith(
        color: scheme.onSurface,
        fontSize: 18,
        height: 1.30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.25,
      ),
      titleSmall: base.titleSmall?.copyWith(
        color: scheme.onSurface,
        fontSize: 16,
        height: 1.35,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.15,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 17,
        height: 1.45,
        fontWeight: FontWeight.w400,
        letterSpacing: -0.2,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        color: scheme.onSurface,
        fontSize: 15,
        height: 1.45,
        fontWeight: FontWeight.w400,
        letterSpacing: -0.1,
      ),
      bodySmall: base.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
        fontSize: 13,
        height: 1.40,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
      ),
      labelLarge: base.labelLarge?.copyWith(
        color: scheme.onSurface,
        fontSize: 16,
        height: 1.30,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
      ),
      labelMedium: base.labelMedium?.copyWith(
        color: scheme.onSurface,
        fontSize: 13,
        height: 1.30,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      labelSmall: base.labelSmall?.copyWith(
        color: scheme.onSurfaceVariant,
        fontSize: 11,
        height: 1.30,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    );
  }
}
