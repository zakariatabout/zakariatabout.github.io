import 'package:flutter/material.dart';

import '../design_system/design_system.dart';

/// Surface flottante pour les éléments posés au-dessus de la carte
/// (recherche, contrôles, légende) — le langage visuel Waze/Apple Maps.
///
/// Volontairement SANS BackdropFilter : le flou d'arrière-plan bave hors de
/// son clip sur iOS (Impeller) et assombrissait toute la carte. Une surface
/// quasi opaque avec un fin liseré donne le même effet « carte flottante »
/// sans artefact ni coût GPU.
///
/// [enabled] force une surface pleinement opaque en mode conduite : au
/// volant, le contraste prime sur l'esthétique (contrainte de l'audit design).
class ParkGlass extends StatelessWidget {
  const ParkGlass({
    super.key,
    required this.child,
    required this.borderRadius,
    this.enabled = true,
    this.elevation = 3,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final bool enabled;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final colors = context.parkRadarColors;
    if (!enabled) {
      return Material(
        color: colors.mapControlSurface,
        elevation: elevation,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: child,
      );
    }
    return Material(
      color: colors.mapControlSurface.withValues(alpha: 0.94),
      elevation: elevation,
      shadowColor: Colors.black26,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: child,
      ),
    );
  }
}
