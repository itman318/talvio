import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Birthday party over a profile: fireworks burst in the sky while balloons float up.
/// Plays for a few seconds (and again on [replay]); it never blocks taps.
class BirthdayCelebration extends StatefulWidget {
  const BirthdayCelebration({super.key, this.seconds = 7});
  final int seconds;

  @override
  State<BirthdayCelebration> createState() => BirthdayCelebrationState();
}

class BirthdayCelebrationState extends State<BirthdayCelebration> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Duration(seconds: widget.seconds))..forward();
  int _seed = DateTime.now().millisecond;

  void replay() {
    setState(() => _seed++);
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => _c.isCompleted ? const SizedBox.expand() : CustomPaint(painter: _PartyPainter(_c.value, _seed, widget.seconds.toDouble()), size: Size.infinite),
        ),
      ),
    );
  }
}

class _PartyPainter extends CustomPainter {
  _PartyPainter(this.t, this.seed, this.seconds);
  final double t; // 0..1
  final int seed;
  final double seconds;

  static const _colors = [Color(0xFFFF5E8A), Color(0xFFFFC94D), Color(0xFF8E54E9), Color(0xFF3CC8FF), Color(0xFF2ED47A), Color(0xFFFF8A3D)];

  @override
  void paint(Canvas canvas, Size size) {
    final now = t * seconds; // seconds since start
    final fade = t > 0.85 ? (1 - t) / 0.15 : 1.0;
    _fireworks(canvas, size, now, fade);
    _balloons(canvas, size, now, fade);
  }

  void _fireworks(Canvas c, Size s, double now, double fade) {
    final rnd = math.Random(seed);
    for (var i = 0; i < 9; i++) {
      final start = i * 0.65 + rnd.nextDouble() * 0.3;
      final center = Offset(s.width * (0.12 + rnd.nextDouble() * 0.76), s.height * (0.08 + rnd.nextDouble() * 0.32));
      final color = _colors[rnd.nextInt(_colors.length)];
      final rays = 16 + rnd.nextInt(8);
      final radius = 50 + rnd.nextDouble() * 50;
      final age = now - start;
      if (age < 0 || age > 1.6) continue;
      if (age < 0.35) {
        // the rocket rising to the burst point
        final p = age / 0.35;
        final from = Offset(center.dx, s.height * 0.7);
        final pos = Offset.lerp(from, center, Curves.easeOut.transform(p))!;
        c.drawCircle(pos, 2.4, Paint()..color = color.withValues(alpha: fade));
        c.drawLine(pos, Offset.lerp(pos, from, 0.08)!, Paint()
          ..color = color.withValues(alpha: 0.5 * fade)
          ..strokeWidth = 2);
        continue;
      }
      final p = ((age - 0.35) / 1.25).clamp(0.0, 1.0);
      final r = radius * Curves.easeOutCubic.transform(p);
      final alpha = (1 - p) * fade;
      final paint = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2.6 * (1 - p * 0.6);
      for (var k = 0; k < rays; k++) {
        final a = k * 2 * math.pi / rays;
        final dir = Offset(math.cos(a), math.sin(a));
        final drop = Offset(0, 18 * p * p); // gravity
        final tip = center + dir * r + drop;
        final tail = center + dir * (r * 0.72) + drop * 0.8;
        paint.color = (k.isEven ? color : Colors.white).withValues(alpha: alpha);
        c.drawLine(tail, tip, paint);
        if (p > 0.55 && k % 3 == 0) {
          c.drawCircle(tip + Offset(0, 6 * p), 1.6, Paint()..color = color.withValues(alpha: alpha * 0.8)); // sparkle
        }
      }
      // flash at the start of the burst
      if (p < 0.15) {
        c.drawCircle(center, 10 * (1 - p / 0.15), Paint()
          ..color = Colors.white.withValues(alpha: 0.8 * fade)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      }
    }
  }

  void _balloons(Canvas c, Size s, double now, double fade) {
    final rnd = math.Random(seed + 99);
    for (var i = 0; i < 11; i++) {
      final x0 = s.width * (0.06 + rnd.nextDouble() * 0.88);
      final delay = rnd.nextDouble() * 2.2;
      final speed = s.height * (0.16 + rnd.nextDouble() * 0.1); // px per second
      final color = _colors[i % _colors.length];
      final r = 17 + rnd.nextDouble() * 10;
      final age = now - delay;
      if (age < 0) continue;
      final y = s.height + r * 2 - age * speed;
      if (y < -r * 4) continue;
      final x = x0 + math.sin(age * 1.6 + i) * 14;
      final center = Offset(x, y);
      // string
      final path = Path()..moveTo(x, y + r * 1.2);
      for (var k = 1; k <= 6; k++) {
        path.lineTo(x + math.sin(age * 3 + k) * 3, y + r * 1.2 + k * 9);
      }
      c.drawPath(path, Paint()
        ..color = Colors.black.withValues(alpha: 0.25 * fade)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
      // balloon with a shine
      final rect = Rect.fromCenter(center: center, width: r * 1.7, height: r * 2.1);
      c.drawOval(rect, Paint()
        ..shader = RadialGradient(center: const Alignment(-0.35, -0.45), radius: 0.9, colors: [Color.lerp(color, Colors.white, 0.45)!, color, Color.lerp(color, Colors.black, 0.2)!])
            .createShader(rect)
        ..color = Colors.white.withValues(alpha: fade));
      final knot = Path()
        ..moveTo(x - 3.5, rect.bottom + 3)
        ..lineTo(x + 3.5, rect.bottom + 3)
        ..lineTo(x, rect.bottom - 1)
        ..close();
      c.drawPath(knot, Paint()..color = color.withValues(alpha: fade));
      c.drawOval(Rect.fromCenter(center: center + Offset(-r * 0.32, -r * 0.42), width: r * 0.32, height: r * 0.55), Paint()..color = Colors.white.withValues(alpha: 0.55 * fade));
    }
  }

  @override
  bool shouldRepaint(_PartyPainter old) => old.t != t || old.seed != seed;
}
