import 'package:flutter/material.dart';

import '../utils/format.dart';

/// Hushavia's own "seen" eye: an almond outline with a round iris and a small spark of light,
/// drawn (not a stock icon) so it stays crisp at tiny sizes next to the time.
class ViewsEye extends StatelessWidget {
  const ViewsEye({super.key, required this.color, this.size = 13});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size(size * 1.25, size), painter: _EyePainter(color));
}

class _EyePainter extends CustomPainter {
  _EyePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height, cy = h / 2;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.13
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // almond: two soft arcs meeting in pointed corners
    final lid = Path()
      ..moveTo(w * 0.04, cy)
      ..quadraticBezierTo(w * 0.5, -h * 0.28, w * 0.96, cy)
      ..quadraticBezierTo(w * 0.5, h * 1.28, w * 0.04, cy)
      ..close();
    canvas.drawPath(lid, stroke);
    // iris + the spark of light that gives it life
    canvas.drawCircle(Offset(w / 2, cy), h * 0.24, Paint()..color = color);
    canvas.drawCircle(Offset(w / 2 + h * 0.08, cy - h * 0.08), h * 0.075, Paint()..color = color.computeLuminance() > 0.6 ? const Color(0xFF1C1838) : Colors.white);
  }

  @override
  bool shouldRepaint(_EyePainter old) => old.color != color;
}

/// The eye and how many people saw it ("1.2K"), as shown under channel posts and group messages.
class ViewsBadge extends StatelessWidget {
  const ViewsBadge({super.key, required this.count, required this.color, this.fontSize = 11.5});
  final int count;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '$count views',
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          ViewsEye(color: color, size: fontSize),
          const SizedBox(width: 3),
          Text(compactNumber(count),
              style: TextStyle(fontSize: fontSize, color: color, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      );
}
