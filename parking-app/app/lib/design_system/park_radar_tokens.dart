import 'package:flutter/material.dart';

/// Une paire de couleurs sémantiques utilisable pour un badge, une bannière
/// ou un état de donnée. La bordure évite de transmettre l'information par la
/// couleur de fond seule.
@immutable
class ParkRadarTone {
  const ParkRadarTone({
    required this.foreground,
    required this.background,
    required this.border,
  });

  final Color foreground;
  final Color background;
  final Color border;

  static ParkRadarTone lerp(ParkRadarTone a, ParkRadarTone b, double t) {
    return ParkRadarTone(
      foreground: Color.lerp(a.foreground, b.foreground, t)!,
      background: Color.lerp(a.background, b.background, t)!,
      border: Color.lerp(a.border, b.border, t)!,
    );
  }
}

/// Couleurs propres à ParkRadar qui ne rentrent pas dans [ColorScheme].
///
/// Les composants lisent ces rôles plutôt que des couleurs brutes. Cela
/// garantit que les mêmes états restent compréhensibles en clair et en sombre.
@immutable
class ParkRadarColors extends ThemeExtension<ParkRadarColors> {
  const ParkRadarColors({
    required this.brand,
    required this.onBrand,
    required this.route,
    required this.routeCasing,
    required this.mapControlSurface,
    required this.mapControlForeground,
    required this.mapScrim,
    required this.confidenceLow,
    required this.confidenceMedium,
    required this.confidenceHigh,
    required this.confidenceUnknown,
    required this.info,
    required this.success,
    required this.warning,
    required this.danger,
    required this.neutral,
  });

  static const light = ParkRadarColors(
    brand: Color(0xFF0D47A1),
    onBrand: Color(0xFFFFFFFF),
    route: Color(0xFF1565C0),
    routeCasing: Color(0xFFFFFFFF),
    mapControlSurface: Color(0xF7FFFFFF),
    mapControlForeground: Color(0xFF101828),
    mapScrim: Color(0x73000000),
    confidenceLow: ParkRadarTone(
      foreground: Color(0xFF8A1C4A),
      background: Color(0xFFFCE7F3),
      border: Color(0xFFF2A7C6),
    ),
    confidenceMedium: ParkRadarTone(
      foreground: Color(0xFF714500),
      background: Color(0xFFFFF3D6),
      border: Color(0xFFE8BD62),
    ),
    confidenceHigh: ParkRadarTone(
      foreground: Color(0xFF006052),
      background: Color(0xFFDDF7F0),
      border: Color(0xFF75CDBE),
    ),
    confidenceUnknown: ParkRadarTone(
      foreground: Color(0xFF475467),
      background: Color(0xFFF2F4F7),
      border: Color(0xFFD0D5DD),
    ),
    info: ParkRadarTone(
      foreground: Color(0xFF084B8A),
      background: Color(0xFFE7F1FF),
      border: Color(0xFFA7C7F7),
    ),
    success: ParkRadarTone(
      foreground: Color(0xFF006052),
      background: Color(0xFFDDF7F0),
      border: Color(0xFF75CDBE),
    ),
    warning: ParkRadarTone(
      foreground: Color(0xFF714500),
      background: Color(0xFFFFF3D6),
      border: Color(0xFFE8BD62),
    ),
    danger: ParkRadarTone(
      foreground: Color(0xFF8B1E1E),
      background: Color(0xFFFDECEC),
      border: Color(0xFFF0A6A6),
    ),
    neutral: ParkRadarTone(
      foreground: Color(0xFF344054),
      background: Color(0xFFF2F4F7),
      border: Color(0xFFD0D5DD),
    ),
  );

  static const dark = ParkRadarColors(
    brand: Color(0xFFA8C7FA),
    onBrand: Color(0xFF062E6F),
    route: Color(0xFF73A7FF),
    routeCasing: Color(0xFF0B1220),
    mapControlSurface: Color(0xF21A2230),
    mapControlForeground: Color(0xFFF8FAFC),
    mapScrim: Color(0x99000000),
    confidenceLow: ParkRadarTone(
      foreground: Color(0xFFFFB4D2),
      background: Color(0xFF4B1630),
      border: Color(0xFFA94A75),
    ),
    confidenceMedium: ParkRadarTone(
      foreground: Color(0xFFFFD58A),
      background: Color(0xFF442F05),
      border: Color(0xFF8C681E),
    ),
    confidenceHigh: ParkRadarTone(
      foreground: Color(0xFF7EE7D1),
      background: Color(0xFF073D35),
      border: Color(0xFF1A7F70),
    ),
    confidenceUnknown: ParkRadarTone(
      foreground: Color(0xFFD0D5DD),
      background: Color(0xFF27303F),
      border: Color(0xFF667085),
    ),
    info: ParkRadarTone(
      foreground: Color(0xFFA8C7FA),
      background: Color(0xFF12345A),
      border: Color(0xFF3F70A8),
    ),
    success: ParkRadarTone(
      foreground: Color(0xFF7EE7D1),
      background: Color(0xFF073D35),
      border: Color(0xFF1A7F70),
    ),
    warning: ParkRadarTone(
      foreground: Color(0xFFFFD58A),
      background: Color(0xFF442F05),
      border: Color(0xFF8C681E),
    ),
    danger: ParkRadarTone(
      foreground: Color(0xFFFFB4AB),
      background: Color(0xFF5A1A17),
      border: Color(0xFFA64942),
    ),
    neutral: ParkRadarTone(
      foreground: Color(0xFFD0D5DD),
      background: Color(0xFF27303F),
      border: Color(0xFF667085),
    ),
  );

