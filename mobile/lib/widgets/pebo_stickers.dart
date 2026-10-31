import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Pebo: Talvio's own animated sticker pack — a soft mint gummy with big eyes.
/// Everything is drawn in code (vector, sharp at any size, no download) and loops smoothly.
enum PeboPose { hi, love, laugh, cry, angry, cool, thumbsUp, party, sleep, think, wow, ok, kiss, facepalm, run, gift }

/// The pack, in picker order: pose and the emoji it stands for.
const peboStickers = <(PeboPose, String)>[
  (PeboPose.hi, '👋'),
  (PeboPose.love, '😍'),
  (PeboPose.laugh, '😂'),
  (PeboPose.cry, '😭'),
  (PeboPose.angry, '😡'),
  (PeboPose.cool, '😎'),
  (PeboPose.thumbsUp, '👍'),
  (PeboPose.party, '🥳'),
  (PeboPose.sleep, '😴'),
  (PeboPose.think, '🤔'),
  (PeboPose.wow, '😮'),
  (PeboPose.ok, '😊'),
  (PeboPose.kiss, '😘'),
  (PeboPose.facepalm, '🤦'),
  (PeboPose.run, '🏃'),
  (PeboPose.gift, '🎁'),
];

PeboPose? peboPoseByName(String name) {
  for (final p in PeboPose.values) {
    if (p.name == name) return p;
  }
  return null;
}

String peboEmoji(PeboPose p) => peboStickers.firstWhere((e) => e.$1 == p, orElse: () => (p, '🙂')).$2;

class PeboSticker extends StatefulWidget {
  const PeboSticker({super.key, required this.pose, this.size = 150, this.animate = true});
  final PeboPose pose;
  final double size;
  final bool animate;

  @override
  State<PeboSticker> createState() => _PeboStickerState();
}

class _PeboStickerState extends State<PeboSticker> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void didUpdateWidget(PeboSticker old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_c.isAnimating) _c.repeat();
    if (!widget.animate && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => CustomPaint(painter: _PeboPainter(widget.pose, widget.animate ? _c.value : 0.18)),
        ),
      ),
    );
  }
}

class _PeboPainter extends CustomPainter {
  _PeboPainter(this.pose, this.t);
  final PeboPose pose;
  final double t; // 0..1, loops

  static const _top = Color(0xFF8BF5D0);
  static const _bottom = Color(0xFF27B5A6);
  static const _line = Color(0xFF16867D);
  static const _ink = Color(0xFF16213E);
  static const _blush = Color(0xFFFF7FA3);

