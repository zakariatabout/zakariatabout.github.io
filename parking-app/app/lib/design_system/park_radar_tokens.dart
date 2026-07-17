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
    required this.routeInner,
    required this.routeGlow,
    required this.mapCasing,
    required this.availabilityHigh,
    required this.availabilityMedium,
    required this.availabilityLow,
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
    route: Color(0xFF2563EB),
    routeCasing: Color(0xFFFFFFFF),
    routeInner: Color(0xFF93C5FD),
    routeGlow: Color(0x2E2563EB),
    mapCasing: Color(0xF2FFFFFF),
    availabilityHigh: Color(0xFF15803D),
    availabilityMedium: Color(0xFFB45309),
    availabilityLow: Color(0xFFDC2626),
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
    brand: Color(0xFF60A5FA),
    onBrand: Color(0xFF172554),
    route: Color(0xFF3B82F6),
    routeCasing: Color(0xFF0B1220),
    routeInner: Color(0xFFA7C8FF),
    routeGlow: Color(0x383B82F6),
    mapCasing: Color(0xE60B1220),
    availabilityHigh: Color(0xFF4ADE80),
    availabilityMedium: Color(0xFFFBBF24),
    availabilityLow: Color(0xFFF97066),
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

  /// Cœur clair du double-trait d'itinéraire (façon Waze nuit).
  final Color routeInner;

  /// Halo translucide sous l'itinéraire (alpha ~20 %).
  final Color routeGlow;

  /// Casing unifié de toutes les couches carte (traits de disponibilité,
  /// boucle, itinéraire) : même bleu-nuit que le fond des tuiles assombries,
  /// pour que les couches paraissent appartenir au même monde.
  final Color mapCasing;

  /// Traits de disponibilité posés sur les tuiles (saturés et lumineux en
  /// sombre). Les tones confidence* restent réservés aux badges/panneaux.
  final Color availabilityHigh;
  final Color availabilityMedium;
  final Color availabilityLow;
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
    Color? routeInner,
    Color? routeGlow,
    Color? mapCasing,
    Color? availabilityHigh,
    Color? availabilityMedium,
    Color? availabilityLow,
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
      routeInner: routeInner ?? this.routeInner,
      routeGlow: routeGlow ?? this.routeGlow,
      mapCasing: mapCasing ?? this.mapCasing,
      availabilityHigh: availabilityHigh ?? this.availabilityHigh,
      availabilityMedium: availabilityMedium ?? this.availabilityMedium,
      availabilityLow: availabilityLow ?? this.availabilityLow,
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
      routeInner: Color.lerp(routeInner, other.routeInner, t)!,
      routeGlow: Color.lerp(routeGlow, other.routeGlow, t)!,
      mapCasing: Color.lerp(mapCasing, other.mapCasing, t)!,
      availabilityHigh: Color.lerp(
        availabilityHigh,
        other.availabilityHigh,
        t,
      )!,
      availabilityMedium: Color.lerp(
        availabilityMedium,
        other.availabilityMedium,
        t,
      )!,
      availabilityLow: Color.lerp(availabilityLow, other.availabilityLow, t)!,
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

  /// Pilule de recherche flottante : 26 = moitié de
  /// [ParkRadarSizes.searchPillHeight], donc extrémités parfaitement rondes.
  static const BorderRadius searchPill = BorderRadius.all(Radius.circular(26));

  /// Feuille basse flottante : très arrondie côté carte, un peu moins en bas.
  static const BorderRadius sheet = BorderRadius.only(
    topLeft: Radius.circular(28),
    topRight: Radius.circular(28),
    bottomLeft: Radius.circular(20),
    bottomRight: Radius.circular(20),
  );
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

  /// Suivi caméra en guidage : LÉGÈREMENT au-dessus de la cadence GPS (1 Hz)
  /// pour que le tween linéaire ne se termine jamais entre deux échantillons,
  /// même avec 100-150 ms de gigue CoreLocation. Toujours associer à
  /// Curves.linear (glissement continu, retard borné ~1 s, standard Waze).
  static const Duration cameraFollow = Duration(milliseconds: 1150);
}

abstract final class ParkRadarSizes {
  static const double minimumTouchTarget = 48;
  static const double primaryControlHeight = 54;
  static const double searchFieldHeight = 56;

  /// Hauteur minimale de la pilule de recherche flottante (>= 48 dp tactile).
  static const double searchPillHeight = 52;
  static const double icon = 24;
  static const double compactIcon = 18;
  static const double grabHandleWidth = 40;
  static const double grabHandleHeight = 4;

  /// Diamètre des boutons flottants posés sur la carte.
  static const double mapFab = 48; // >= 44 (HIG iOS), == minimumTouchTarget

  /// Tuile de manœuvre du HUD de guidage (référence Waze : ~72 dp).
  static const double hudManeuverTile = 72;

  /// Icône de manœuvre dans la tuile.
  static const double hudManeuverIcon = 44;

  /// Action reine du guidage (« Place trouvée ») : plus haute que
  /// [primaryControlHeight] pour être atteignable au pouce sans regarder.
  static const double hudActionHeight = 60;
}

