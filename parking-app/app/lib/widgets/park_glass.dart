import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../design_system/design_system.dart';

/// Surface « verre dépoli » pour les éléments flottant au-dessus de la carte
/// (recherche, contrôles, légende) — le langage visuel Waze/Apple Maps.
///
/// [enabled] permet de couper le flou en mode conduite : au volant, le
/// contraste prime sur l'esthétique (contrainte de l'audit design).
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
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: ParkRadarBlur.glass,
          sigmaY: ParkRadarBlur.glass,
        ),
        child: Material(
          color: colors.mapControlSurface.withValues(alpha: 0.78),
          elevation: 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant.withValues(
                  alpha: 0.4,
                ),
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