  double get _w => t * 2 * math.pi; // one full wave per loop

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);

    // body motion per pose: (dx, dy, squash, tilt)
    var dx = 0.0, dy = 0.0, squash = 0.04 * math.sin(_w), tilt = 0.0;
    switch (pose) {
      case PeboPose.hi:
        tilt = 0.06 * math.sin(_w);
      case PeboPose.laugh:
        dy = -3 * (math.sin(_w * 4).abs());
        squash = 0.07 * math.sin(_w * 4);
        tilt = 0.05 * math.sin(_w * 2);
      case PeboPose.cry:
        dy = 1.2 * math.sin(_w * 3);
        squash = 0.03 * math.sin(_w * 3);
      case PeboPose.angry:
        dx = 1.6 * math.sin(_w * 10);
        squash = 0.03;
      case PeboPose.cool:
        dy = 1.5 * math.sin(_w * 2);
        tilt = 0.04 * math.sin(_w);
      case PeboPose.party:
      case PeboPose.gift:
        final j = math.sin(_w * 2);
        dy = -8 * math.max(0, j);
        squash = j < 0 ? 0.09 * -j : -0.05 * j;
      case PeboPose.sleep:
        squash = 0.05 * math.sin(_w);
        tilt = -0.08;
      case PeboPose.think:
        tilt = 0.08 + 0.02 * math.sin(_w);
      case PeboPose.wow:
        final p = (t * 2) % 1;
        dy = p < 0.25 ? -9 * math.sin(p / 0.25 * math.pi) : 0;
        squash = p < 0.25 ? -0.08 : 0.02 * math.sin(_w * 2);
      case PeboPose.ok:
        dy = 1.6 * math.sin(_w * 2);
      case PeboPose.run:
        dy = -2.5 * math.sin(_w * 6).abs();
        tilt = 0.12;
        dx = 2 * math.sin(_w);
      case PeboPose.love:
      case PeboPose.kiss:
        squash = 0.05 * math.sin(_w * 2);
      case PeboPose.thumbsUp:
      case PeboPose.facepalm:
        break;
    }

    _behind(canvas);

    // ground shadow
    final lift = (-dy).clamp(0.0, 12.0) / 12;
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(50, 92), width: 52 * (1 - 0.3 * lift), height: 7 * (1 - 0.3 * lift)),
      Paint()..color = Colors.black.withValues(alpha: 0.13 * (1 - 0.4 * lift)),
    );

    canvas.save();
    canvas.translate(50 + dx, 88 + dy);
    canvas.rotate(tilt);
    canvas.scale(1 + squash, 1 - squash);
    canvas.translate(-50, -88);

    _arms(canvas, back: true);
    _body(canvas);
    _face(canvas);
    _arms(canvas, back: false);
    _props(canvas);
    canvas.restore();

    _front(canvas);
    canvas.restore();
  }

  // ---------------------------------------------------------------- body
  void _body(Canvas c) {
    final r = RRect.fromRectAndCorners(
      const Rect.fromLTWH(18, 30, 64, 58),
      topLeft: const Radius.elliptical(32, 30),
      topRight: const Radius.elliptical(32, 30),
      bottomLeft: const Radius.elliptical(24, 22),
      bottomRight: const Radius.elliptical(24, 22),
    );
    var top = _top, bottom = _bottom;
    if (pose == PeboPose.angry) {
      final k = 0.45 + 0.15 * math.sin(_w * 2);
      top = Color.lerp(_top, const Color(0xFFFF9C8A), k)!;
      bottom = Color.lerp(_bottom, const Color(0xFFE5484D), k)!;
    }
    c.drawRRect(r, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]).createShader(r.outerRect));
    // soft belly + shine
    c.drawOval(const Rect.fromLTWH(32, 60, 36, 24), Paint()..color = Colors.white.withValues(alpha: 0.18));
    c.drawOval(const Rect.fromLTWH(27, 36, 16, 9), Paint()..color = Colors.white.withValues(alpha: 0.55));
    c.drawRRect(r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = pose == PeboPose.angry ? const Color(0xFFB5303A) : _line);
    // little sprout on top
    final sway = 3 * math.sin(_w + 0.6);
    final stem = Path()
      ..moveTo(50, 31)
      ..quadraticBezierTo(50 + sway * 0.4, 25, 50 + sway, 21);
    c.drawPath(stem, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..color = _line);
    final leaf = Path()
      ..moveTo(50 + sway, 21)
      ..quadraticBezierTo(57 + sway, 13, 64 + sway, 18)
      ..quadraticBezierTo(57 + sway, 24, 50 + sway, 21);
    c.drawPath(leaf, Paint()..color = const Color(0xFF5BDB8C));
    c.drawPath(leaf, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = _line);
  }

  // ---------------------------------------------------------------- face
  bool get _blinkNow {
    final p = (t * 1.0) % 1;
    return p > 0.9 && p < 0.95;
  }

  void _face(Canvas c) {
    final cheeks = Paint()..color = _blush.withValues(alpha: pose == PeboPose.angry ? 0 : 0.42);
    c.drawOval(Rect.fromCenter(center: const Offset(30, 66), width: 11, height: 6.5), cheeks);
    c.drawOval(Rect.fromCenter(center: const Offset(70, 66), width: 11, height: 6.5), cheeks);

    switch (pose) {
      case PeboPose.laugh:
        _arcEye(c, const Offset(39, 55), up: true);
        _arcEye(c, const Offset(61, 55), up: true);
        _mouthOpen(c, const Offset(50, 69), 14, 10 + 2 * math.sin(_w * 4).abs());
        // happy tears flying off
        final p = (t * 2) % 1;
        for (final side in [-1.0, 1.0]) {
          final o = Offset(50 + side * (17 + 10 * p), 55 - 8 * math.sin(p * math.pi));
          _drop(c, o, 3.2 * (1 - p * 0.5), alpha: 1 - p);
        }
      case PeboPose.cry:
        _arcEye(c, const Offset(39, 56), up: false);
        _arcEye(c, const Offset(61, 56), up: false);
        _brows(c, sad: true);
        _mouthWobble(c);
        for (final x in [37.0, 63.0]) {
          for (var k = 0; k < 2; k++) {
            final p = ((t * 2) + k * 0.5) % 1;
            _drop(c, Offset(x + (x < 50 ? -1 : 1) * 2 * p, 60 + 26 * p), 2.8, alpha: 1 - p);
          }
        }
      case PeboPose.angry:
        _eyes(c, look: Offset.zero, scaleY: 0.75);
        _brows(c, angry: true);
        _mouthFlat(c, frown: true);
      case PeboPose.cool:
        _mouthSmile(c, wide: 0.8, smirk: true);
        _sunglasses(c);
      case PeboPose.sleep:
        _arcEye(c, const Offset(39, 56), up: false, flat: true);
        _arcEye(c, const Offset(61, 56), up: false, flat: true);
        final o = 1.5 + 1.2 * math.sin(_w);
        c.drawOval(Rect.fromCenter(center: const Offset(50, 69), width: 5, height: o * 2), Paint()..color = _ink);
      case PeboPose.think:
        _eyes(c, look: const Offset(2.4, -2.6));
        _mouthFlat(c, side: true);
      case PeboPose.wow:
        _eyes(c, look: Offset.zero, big: true);
        c.drawOval(Rect.fromCenter(center: const Offset(50, 71), width: 9, height: 11), Paint()..color = _ink);
        c.drawOval(Rect.fromCenter(center: const Offset(50, 73.5), width: 5, height: 4), Paint()..color = const Color(0xFFFF6F8E));
      case PeboPose.love:
        final beat = 1 + 0.18 * math.max(0, math.sin(_w * 3));
        _heart(c, const Offset(39, 55), 7.5 * beat, const Color(0xFFFF3D6E));
        _heart(c, const Offset(61, 55), 7.5 * beat, const Color(0xFFFF3D6E));
        _mouthSmile(c, wide: 1, open: true);
      case PeboPose.kiss:
        _arcEye(c, const Offset(39, 55), up: true);
        _winkOrEye(c, const Offset(61, 55));
        _kissMouth(c);
      case PeboPose.thumbsUp:
        _eyes(c, look: Offset.zero, winkRight: true);
        _mouthSmile(c, wide: 1, open: true);
      case PeboPose.facepalm:
        _arcEye(c, const Offset(61, 56), up: false, flat: true);
        _mouthFlat(c, frown: true);
      case PeboPose.party:
      case PeboPose.gift:
        _arcEye(c, const Offset(39, 55), up: true);
        _arcEye(c, const Offset(61, 55), up: true);
        _mouthOpen(c, const Offset(50, 69), 12, 9);
      case PeboPose.run:
        _eyes(c, look: const Offset(2.5, 0));
        _mouthOpen(c, const Offset(53, 70), 8, 6);
        _drop(c, Offset(22 - 3 * ((t * 3) % 1), 42 + 6 * ((t * 3) % 1)), 2.6, alpha: 1 - ((t * 3) % 1)); // sweat
      case PeboPose.ok:
        _arcEye(c, const Offset(39, 55), up: true);
        _arcEye(c, const Offset(61, 55), up: true);
        _mouthSmile(c, wide: 1);
      case PeboPose.hi:
        _eyes(c, look: Offset(1.2 * math.sin(_w), 0));
        _mouthSmile(c, wide: 1, open: true);
    }
  }

  void _eyes(Canvas c, {Offset look = Offset.zero, bool big = false, double scaleY = 1, bool winkRight = false}) {
    final blink = _blinkNow && !big;
    for (final x in [39.0, 61.0]) {
      if ((blink) || (winkRight && x > 50)) {
        _arcEye(c, Offset(x, 56), up: true);
        continue;
      }
      final w = big ? 17.0 : 13.0, h = (big ? 19.0 : 15.0) * scaleY;
      final eye = Rect.fromCenter(center: Offset(x, 55), width: w, height: h);
      c.drawOval(eye, Paint()..color = Colors.white);
      c.drawOval(eye, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = _line.withValues(alpha: 0.6));
      final pr = big ? 4.2 : 4.6;
      final pc = Offset(x, 56) + look;
      c.drawCircle(pc, pr, Paint()..color = _ink);
      c.drawCircle(pc + const Offset(-1.6, -1.8), pr * 0.38, Paint()..color = Colors.white);
      c.drawCircle(pc + const Offset(1.6, 1.6), pr * 0.18, Paint()..color = Colors.white.withValues(alpha: 0.8));
    }
  }

  void _winkOrEye(Canvas c, Offset o) {
    final p = (t * 2) % 1;
    if (p < 0.5) {
      _arcEye(c, o, up: true);
    } else {
      final eye = Rect.fromCenter(center: o, width: 13, height: 15);
      c.drawOval(eye, Paint()..color = Colors.white);
      c.drawCircle(o + const Offset(0, 1), 4.6, Paint()..color = _ink);
      c.drawCircle(o + const Offset(-1.6, -0.8), 1.7, Paint()..color = Colors.white);
    }
  }

  void _arcEye(Canvas c, Offset o, {required bool up, bool flat = false}) {
    final p = Path();
    if (flat) {
      p
        ..moveTo(o.dx - 6, o.dy)
        ..quadraticBezierTo(o.dx, o.dy + 3, o.dx + 6, o.dy);
    } else if (up) {
      p
        ..moveTo(o.dx - 6, o.dy + 2)
        ..quadraticBezierTo(o.dx, o.dy - 6, o.dx + 6, o.dy + 2);
    } else {
      p
        ..moveTo(o.dx - 6, o.dy - 2)
        ..quadraticBezierTo(o.dx, o.dy + 5, o.dx + 6, o.dy - 2);
    }
    c.drawPath(p, _stroke(2.8));
  }

  void _brows(Canvas c, {bool angry = false, bool sad = false}) {
    final paint = _stroke(2.6);
    if (angry) {
      c.drawLine(const Offset(32, 43), const Offset(44, 48), paint);
      c.drawLine(const Offset(68, 43), const Offset(56, 48), paint);
    } else if (sad) {
      c.drawLine(const Offset(33, 48), const Offset(44, 44), paint);
      c.drawLine(const Offset(67, 48), const Offset(56, 44), paint);
    }
  }

  void _mouthSmile(Canvas c, {double wide = 1, bool open = false, bool smirk = false}) {
    final w = 8 * wide;
    final p = Path()
      ..moveTo(50 - w, 67)
      ..quadraticBezierTo(50 + (smirk ? 2 : 0), 75 + (smirk ? -1 : 0), 50 + w + (smirk ? 2 : 0), 66 - (smirk ? 2 : 0));
    if (open) {
      final fill = Path()
        ..moveTo(50 - w, 67)
        ..quadraticBezierTo(50, 78, 50 + w, 67)
        ..close();
      c.drawPath(fill, Paint()..color = const Color(0xFF7A1F3D));
      c.save();
      c.clipPath(fill);
      c.drawCircle(const Offset(50, 76), 5, Paint()..color = const Color(0xFFFF6F8E));
      c.restore();
      c.drawPath(fill, _stroke(2.2));
    } else {
      c.drawPath(p, _stroke(2.6));
    }
  }

  void _mouthOpen(Canvas c, Offset o, double w, double h) {
    final r = Rect.fromCenter(center: o, width: w, height: h);
    final path = Path()
      ..moveTo(r.left, r.top)
      ..lineTo(r.right, r.top)
      ..quadraticBezierTo(r.right, r.bottom + 2, o.dx, r.bottom)
      ..quadraticBezierTo(r.left, r.bottom + 2, r.left, r.top)
      ..close();
    c.drawPath(path, Paint()..color = const Color(0xFF7A1F3D));
    c.save();
    c.clipPath(path);
    c.drawOval(Rect.fromCenter(center: Offset(o.dx, r.bottom), width: w * 0.7, height: h * 0.7), Paint()..color = const Color(0xFFFF6F8E));
    c.drawRect(Rect.fromLTWH(r.left, r.top, w, 2.2), Paint()..color = Colors.white);
    c.restore();
    c.drawPath(path, _stroke(2));
  }

  void _mouthFlat(Canvas c, {bool frown = false, bool side = false}) {
    final p = Path();
    if (side) {
      p
        ..moveTo(47, 70)
        ..quadraticBezierTo(52, 68, 57, 70);
    } else if (frown) {
      p
        ..moveTo(43, 72)
        ..quadraticBezierTo(50, 66, 57, 72);
    } else {
      p
        ..moveTo(44, 70)
        ..lineTo(56, 70);
    }
    c.drawPath(p, _stroke(2.6));
  }

  void _mouthWobble(Canvas c) {
    final p = Path()..moveTo(42, 72);
    for (var i = 1; i <= 4; i++) {
      p.lineTo(42 + i * 4, 72 + (i.isOdd ? -2.4 : 0) + 0.8 * math.sin(_w * 4 + i));
    }
    c.drawPath(p, _stroke(2.4));
  }

  void _kissMouth(Canvas c) {
    final p = Path()
      ..moveTo(50, 66)
      ..quadraticBezierTo(55, 68, 50, 70)
      ..quadraticBezierTo(55, 72, 50, 74);
    c.drawPath(p, _stroke(2.4));
  }

  void _sunglasses(Canvas c) {
    final frame = Paint()..color = const Color(0xFF111827);
    final l = RRect.fromRectAndRadius(const Rect.fromLTWH(28, 48, 19, 13), const Radius.circular(5));
    final r = RRect.fromRectAndRadius(const Rect.fromLTWH(53, 48, 19, 13), const Radius.circular(5));
    c.drawRRect(l, frame);
    c.drawRRect(r, frame);
    c.drawLine(const Offset(46, 52), const Offset(54, 52), _stroke(2.4, color: const Color(0xFF111827)));
    c.drawLine(const Offset(28, 51), const Offset(20, 48), _stroke(2.2, color: const Color(0xFF111827)));
    c.drawLine(const Offset(72, 51), const Offset(80, 48), _stroke(2.2, color: const Color(0xFF111827)));
    // a glint sweeping across the lenses
    final g = (t * 1.5) % 1.5;
    if (g < 1) {
      for (final lens in [l, r]) {
        c.save();
        c.clipRRect(lens);
        final x = lens.left - 8 + g * (lens.width + 16);
        c.drawLine(Offset(x, lens.bottom), Offset(x + 7, lens.top), _stroke(3, color: Colors.white.withValues(alpha: 0.7)));
        c.restore();
      }
    }
  }

  // ---------------------------------------------------------------- arms
  void _arm(Canvas c, Offset shoulder, double angle, {double len = 15, bool thumb = false, bool fist = false}) {
    c.save();
    c.translate(shoulder.dx, shoulder.dy);
    c.rotate(angle);
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(-4.5, -len, 9, len + 3), const Radius.circular(4.5));
    c.drawRRect(r, Paint()..color = const Color(0xFF52D6B8));
    c.drawRRect(r, _stroke(1.8, color: _line));
    if (thumb) {
      final th = RRect.fromRectAndRadius(Rect.fromLTWH(-2.4, -len - 7, 5, 9), const Radius.circular(2.5));
      c.drawRRect(th, Paint()..color = const Color(0xFF52D6B8));
      c.drawRRect(th, _stroke(1.6, color: _line));
    }
    if (fist) c.drawCircle(Offset(0, -len), 5.6, Paint()..color = const Color(0xFF52D6B8));
    c.restore();
  }

  void _arms(Canvas c, {required bool back}) {
    if (back) return; // arms all sit in front of the body
    const lS = Offset(22, 70), rS = Offset(78, 70);
    switch (pose) {
      case PeboPose.hi:
        _arm(c, lS, -2.2);
        _arm(c, rS, 0.5 + 0.45 * math.sin(_w * 3), len: 17);
      case PeboPose.thumbsUp:
        _arm(c, lS, -2.3);
        final up = (t * 2) % 1 < 0.15 ? 0.15 * math.sin(((t * 2) % 1) / 0.15 * math.pi) : 0.0;
        _arm(c, rS, 0.35 - up, len: 16, thumb: true);
      case PeboPose.party:
      case PeboPose.gift:
        _arm(c, lS, -0.55 + 0.15 * math.sin(_w * 2), len: 16);
        _arm(c, rS, 0.55 - 0.15 * math.sin(_w * 2), len: 16);
      case PeboPose.think:
        _arm(c, lS, -2.3);
        _arm(c, const Offset(60, 80), -0.25, len: 9, fist: true);
      case PeboPose.facepalm:
        _arm(c, lS, -2.3);
        _arm(c, const Offset(66, 76), -0.85, len: 21);
        c.drawOval(Rect.fromCenter(center: const Offset(42, 56), width: 18, height: 14), Paint()..color = const Color(0xFF52D6B8));
        c.drawOval(Rect.fromCenter(center: const Offset(42, 56), width: 18, height: 14), _stroke(1.8, color: _line));
      case PeboPose.wow:
        _arm(c, lS, -0.4, len: 15);
        _arm(c, rS, 0.4, len: 15);
      case PeboPose.angry:
        _arm(c, lS, -2.6 + 0.08 * math.sin(_w * 10), fist: true);
        _arm(c, rS, 2.6 - 0.08 * math.sin(_w * 10), fist: true);
      case PeboPose.run:
        _arm(c, lS, -1.6 + 0.9 * math.sin(_w * 6));
        _arm(c, rS, 1.6 + 0.9 * math.sin(_w * 6 + math.pi));
      case PeboPose.kiss:
        _arm(c, lS, -2.3);
        _arm(c, rS, -0.9 + 0.2 * math.sin(_w * 2), len: 13);
      default:
        _arm(c, lS, -2.25 + 0.06 * math.sin(_w));
        _arm(c, rS, 2.25 - 0.06 * math.sin(_w));
    }
  }

  // ---------------------------------------------------------------- props on the body
  void _props(Canvas c) {
    switch (pose) {
      case PeboPose.party:
        // party hat
        final hat = Path()
          ..moveTo(38, 33)
          ..lineTo(56, 9)
          ..lineTo(66, 36)
          ..close();
        c.drawPath(hat, Paint()..shader = const LinearGradient(colors: [Color(0xFF8E54E9), Color(0xFFFF5E8A)]).createShader(const Rect.fromLTWH(38, 9, 28, 27)));
        c.drawPath(hat, _stroke(1.6, color: const Color(0xFF5B2BA8)));
        for (var i = 0; i < 3; i++) {
          c.drawCircle(Offset(46 + i * 6.0, 28 - i * 6.5), 1.8, Paint()..color = const Color(0xFFFFC94D));
        }
        c.drawCircle(const Offset(56, 9), 3.4, Paint()..color = const Color(0xFFFFC94D));
      case PeboPose.gift:
        final bob = 2 * math.sin(_w * 2);
        final box = Rect.fromLTWH(36, 70 + bob, 28, 20);
        c.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)), Paint()..color = const Color(0xFFFF5E8A));
        c.drawRect(Rect.fromLTWH(box.left - 2, box.top - 5, box.width + 4, 7), Paint()..color = const Color(0xFFFF3D6E));
        c.drawRect(Rect.fromLTWH(box.center.dx - 2.5, box.top - 5, 5, box.height + 5), Paint()..color = const Color(0xFFFFC94D));
        final bow = Path()
          ..moveTo(50, box.top - 5)
          ..quadraticBezierTo(41, box.top - 15, 44, box.top - 5)
          ..moveTo(50, box.top - 5)
          ..quadraticBezierTo(59, box.top - 15, 56, box.top - 5);
        c.drawPath(bow, _stroke(2.6, color: const Color(0xFFFFC94D)));
      case PeboPose.sleep:
        // nightcap
        final cap = Path()
          ..moveTo(30, 38)
          ..quadraticBezierTo(48, 18, 70, 36)
          ..quadraticBezierTo(80, 30, 84, 44)
          ..quadraticBezierTo(70, 26, 30, 38);
        c.drawPath(cap, Paint()..color = const Color(0xFF6C7BF2));
        c.drawCircle(const Offset(84, 45), 3.6, Paint()..color = Colors.white);
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- effects behind / in front
  void _behind(Canvas c) {
    if (pose == PeboPose.ok || pose == PeboPose.cool) {
      for (var i = 0; i < 3; i++) {
        final p = ((t * 1.5) + i / 3) % 1;
        final a = math.sin(p * math.pi);
        _sparkle(c, [const Offset(16, 30), const Offset(86, 26), const Offset(88, 64)][i], 5 * a, const Color(0xFFFFC94D).withValues(alpha: a));
      }
    }
  }

  void _front(Canvas c) {
    switch (pose) {
      case PeboPose.love:
        for (var i = 0; i < 3; i++) {
          final p = ((t * 1.2) + i / 3) % 1;
          final x = [20.0, 82.0, 70.0][i] + 4 * math.sin(p * 6 + i);
          _heart(c, Offset(x, 40 - 32 * p), 5 + 2.0 * i, const Color(0xFFFF3D6E).withValues(alpha: 1 - p));
        }
      case PeboPose.kiss:
        final p = (t * 2) % 1;
        _heart(c, Offset(62 + 26 * p, 66 - 34 * p), 4 + 6 * p, const Color(0xFFFF3D6E).withValues(alpha: 1 - p * 0.8));
      case PeboPose.sleep:
        for (var i = 0; i < 3; i++) {
          final p = ((t) + i / 3) % 1;
          final tp = TextPainter(
            text: TextSpan(text: 'z', style: TextStyle(fontSize: 8 + 6 * p, fontWeight: FontWeight.w900, color: const Color(0xFF6C7BF2).withValues(alpha: 1 - p))),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(c, Offset(68 + 16 * p, 34 - 26 * p));
        }
      case PeboPose.think:
        final bob = 2 * math.sin(_w * 2);
        final tp = TextPainter(
          text: const TextSpan(text: '?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF6C4BE0))),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(c, Offset(74, 8 + bob));
        for (var i = 0; i < 2; i++) {
          c.drawCircle(Offset(72 - i * 5.0, 32 + i * 4.0), 2.2 - i * 0.6, Paint()..color = const Color(0xFF6C4BE0).withValues(alpha: 0.6));
        }
      case PeboPose.angry:
        for (final side in [-1.0, 1.0]) {
          final p = (t * 2) % 1;
          final o = Offset(50 + side * (30 + 6 * p), 30 - 12 * p);
          c.drawCircle(o, 4 + 4 * p, Paint()..color = Colors.white.withValues(alpha: 0.85 * (1 - p)));
          c.drawCircle(o + Offset(side * 4, -3), 3 + 3 * p, Paint()..color = Colors.white.withValues(alpha: 0.7 * (1 - p)));
        }
      case PeboPose.party:
        final rnd = math.Random(7);
        const colors = [Color(0xFFFF5E8A), Color(0xFFFFC94D), Color(0xFF8E54E9), Color(0xFF3CC8FF), Color(0xFF2ED47A)];
        for (var i = 0; i < 14; i++) {
          final x0 = rnd.nextDouble() * 100;
          final speed = 0.6 + rnd.nextDouble() * 0.6;
          final p = ((t * speed) + rnd.nextDouble()) % 1;
          final y = -6 + 108 * p;
          final x = x0 + 4 * math.sin(p * 8 + i);
          c.save();
          c.translate(x, y);
          c.rotate(p * 9 + i);
          c.drawRect(const Rect.fromLTWH(-2, -1, 4, 2.4), Paint()..color = colors[i % colors.length]);
          c.restore();
        }
      case PeboPose.gift:
        for (var i = 0; i < 3; i++) {
          final p = ((t * 1.6) + i / 3) % 1;
          final a = math.sin(p * math.pi);
          _sparkle(c, [const Offset(30, 64), const Offset(72, 62), const Offset(50, 52)][i] + Offset(0, -10 * p), 4 * a, const Color(0xFFFFC94D).withValues(alpha: a));
        }
      case PeboPose.run:
        for (var i = 0; i < 3; i++) {
          final p = ((t * 3) + i / 3) % 1;
          c.drawLine(Offset(10 - 6 * p, 52 + i * 10.0), Offset(18 - 6 * p, 52 + i * 10.0), _stroke(2, color: _line.withValues(alpha: 0.5 * (1 - p))));
        }
        for (var i = 0; i < 2; i++) {
          final p = ((t * 3) + i / 2) % 1;
          c.drawCircle(Offset(26 - 20 * p, 88 - 4 * p), 3 + 3 * p, Paint()..color = Colors.grey.withValues(alpha: 0.35 * (1 - p)));
        }
      case PeboPose.wow:
        final p = (t * 2) % 1;
        if (p < 0.5) {
          for (var k = 0; k < 3; k++) {
            final a = -math.pi / 2 + (k - 1) * 0.5;
            final d = 6 * p;
            final from = Offset(50 + math.cos(a) * (36 + d), 26 + math.sin(a) * (8 + d));
            c.drawLine(from, from + Offset(math.cos(a), math.sin(a)) * 6, _stroke(2.4, color: const Color(0xFFFFB020).withValues(alpha: 1 - p * 2)));
          }
        }
        _drop(c, const Offset(78, 44), 3, alpha: 0.9);
      case PeboPose.facepalm:
        final p = (t * 1.5) % 1;
        c.drawLine(Offset(74, 34 + 6 * p), Offset(74, 40 + 6 * p), _stroke(2, color: _line.withValues(alpha: 1 - p)));
        c.drawLine(Offset(79, 33 + 6 * p), Offset(79, 41 + 6 * p), _stroke(2, color: _line.withValues(alpha: 1 - p)));
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- helpers
  Paint _stroke(double w, {Color color = _ink}) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = color;

  void _drop(Canvas c, Offset o, double r, {double alpha = 1}) {
    final p = Path()
      ..moveTo(o.dx, o.dy - r * 1.6)
      ..quadraticBezierTo(o.dx + r * 1.1, o.dy - r * 0.2, o.dx, o.dy + r)
      ..quadraticBezierTo(o.dx - r * 1.1, o.dy - r * 0.2, o.dx, o.dy - r * 1.6);
    c.drawPath(p, Paint()..color = const Color(0xFF5CC8FF).withValues(alpha: alpha.clamp(0.0, 1.0)));
  }

  void _heart(Canvas c, Offset o, double s, Color color) {
    final p = Path()
      ..moveTo(o.dx, o.dy + s * 0.75)
      ..cubicTo(o.dx - s * 1.3, o.dy - s * 0.1, o.dx - s * 0.6, o.dy - s * 1.0, o.dx, o.dy - s * 0.35)
      ..cubicTo(o.dx + s * 0.6, o.dy - s * 1.0, o.dx + s * 1.3, o.dy - s * 0.1, o.dx, o.dy + s * 0.75)
      ..close();
    c.drawPath(p, Paint()..color = color);
    c.drawCircle(o + Offset(-s * 0.4, -s * 0.35), s * 0.16, Paint()..color = Colors.white.withValues(alpha: 0.7 * color.a));
  }

  void _sparkle(Canvas c, Offset o, double r, Color color) {
    if (r <= 0.2) return;
    final p = Path()
      ..moveTo(o.dx, o.dy - r)
      ..quadraticBezierTo(o.dx, o.dy, o.dx + r, o.dy)
      ..quadraticBezierTo(o.dx, o.dy, o.dx, o.dy + r)
      ..quadraticBezierTo(o.dx, o.dy, o.dx - r, o.dy)
      ..quadraticBezierTo(o.dx, o.dy, o.dx, o.dy - r);
    c.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PeboPainter old) => old.t != t || old.pose != pose;
}
