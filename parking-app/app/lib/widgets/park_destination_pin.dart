import 'package:flutter/material.dart';

/// Pin de destination « goutte » signature de ParkRadar : bleu marque + liseré
/// blanc, identique dans les deux thèmes. La pointe touche le point
/// géographique : utiliser `alignment: Alignment.topCenter` dans le Marker.
/// MaskFilter.blur est autorisé (ce n'est PAS un BackdropFilter).
class ParkDestinationPin extends StatelessWidget {
  const ParkDestinationPin({
    super.key,
    this.fill = const Color(0xFF2563EB),
    this.ring = const Color(0xFFFFFFFF),
  });

  final Color fill;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(40, 52),
      painter: _PinPainter(fill: fill, ring: ring),
    );
  }
}

class _PinPainter extends CustomPainter {
  const _PinPainter({required this.fill, required this.ring});
  final Color fill;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = w / 2 - 2;
    final head = Offset(w / 2, r + 2);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w / 2, h - 2), width: 14, height: 5),
      Paint()
        ..color = const Color(0x59000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    final path = Path()
      ..addOval(Rect.fromCircle(center: head, radius: r))
      ..moveTo(head.dx - r * 0.62, head.dy + r * 0.76)
      ..quadraticBezierTo(head.dx - r * 0.28, head.dy + r * 1.1, w / 2, h - 3)
      ..quadraticBezierTo(
        head.dx + r * 0.28,
        head.dy + r * 1.1,
        head.dx + r * 0.62,
        head.dy + r * 0.76,
      )
      ..close();
    canvas.drawShadow(path, const Color(0xB3000000), 3, true);
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = ring,
    );
    canvas.drawCircle(head, 6, Paint()..color = ring);
  }

  @override
  bool shouldRepaint(_PinPainter old) => old.fill != fill || old.ring != ring;
}
