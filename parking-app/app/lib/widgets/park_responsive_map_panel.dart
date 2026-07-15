import 'package:flutter/material.dart';

import '../design_system/design_system.dart';

enum ParkMapPanelPlacement { bottom, side }

/// Surface adaptative pour le contenu détaillé d'une carte.
///
/// Sur téléphone, elle reste bornée en hauteur au bas de la carte. Sur grand
/// écran ou téléphone en paysage, elle devient un panneau latéral de 420 px.
/// Le parent peut remplacer cette présentation par une
/// [DraggableScrollableSheet] tout en réutilisant [ParkMapPanelSurface].
class ParkResponsiveMapPanel extends StatelessWidget {
  const ParkResponsiveMapPanel({
    super.key,
    required this.child,
    this.scrollController,
    this.sideAlignment = Alignment.centerLeft,
  });

  final Widget child;
  final ScrollController? scrollController;
  final Alignment sideAlignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final placement = ParkRadarBreakpoints.usesSidePanel(size)
            ? ParkMapPanelPlacement.side
            : ParkMapPanelPlacement.bottom;
        final panel = ParkMapPanelSurface(
          placement: placement,
          scrollController: scrollController,
          child: child,
        );

        if (placement == ParkMapPanelPlacement.side) {
          return Align(
            key: const ValueKey('park-map-panel-side'),
            alignment: sideAlignment,
            child: SafeArea(
              minimum: const EdgeInsets.all(ParkRadarSpacing.lg),
              child: SizedBox(
                width: ParkRadarBreakpoints.panelMaxWidth,
                child: panel,
              ),
            ),
          );
        }

        return Align(
          key: const ValueKey('park-map-panel-bottom'),
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(
              ParkRadarSpacing.sm,
              0,
              ParkRadarSpacing.sm,
              ParkRadarSpacing.sm,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 640,
                maxHeight: size.height * 0.58,
              ),
              child: panel,
            ),
          ),
        );
      },
    );
  }
}

/// Surface scrollable et thémée, réutilisable dans un panneau latéral ou une
/// `DraggableScrollableSheet`.
class ParkMapPanelSurface extends StatelessWidget {
  const ParkMapPanelSurface({
    super.key,
    required this.child,
    this.placement = ParkMapPanelPlacement.bottom,
    this.scrollController,
  });

  final Widget child;
  final ParkMapPanelPlacement placement;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final borderRadius = placement == ParkMapPanelPlacement.bottom
        ? ParkRadarRadii.topPanel
        : ParkRadarRadii.panel;

    return Material(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black.withValues(
        alpha: Theme.of(context).brightness == Brightness.dark ? 0.48 : 0.20,
      ),
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        controller: scrollController,
        padding: const EdgeInsets.all(ParkRadarSpacing.md),
        child: child,
      ),
    );
  }
}

/// Gouttières et largeur maximale communes aux overlays supérieurs de carte.
class ParkMapOverlayShell extends StatelessWidget {
  const ParkMapOverlayShell({
    super.key,
    required this.child,
    this.maxWidth = ParkRadarBreakpoints.searchMaxWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = constraints.maxWidth >= ParkRadarBreakpoints.desktop
            ? ParkRadarSpacing.lg
            : ParkRadarSpacing.sm;
        return SafeArea(
          bottom: false,
          minimum: EdgeInsets.symmetric(
            horizontal: horizontal,
            vertical: ParkRadarSpacing.sm,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