  final Color brand;
  final Color onBrand;
  final Color route;
  final Color routeCasing;
  final Color mapControlSurface;
  final Color mapControlForeground;
  final Color mapScrim;
  final ParkRadarTone confidenceLow;
  final ParkRadarTone confidenceMedium;
  final ParkRadarTone confidenceHigh;
  final ParkRadarTone confidenceUnknown;
  final ParkRadarTone info;
  final ParkRadarTone success;
  final ParkRadarTone warning;
  final ParkRadarTone danger;
  final ParkRadarTone neutral;

  @override
  ParkRadarColors copyWith({
    Color? brand,
    Color? onBrand,
    Color? route,
    Color? routeCasing,
    Color? mapControlSurface,
    Color? mapControlForeground,
    Color? mapScrim,
    ParkRadarTone? confidenceLow,
    ParkRadarTone? confidenceMedium,
    ParkRadarTone? confidenceHigh,
    ParkRadarTone? confidenceUnknown,
    ParkRadarTone? info,
    ParkRadarTone? success,
    ParkRadarTone? warning,
    ParkRadarTone? danger,
    ParkRadarTone? neutral,
  }) {
    return ParkRadarColors(
      brand: brand ?? this.brand,
      onBrand: onBrand ?? this.onBrand,
      route: route ?? this.route,
      routeCasing: routeCasing ?? this.routeCasing,
      mapControlSurface: mapControlSurface ?? this.mapControlSurface,
      mapControlForeground: mapControlForeground ?? this.mapControlForeground,
      mapScrim: mapScrim ?? this.mapScrim,
      confidenceLow: confidenceLow ?? this.confidenceLow,
      confidenceMedium: confidenceMedium ?? this.confidenceMedium,
      confidenceHigh: confidenceHigh ?? this.confidenceHigh,
      confidenceUnknown: confidenceUnknown ?? this.confidenceUnknown,
      info: info ?? this.info,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      neutral: neutral ?? this.neutral,
    );
  }

  @override
  ParkRadarColors lerp(covariant ParkRadarColors? other, double t) {
    if (other == null) return this;
    return ParkRadarColors(
      brand: Color.lerp(brand, other.brand, t)!,
      onBrand: Color.lerp(onBrand, other.onBrand, t)!,
      route: Color.lerp(route, other.route, t)!,
      routeCasing: Color.lerp(routeCasing, other.routeCasing, t)!,
      mapControlSurface: Color.lerp(
        mapControlSurface,
        other.mapControlSurface,
        t,
      )!,
      mapControlForeground: Color.lerp(
        mapControlForeground,
        other.mapControlForeground,
        t,
      )!,
      mapScrim: Color.lerp(mapScrim, other.mapScrim, t)!,
      confidenceLow: ParkRadarTone.lerp(confidenceLow, other.confidenceLow, t),
      confidenceMedium: ParkRadarTone.lerp(
        confidenceMedium,
        other.confidenceMedium,
        t,
      ),
      confidenceHigh: ParkRadarTone.lerp(
        confidenceHigh,
        other.confidenceHigh,
        t,
      ),
      confidenceUnknown: ParkRadarTone.lerp(
        confidenceUnknown,
        other.confidenceUnknown,
        t,
      ),
      info: ParkRadarTone.lerp(info, other.info, t),
      success: ParkRadarTone.lerp(success, other.success, t),
      warning: ParkRadarTone.lerp(warning, other.warning, t),
      danger: ParkRadarTone.lerp(danger, other.danger, t),
      neutral: ParkRadarTone.lerp(neutral, other.neutral, t),
    );
  }
}

extension ParkRadarThemeContext on BuildContext {
  ParkRadarColors get parkRadarColors {
    final colors = Theme.of(this).extension<ParkRadarColors>();
    assert(
      colors != null,
      'ParkRadarColors doit être installé dans ThemeData.',
    );
    return colors!;
  }
}

abstract final class ParkRadarSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

abstract final class ParkRadarRadii {
  static const BorderRadius control = BorderRadius.all(Radius.circular(12));
  static const BorderRadius card = BorderRadius.all(Radius.circular(16));
  static const BorderRadius panel = BorderRadius.all(Radius.circular(24));
  static const BorderRadius topPanel = BorderRadius.vertical(
    top: Radius.circular(24),
  );
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

/// Intensités de flou des surfaces « verre dépoli ».
abstract final class ParkRadarBlur {
  static const double glass = 14;
}

abstract final class ParkRadarMotion {
  static const Duration feedback = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 200);
  static const Duration panel = Duration(milliseconds: 300);
  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
}

abstract final class ParkRadarSizes {
  static const double minimumTouchTarget = 48;
  static const double primaryControlHeight = 52;
  static const double searchFieldHeight = 56;
  static const double icon = 24;
  static const double compactIcon = 18;
}

abstract final class ParkRadarBreakpoints {
  static const double phone = 600;
  static const double sidePanel = 840;
  static const double desktop = 1024;
  static const double searchMaxWidth = 520;
  static const double panelMaxWidth = 420;

  static bool usesSidePanel(Size size) {
    return size.width >= sidePanel ||
        (size.width >= phone && size.width > size.height * 1.25);
  }
}
