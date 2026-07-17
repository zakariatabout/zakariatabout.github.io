import 'package:flutter/material.dart';

import '../design_system/design_system.dart';

enum ParkConfidenceLevel { unknown, low, medium, high }

enum ParkFreshnessLevel { live, fresh, delayed, stale, unavailable }

/// Rend le niveau de confiance avec une icône et un libellé, afin que la
/// couleur ne soit jamais le seul vecteur d'information.
class ParkConfidenceChip extends StatelessWidget {
  const ParkConfidenceChip({super.key, required this.level, this.detail});

  final ParkConfidenceLevel level;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.parkRadarColors;
    final (tone, label, icon) = switch (level) {
      ParkConfidenceLevel.low => (
        colors.confidenceLow,
        'Confiance faible',
        Icons.gpp_maybe_outlined,
      ),
      ParkConfidenceLevel.medium => (
        colors.confidenceMedium,
        'Confiance moyenne',
        Icons.shield_outlined,
      ),
      ParkConfidenceLevel.high => (
        colors.confidenceHigh,
        'Confiance élevée',
        Icons.verified_user_outlined,
      ),
      ParkConfidenceLevel.unknown => (
        colors.confidenceUnknown,
        'Confiance inconnue',
        Icons.help_outline,
      ),
    };
    return _ParkTrustChip(
      tone: tone,
      label: label,
      detail: detail,
      icon: icon,
      semanticLabel: detail == null ? label : '$label, $detail',
    );
  }
}

/// Indique explicitement si les données sont récentes, retardées ou absentes.
/// Le calcul du TTL reste dans la couche métier ; ce widget ne fait qu'afficher
/// l'état déjà décidé par le contrôleur.
class ParkFreshnessChip extends StatelessWidget {
  const ParkFreshnessChip({super.key, required this.level, this.detail});

  final ParkFreshnessLevel level;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.parkRadarColors;
    final (tone, label, icon) = switch (level) {
      ParkFreshnessLevel.live => (
        colors.success,
        'Dernier relevé récent',
        Icons.sensors,
      ),
      ParkFreshnessLevel.fresh => (
        colors.info,
        'Données à jour',
        Icons.schedule,
      ),
      ParkFreshnessLevel.delayed => (
        colors.warning,
        'Données retardées',
        Icons.sync_problem_outlined,
      ),
      ParkFreshnessLevel.stale => (
        colors.danger,
        'Données anciennes',
        Icons.history_toggle_off,
      ),
      ParkFreshnessLevel.unavailable => (
        colors.neutral,
        'Données indisponibles',
        Icons.cloud_off_outlined,
      ),
    };
    return _ParkTrustChip(
      tone: tone,
      label: label,
      detail: detail,
      icon: icon,
      semanticLabel: detail == null ? label : '$label, $detail',
    );
  }
}

class _ParkTrustChip extends StatelessWidget {
  const _ParkTrustChip({
    required this.tone,
    required this.label,
    required this.icon,
    required this.semanticLabel,
    this.detail,
  });

  final ParkRadarTone tone;
  final String label;
  final String? detail;
  final IconData icon;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    // Hiérarchie interne : libellé en semi-gras, détail atténué. Le texte à
    // plat reste « label · détail » (compatible find.textContaining).
    return Semantics(
      container: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tone.background,
            border: Border.all(color: tone.border.withValues(alpha: 0.6)),
            borderRadius: ParkRadarRadii.pill,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: ParkRadarSpacing.sm + 2,
                vertical: 6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: tone.foreground),
                  const SizedBox(width: ParkRadarSpacing.xs),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        text: label,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: tone.foreground,
                              fontWeight: FontWeight.w600,
                            ),
                        children: [
                          if (detail != null)
                            TextSpan(
                              text: ' · $detail',
                              style: TextStyle(
                                fontWeight: FontWeight.w400,
                                color: tone.foreground.withValues(alpha: 0.85),
                              ),
                            ),
                        ],
                      ),
                      softWrap: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
