import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_system/design_system.dart';

/// Marqueur véhicule « vivant » : pastille de marque avec anneau pulsant et,
/// en guidage, un cône de cap façon Waze.
///
/// Contraintes héritées de l'audit : constructible en const-like (pas de
/// closure par frame), pulsation coupée quand l'utilisateur préfère les
/// animations réduites, sémantique préservée par l'appelant.
class ParkUserMarker extends StatefulWidget {
  const ParkUserMarker({super.key, this.headingScreenDegrees});

  /// Cap à afficher, déjà converti en angle ÉCRAN (cap GPS + rotation carte).
  /// Null = pas de cône (à l'arrêt ou hors guidage).
  final double? headingScreenDegrees;

  @override
  State<ParkUserMarker> createState() => _ParkUserMarkerState();
}

class _ParkUserMarkerState extends State<ParkUserMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.parkRadarColors;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        // Anneau pulsant : présence vivante sans gêner la lecture.
        if (!reduceMotion)
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final t = Curves.easeOut.transform(_pulse.value);
              return Opacity(
                opacity: (1 - t) * 0.35,
                child: Transform.scale(
                  scale: 0.6 + t * 1.4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.route, width: 3),
                    ),
                    child: const SizedBox.square(dimension: 44),
                  ),
                ),
              );
            },
          ),
        // Cône de cap (sous la pastille).
        if (widget.headingScreenDegrees case final heading?)
          Transform.rotate(
            angle: heading * math.pi / 180,
            child: CustomPaint(
              size: const Size(44, 44),
              painter: _HeadingConePainter(color: colors.route),
            ),
          ),
        // Pastille véhicule.
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.route,
            shape: BoxShape.circle,
            border: Border.all(color: colors.routeCasing, width: 4),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5)],
          ),
          child: const SizedBox.square(dimension: 26),
        ),
      ],
    );
  }
}

class _HeadingConePainter extends CustomPainter {
  const _HeadingConePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color.withValues(alpha: 0.55), color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: size.height / 2));
    final path = Path()
      ..moveTo(center.dx, center.dy)
      ..lineTo(center.dx - 9, 2)
      ..lineTo(center.dx + 9, 2)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_HeadingConePainter oldDelegate) =>
      oldDelegate.color != color;
}
