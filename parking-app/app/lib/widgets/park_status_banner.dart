import 'package:flutter/material.dart';

import '../design_system/design_system.dart';

enum ParkStatusTone { neutral, info, success, warning, error }

/// Message d'état contextuel pour les erreurs réseau, la fraîcheur des données
/// ou une confirmation. Les actions passent sous le texte sur petit écran afin
/// de rester utilisables avec Dynamic Type.
class ParkStatusBanner extends StatelessWidget {
  const ParkStatusBanner({
    super.key,
    required this.title,
    this.message,
    this.tone = ParkStatusTone.info,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.liveRegion = true,
  }) : assert(
         (actionLabel == null && onAction == null) ||
             (actionLabel != null && onAction != null),
         'actionLabel et onAction doivent être fournis ensemble.',
       );

  final String title;
  final String? message;
  final ParkStatusTone tone;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final colors = context.parkRadarColors;
    final palette = switch (tone) {
      ParkStatusTone.neutral => colors.neutral,
      ParkStatusTone.info => colors.info,
      ParkStatusTone.success => colors.success,
      ParkStatusTone.warning => colors.warning,
      ParkStatusTone.error => colors.danger,
    };
    final resolvedIcon =
        icon ??
        switch (tone) {
          ParkStatusTone.neutral => Icons.info_outline,
          ParkStatusTone.info => Icons.info_outline,
          ParkStatusTone.success => Icons.check_circle_outline,
          ParkStatusTone.warning => Icons.warning_amber_rounded,
          ParkStatusTone.error => Icons.error_outline,
        };

    return Semantics(
      container: true,
      liveRegion: liveRegion,
      child: Material(
        color: palette.background,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: ParkRadarRadii.card,
          side: BorderSide(color: palette.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(ParkRadarSpacing.md),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final inlineAction = constraints.maxWidth >= 480;
              final titleStyle = Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(color: palette.foreground);
              final messageStyle = Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: palette.foreground);
              final leading = ExcludeSemantics(
                child: Icon(
                  resolvedIcon,
                  color: palette.foreground,
                  size: ParkRadarSizes.icon,
                ),
              );
              final dismiss = onDismiss == null
                  ? null
                  : IconButton(
                      onPressed: onDismiss,
                      tooltip: 'Fermer le message',
                      color: palette.foreground,
                      icon: const Icon(Icons.close),
                    );

              if (!inlineAction) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        leading,
                        const SizedBox(width: ParkRadarSpacing.sm),
                        Expanded(child: Text(title, style: titleStyle)),
                        ?dismiss,
                      ],
                    ),
                    if (message != null) ...[
                      const SizedBox(height: ParkRadarSpacing.xs),
                      Text(message!, style: messageStyle),
                    ],
                    if (onAction != null) ...[
                      const SizedBox(height: ParkRadarSpacing.xs),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: onAction,
                          style: TextButton.styleFrom(
                            foregroundColor: palette.foreground,
                          ),
                          child: Text(actionLabel!),
                        ),
                      ),
                    ],
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  leading,
                  const SizedBox(width: ParkRadarSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: titleStyle),
                        if (message != null) ...[
                          const SizedBox(height: ParkRadarSpacing.xxs),
                          Text(message!, style: messageStyle),
                        ],
                      ],
                    ),
                  ),
                  if (onAction != null) ...[
                    const SizedBox(width: ParkRadarSpacing.sm),
                    TextButton(
                      onPressed: onAction,
                      style: TextButton.styleFrom(
                        foregroundColor: palette.foreground,
                      ),
                      child: Text(actionLabel!),
                    ),
                  ],
                  ?dismiss,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
