import 'package:flutter/material.dart';

import '../design_system/design_system.dart';

/// Bouton circulaire flottant posé sur la carte (langage Waze/Apple Plans).
///
/// Volontairement SANS BackdropFilter (bug de rendu Impeller iOS) : surface
/// quasi opaque + liseré fin, même recette que [ParkGlass].
class ParkMapFab extends StatelessWidget {
  const ParkMapFab({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.active = false,
    this.opaque = false,
  });

  /// Passe un [Icon] (ou un AnimatedSwitcher d'icônes).
  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Couche activée : fond bleu marque, icône inversée.
  final bool active;

  /// Mode conduite : surface 100 % opaque, le contraste prime.
  final bool opaque;

  @override
  Widget build(BuildContext context) {
    final colors = context.parkRadarColors;
    final background = active
        ? colors.brand
        : opaque
            ? colors.mapControlSurface
            : colors.mapControlSurface.withValues(alpha: 0.94);
    final foreground = active ? colors.onBrand : colors.mapControlForeground;
    return Material(
      color: background,
      shape: active
          ? const CircleBorder()
          : CircleBorder(
              side: BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: 0.4),
              ),
            ),
      elevation: active ? 6 : 4,
      shadowColor: Colors.black45,
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        color: foreground,
        iconSize: ParkRadarSizes.icon,
        constraints: const BoxConstraints.tightFor(
          width: ParkRadarSizes.mapFab,
          height: ParkRadarSizes.mapFab,
        ),
        icon: icon,
      ),
    );
  }
}
