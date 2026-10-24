import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Full-screen message effects: confetti, hearts, balloons, fireworks.
const messageEffects = <(String, String, String)>[
  ('confetti', '🎉', 'Confetti'),
  ('hearts', '❤️', 'Hearts'),
  ('balloons', '🎈', 'Balloons'),
  ('fireworks', '🎆', 'Fireworks'),
];

/// Plays [effect] over the whole screen once.
void playMessageEffect(BuildContext context, String effect) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(builder: (_) => _EffectLayer(effect: effect, onDone: () => entry.remove()));
  overlay.insert(entry);
}

class _EffectLayer extends StatefulWidget {
  const _EffectLayer({required this.effect, required this.onDone});
  final String effect;
  final VoidCallback onDone;

  @override
  State<_EffectLayer> createState() => _EffectLayerState();
}

class _Particle {
  _Particle(this.x, this.y, this.vx, this.vy, this.size, this.color, this.spin, this.delay, this.glyph);
  final double x, y, vx, vy, size, spin, delay;
  final Color color;
  final String? glyph;
}

class _EffectLayerState extends State<_EffectLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))..forward().whenComplete(widget.onDone);
  final _rnd = math.Random();
  late final List<_Particle> _parts = _make();

  static const _colors = [Color(0xFFFF7A59), Color(0xFFF0446E), Color(0xFF8B5CF6), Color(0xFF3C9BEA), Color(0xFF22B573), Color(0xFFF5B544)];

  List<_Particle> _make() {
    double r() => _rnd.nextDouble();
    switch (widget.effect) {
      case 'hearts':
        return List.generate(26, (i) => _Particle(r(), 1.05, (r() - 0.5) * 0.15, -(0.55 + r() * 0.45), 22 + r() * 22, Colors.red, (r() - 0.5) * 0.6, r() * 0.45, ['❤️', '💖', '💕'][i % 3]));
      case 'balloons':
        return List.generate(16, (i) => _Particle(r(), 1.1, (r() - 0.5) * 0.08, -(0.45 + r() * 0.35), 34 + r() * 22, Colors.red, (r() - 0.5) * 0.3, r() * 0.4, '🎈'));
      case 'fireworks':
        final out = <_Particle>[];
        for (var b = 0; b < 4; b++) {
          final cx = 0.2 + r() * 0.6, cy = 0.2 + r() * 0.35, color = _colors[_rnd.nextInt(_colors.length)], d = b * 0.18;
          for (var k = 0; k < 28; k++) {
            final a = k / 28 * math.pi * 2;
            final sp = 0.18 + r() * 0.12;
            out.add(_Particle(cx, cy, math.cos(a) * sp, math.sin(a) * sp, 3 + r() * 2.5, color, 0, d, null));
          }
        }
        return out;
      default: // confetti
        return List.generate(90, (i) => _Particle(r(), -0.05 - r() * 0.3, (r() - 0.5) * 0.25, 0.55 + r() * 0.5, 6 + r() * 6, _colors[i % _colors.length], (r() - 0.5) * 12, r() * 0.25, null));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (ctx, _) {
          final size = MediaQuery.of(ctx).size;
          final t = _c.value;
          final glyphs = <Widget>[];
          for (final p in _parts.where((p) => p.glyph != null)) {
            final lt = ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
            if (lt <= 0) continue;
            final x = (p.x + p.vx * lt + math.sin(lt * 6 + p.x * 10) * 0.03) * size.width;
            final y = (p.y + p.vy * lt * 1.3) * size.height;
            glyphs.add(Positioned(
              left: x - p.size / 2,
              top: y - p.size / 2,
              child: Opacity(
                opacity: lt > 0.85 ? (1 - lt) / 0.15 : 1,
                child: Transform.rotate(angle: p.spin * math.sin(lt * 4), child: Text(p.glyph!, style: TextStyle(fontSize: p.size))),
              ),
            ));
          }
          return Stack(children: [
            Positioned.fill(child: CustomPaint(painter: _ParticlePainter(_parts.where((p) => p.glyph == null).toList(), t, widget.effect))),
            ...glyphs,
          ]);
        },
      ),
    );
  }
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter(this.parts, this.t, this.effect);
  final List<_Particle> parts;
  final double t;
  final String effect;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in parts) {
      final lt = ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      if (lt <= 0) continue;
      if (effect == 'fireworks') {
        final ease = Curves.easeOut.transform(lt);
        final x = (p.x + p.vx * ease) * size.width;
        final y = (p.y + p.vy * ease) * size.height + lt * lt * 60;
        paint.color = p.color.withValues(alpha: (1 - lt).clamp(0.0, 1.0));
        canvas.drawCircle(Offset(x, y), p.size * (1 - lt * 0.5), paint);
      } else {
        final x = (p.x + p.vx * lt + math.sin(lt * 8 + p.x * 20) * 0.02) * size.width;
        final y = (p.y + p.vy * lt * 1.4) * size.height;
        paint.color = p.color.withValues(alpha: lt > 0.85 ? (1 - lt) / 0.15 : 1);
        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(p.spin * lt);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.55), const Radius.circular(1.5)), paint);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter old) => old.t != t;
}
