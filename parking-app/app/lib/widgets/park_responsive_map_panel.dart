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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isBottom = placement == ParkMapPanelPlacement.bottom;
    final borderRadius = isBottom ? ParkRadarRadii.sheet : ParkRadarRadii.panel;

    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              // surfaceContainerHigh -> surfaceContainerLow de la rampe ardoise.
              ? const [Color(0xFF1E293B), Color(0xFF131E33)]
              // Blanc -> crème de marque.
              : const [Color(0xFFFFFFFF), Color(0xFFFAF7F2)],
        ),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFE4E7EC),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.50 : 0.16),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isBottom)
                Padding(
                  padding: const EdgeInsets.only(top: ParkRadarSpacing.xs),
                  child: Container(
                    width: ParkRadarSizes.grabHandleWidth,
                    height: ParkRadarSizes.grabHandleHeight,
                    decoration: BoxDecoration(
                      color: scheme.outlineVariant.withValues(
                        alpha: isDark ? 0.9 : 0.8,
                      ),
                      borderRadius: ParkRadarRadii.pill,
                    ),
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(
                    ParkRadarSpacing.md,
                    ParkRadarSpacing.sm,
                    ParkRadarSpacing.md,
                    ParkRadarSpacing.md,
                  ),
                  child: child,
                ),
              ),
            ],
          ),
        ),
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
            // 16 dp : la pilule flotte, elle ne touche plus les bords.
            : ParkRadarSpacing.md;
        return SafeArea(
          bottom: false,
          minimum: EdgeInsets.only(
            left: horizontal,
            right: horizontal,
            top: ParkRadarSpacing.xs, // 8 dp sous la status bar, façon Waze
            bottom: ParkRadarSpacing.sm,
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