/// Couleurs figées de la pilule de recherche flottante. Volontairement hors
/// [ColorScheme] : la pilule est posée sur la carte OSM, pas sur une surface
/// applicative, et doit rester identique quel que soit le fond de tuiles.
abstract final class ParkRadarSearchPalette {
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color surfaceDark = Color(0xFF1A2230);
  static const Color hintLight = Color(0xFF667085); // 5,0:1 sur surfaceLight
  static const Color hintDark = Color(0xFF98A2B3); // 6,2:1 sur surfaceDark
  static const Color hairlineLight = Color(0xFFE4E7EC);
  static const Color hairlineDark = Color(0xFF2E3A4E);
  static const Color shadowLight = Color(0x29101828);
  static const Color shadowDark = Color(0x66000000);
}

/// Filtres couleur appliqués aux tuiles raster OSM (tile.openstreetmap.org)
/// via ColorFiltered — le pattern natif flutter_map (même base que
/// darkModeTilesContainerBuilder du package). Pipeline sombre composé en une
/// matrice : inversion -> rotation de teinte 180° (luminance 0.213/0.715/0.072,
/// qui garde les parcs verts et l'eau bleue) -> désaturation -> gains par canal
/// vers l'ardoise #0F172A. Offsets > 255 volontaires : résultat clampé [0,255].
abstract final class ParkRadarMapFilters {
  /// SOMBRE (recommandé). Rendu vérifié numériquement sur la palette OSM :
  /// fond #F2EFE9 -> #111521, eau #AAD3DF -> #1F4068, rues #FFFFFF -> #020510,
  /// bâtiments #D9D0C9 -> #2C3449, parcs #ADD19E -> #274842, texte -> ~#BEEDFF.
  static const ColorFilter dark = ColorFilter.matrix(<double>[
    0.1869, -0.9420, -0.0949, 0, 218.75, // R
    -0.3467, -0.5862, -0.1172, 0, 272.75, // G
    -0.4622, -1.5516, 0.6138, 0, 373.00, // B
    0, 0, 0, 1, 0, // A
  ]);

  /// Repli quasi neutre (façon Google Maps dark) si [dark] paraît trop bleuté
  /// sur device : fond #101115, eau #193C57.
  static const ColorFilter darkSubdued = ColorFilter.matrix(<double>[
    0.3471, -1.1512, -0.1159, 0, 234.60, // R
    -0.3728, -0.5013, -0.1260, 0, 257.00, // G
    -0.4398, -1.4765, 0.7363, 0, 308.90, // B
    0, 0, 0, 1, 0, // A
  ]);

  /// CLAIR : désaturation 20 % (poids Rec.709) + voile crème #FAF7F2 à 12 %.
  /// Vérifié : fond #F2EFE9 -> #F2F0EB, blanc -> #FEFEFD (rues nettes),
  /// eau adoucie ; gris quasi neutres (#808080 -> #8F8E8E).
  static const ColorFilter light = ColorFilter.matrix(<double>[
    0.7414, 0.1259, 0.0127, 0, 30.00, // R
    0.0374, 0.8299, 0.0127, 0, 29.64, // G
    0.0374, 0.1259, 0.7167, 0, 29.04, // B
    0, 0, 0, 1, 0, // A
  ]);

  /// Couleur des zones SANS tuile (chargement), APRÈS filtre : doit matcher le
  /// fond de plan filtré pour éviter tout flash (image de #F2EFE9 par [dark]).
  static const Color darkBackdrop = Color(0xFF111521);

  /// Image de #F2EFE9 par [light].
  static const Color lightBackdrop = Color(0xFFF2F0EB);
}

/// Palette du HUD de conduite. Volontairement identique en thème clair et
/// sombre : au volant, l'instruction est toujours rendue sur navy opaque
/// (contraste maximal, zéro translucidité), comme le bandeau de Waze. Même
/// convention que [ParkRadarSearchPalette] : figée hors ColorScheme.
abstract final class ParkRadarHud {
  static const Color surfaceTop = Color(0xFF1E2A44); // haut du dégradé
  static const Color surface = Color(0xFF15203A); // corps (blanc dessus 14,9:1)
  static const Color footer = Color(0xFF101A30); // bandeau ETA
  static const Color divider = Color(0xFF2E3A54);
  static const Color rim = Color(0x803B82F6); // liseré bleu 50 %
  static const Color onSurface = Color(0xFFF8FAFC);
  static const Color muted = Color(0xFF9CB0CC); // 7,8:1 sur footer
  static const Color street = Color(0xFFE2E8F0); // nom de rue
  static const Color unit = Color(0xFFB6C2D9); // unité de distance
  static const Color nextChip = Color(0xFF1B2740); // chip « Puis : … »
  static const Color control = Color(0xFF24314B); // boutons ronds fermer/mute
  static const Color maneuverTile = Color(0xFF2563EB); // bleu marque (5,2:1)
  static const Color onManeuverTile = Color(0xFFFFFFFF);
  static const Color maneuverGlow = Color(0x4D2563EB); // halo ~30 %
  static const BorderRadius radius = BorderRadius.all(Radius.circular(20));
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
