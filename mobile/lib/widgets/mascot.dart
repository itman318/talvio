import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Tavi — Talvio's own mascot: a round, fluffy little night-bird in the app's aurora colours.
/// Drawn in code (sharp at any size, tiny download) and animated: blinks, breathes, waves,
/// hides its eyes on password screens, searches with a magnifier, sleeps, celebrates…
enum TaviPose {
  idle,
  wave, // hello / empty chats
  search, // nothing found / no contacts
  hideEyes, // password screens (wings over the eyes)
  peek, // password shown: one wing lowered
  celebrate, // success, Talvio Plus
  sleep, // nothing new, no calls
  mail, // check your email for the code
  sad, // error / offline
  love, // hearts
  think, // bots / setting things up
  cool, // sunglasses
  laugh, // laughing with happy tears
  thumbsUp, // "great!"
  coffee, // good morning / a break
  angry, // grumpy, steam puffs
  shocked, // wide eyes, "!"
  music, // headphones, swaying
}

/// Tavi stickers people can send. The second half are Talvio Plus only.
const taviStickers = <(TaviPose, String, bool)>[
  (TaviPose.wave, '👋', false),
  (TaviPose.love, '❤️', false),
  (TaviPose.sleep, '😴', false),
  (TaviPose.think, '🤔', false),
  (TaviPose.celebrate, '🎉', true),
  (TaviPose.hideEyes, '🙈', true),
  (TaviPose.search, '🔍', true),
  (TaviPose.mail, '✉️', true),
  (TaviPose.sad, '😢', true),
  (TaviPose.cool, '😎', true),
  (TaviPose.laugh, '😂', false),
  (TaviPose.thumbsUp, '👍', false),
  (TaviPose.coffee, '☕', false),
  (TaviPose.angry, '😠', true),
  (TaviPose.shocked, '😮', true),
  (TaviPose.music, '🎧', true),
];

TaviPose? taviPoseByName(String? name) {
  for (final p in TaviPose.values) {
    if (p.name == name) return p;
  }
  return null;
}

class TaviMascot extends StatefulWidget {
  const TaviMascot({super.key, this.pose = TaviPose.idle, this.size = 140, this.animate = true});
  final TaviPose pose;
  final double size;
  final bool animate;

  @override
  State<TaviMascot> createState() => _TaviMascotState();
}

class _TaviMascotState extends State<TaviMascot> with TickerProviderStateMixin {
  late final AnimationController _loop; // endless motion (breathing, waving, floating things)
  late final AnimationController _blend; // smooth change between poses (wings move into place)
  TaviPose _from = TaviPose.idle;

  @override
  void initState() {
    super.initState();
    _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
    _blend = AnimationController(vsync: this, duration: const Duration(milliseconds: 420), value: 1);
    _from = widget.pose;
    if (widget.animate) _loop.repeat();
  }

  @override
  void didUpdateWidget(TaviMascot old) {
    super.didUpdateWidget(old);
    if (old.pose != widget.pose) {
      _from = old.pose;
      _blend.forward(from: 0);
    }
    if (widget.animate && !_loop.isAnimating) _loop.repeat();
    if (!widget.animate && _loop.isAnimating) _loop.stop();
  }

  @override
  void dispose() {
    _loop.dispose();
    _blend.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: Listenable.merge([_loop, _blend]),
          builder: (_, __) => CustomPaint(
            painter: _TaviPainter(
              pose: widget.pose,
              from: _from,
              blend: Curves.easeOutBack.transform(_blend.value).clamp(0.0, 1.1),
              t: _loop.value,
            ),
          ),
        ),
      ),
    );
  }
}

/// Wing placement for a pose: angle (radians, 0 = hanging down) and where the wing tip sits.
class _Wings {
  const _Wings(this.leftAngle, this.rightAngle, {this.leftLift = 0, this.rightLift = 0, this.leftIn = 0, this.rightIn = 0, this.leftScale = 1, this.rightScale = 1});
  final double leftAngle;
  final double rightAngle;
  final double leftLift; // move up (units)
  final double rightLift;
  final double leftIn; // move toward the middle (units)
  final double rightIn;
  final double leftScale; // bigger wings when they cover the eyes
  final double rightScale;

  static _Wings lerp(_Wings a, _Wings b, double t) => _Wings(
        a.leftAngle + (b.leftAngle - a.leftAngle) * t,
        a.rightAngle + (b.rightAngle - a.rightAngle) * t,
        leftLift: a.leftLift + (b.leftLift - a.leftLift) * t,
        rightLift: a.rightLift + (b.rightLift - a.rightLift) * t,
        leftIn: a.leftIn + (b.leftIn - a.leftIn) * t,
        rightIn: a.rightIn + (b.rightIn - a.rightIn) * t,
        leftScale: a.leftScale + (b.leftScale - a.leftScale) * t,
        rightScale: a.rightScale + (b.rightScale - a.rightScale) * t,
      );
}

class _TaviPainter extends CustomPainter {
  _TaviPainter({required this.pose, required this.from, required this.blend, required this.t});
  final TaviPose pose;
  final TaviPose from;
  final double blend;
  final double t;

  // palette
  static const _bodyLight = Color(0xFFFFB08A);
  static const _bodyMid = Color(0xFFF2557E);
  static const _bodyDark = Color(0xFF7B4FE0);
  static const _wingA = Color(0xFFB65BE8);
  static const _wingB = Color(0xFF5B3FC8);
  static const _belly = Color(0xFFFFF4EA);
  static const _bellyShade = Color(0xFFFBDCCB);
  static const _disc = Color(0xFFFFE6EE);
  static const _ink = Color(0xFF1C1836);
  static const _beak = Color(0xFFFFB534);
  static const _beakDark = Color(0xFFF08A1C);

  double get _wave => math.sin(t * 2 * math.pi);

  _Wings _wingsFor(TaviPose p) {
    final w = _wave;
    switch (p) {
      case TaviPose.wave:
        return _Wings(0.15, -2.3 + 0.35 * math.sin(t * 4 * math.pi), rightLift: 10);
      case TaviPose.hideEyes:
        // wings folded over the eyes (a tiny nervous shiver)
        final s = 0.03 * math.sin(t * 8 * math.pi);
        return _Wings(-2.3 + s, 2.3 - s, leftLift: 5, rightLift: 5, leftIn: 2, rightIn: 2, leftScale: 1.3, rightScale: 1.3);
      case TaviPose.peek:
        return _Wings(-2.3, 1.0 + 0.08 * math.sin(t * 2 * math.pi), leftLift: 5, rightLift: 4, leftIn: 2, rightIn: 1, leftScale: 1.3);
      case TaviPose.celebrate:
        return _Wings(-2.5 - 0.25 * w, 2.5 + 0.25 * w, leftLift: 12, rightLift: 12);
      case TaviPose.search:
        return _Wings(0.15, -1.25, rightLift: 8, rightIn: 4);
      case TaviPose.mail:
        return const _Wings(-1.15, 1.15, leftLift: 6, rightLift: 6, leftIn: 8, rightIn: 8);
      case TaviPose.think:
        return _Wings(0.2, -2.0, rightLift: 16, rightIn: 9);
      case TaviPose.love:
        return const _Wings(-0.9, 0.9, leftLift: 4, rightLift: 4, leftIn: 7, rightIn: 7);
      case TaviPose.sad:
        return const _Wings(0.05, -0.05);
      case TaviPose.sleep:
        return const _Wings(0.25, -0.25, leftIn: 2, rightIn: 2);
      case TaviPose.cool:
        return _Wings(0.2, -1.6 + 0.15 * w, rightLift: 6);
      case TaviPose.laugh:
        // holding the belly while laughing
        final k = 0.12 * math.sin(t * 8 * math.pi);
        return _Wings(-0.95 + k, 0.95 - k, leftLift: 2, rightLift: 2, leftIn: 7, rightIn: 7);
      case TaviPose.thumbsUp:
        return _Wings(0.2, -2.55 + 0.08 * w, rightLift: 13, rightIn: 1);
      case TaviPose.coffee:
        return const _Wings(-1.1, 1.1, leftLift: 5, rightLift: 5, leftIn: 8, rightIn: 8);
      case TaviPose.angry:
        // wings on the hips
        return const _Wings(0.85, -0.85, leftLift: -2, rightLift: -2, leftIn: -1, rightIn: -1);
      case TaviPose.shocked:
        final k = 0.05 * math.sin(t * 10 * math.pi);
        return _Wings(-2.1 + k, 2.1 - k, leftLift: 9, rightLift: 9);
      case TaviPose.music:
        return _Wings(0.25 + 0.15 * w, -0.25 + 0.15 * w);
      case TaviPose.idle:
        return _Wings(0.2 + 0.06 * w, -0.2 - 0.06 * w);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 100; // all drawing in a 100×100 box
    canvas.save();
    canvas.scale(u);

    // body motion
    double bob = 1.6 * _wave;
    double tilt = 0;
    double squash = 1;
    switch (pose) {
      case TaviPose.celebrate:
        final j = (math.sin(t * 4 * math.pi)).abs();
        bob = -7 * j;
        squash = 1 + 0.05 * (1 - j);
      case TaviPose.sleep:
        bob = 1.0 * math.sin(t * 2 * math.pi);
        tilt = 0.07;
      case TaviPose.sad:
        bob = 0.6 * _wave;
        tilt = -0.04;
      case TaviPose.search:
        tilt = 0.05 * math.sin(t * 2 * math.pi);
      case TaviPose.love:
        tilt = 0.06 * math.sin(t * 2 * math.pi);
      case TaviPose.laugh:
        final j = math.sin(t * 8 * math.pi);
        tilt = 0.05 * j;
        bob = -1.6 * j.abs();
      case TaviPose.angry:
        tilt = 0.015 * math.sin(t * 16 * math.pi);
      case TaviPose.shocked:
        final j = math.max(0.0, math.sin(t * 2 * math.pi));
        bob = -4 * j;
        squash = 1 + 0.04 * j;
      case TaviPose.music:
        tilt = 0.1 * math.sin(t * 2 * math.pi);
        bob = 1.2 * math.sin(t * 4 * math.pi);
      case TaviPose.thumbsUp:
        bob = -1.2 * math.sin(t * 2 * math.pi).abs();
      default:
        break;
    }

    _shadow(canvas, bob);
    canvas.save();
    canvas.translate(50, 92);
    canvas.rotate(tilt);
    canvas.scale(1 / squash, squash);
    canvas.translate(-50, -92 + bob);

    _feet(canvas);
    final wings = _Wings.lerp(_wingsFor(from), _wingsFor(pose), blend.clamp(0.0, 1.0));
    // back wing details are drawn after the body when they cover the face
    final wingsInFront = pose == TaviPose.hideEyes ||
        pose == TaviPose.peek ||
        pose == TaviPose.mail ||
        pose == TaviPose.love ||
        pose == TaviPose.think ||
        pose == TaviPose.coffee ||
        pose == TaviPose.laugh;
    if (!wingsInFront) _wingsPaint(canvas, wings);
    _body(canvas);
    _tuft(canvas);
    _face(canvas);
    if (pose == TaviPose.mail) _envelope(canvas);
    if (pose == TaviPose.love) _heldHeart(canvas);
    if (pose == TaviPose.coffee) _cup(canvas);
    if (pose == TaviPose.music) _headphones(canvas);
    if (wingsInFront) _wingsPaint(canvas, wings);
    if (pose == TaviPose.search) _magnifier(canvas);
    if (pose == TaviPose.cool) _sunglasses(canvas);
    canvas.restore();

    // things around Tavi
    switch (pose) {
      case TaviPose.sleep:
        _zzz(canvas);
      case TaviPose.celebrate:
        _confetti(canvas);
      case TaviPose.love:
        _floatingHearts(canvas);
      case TaviPose.sad:
        _rainCloud(canvas);
      case TaviPose.think:
        _gears(canvas);
      case TaviPose.wave:
        _sparkles(canvas, 3);
      case TaviPose.cool:
        _sparkles(canvas, 2);
      case TaviPose.thumbsUp:
        _badge(canvas);
        _sparkles(canvas, 3);
      case TaviPose.coffee:
        _steam(canvas, const Offset(50, 60), const Color(0xFFB9A79A));
      case TaviPose.angry:
        _steam(canvas, const Offset(26, 30), const Color(0xFFCBD1E2));
        _steam(canvas, const Offset(74, 30), const Color(0xFFCBD1E2));
        _angerMark(canvas);
      case TaviPose.shocked:
        _exclaim(canvas);
      case TaviPose.music:
        _notes(canvas);
      default:
        break;
    }
    canvas.restore();
  }

  // ------------------------------------------------------------------ body parts
  void _shadow(Canvas c, double bob) {
    final w = 44 - bob * 1.2;
    c.drawOval(
      Rect.fromCenter(center: const Offset(50, 95), width: w, height: 6),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
    );
  }

  void _feet(Canvas c) {
    final p = Paint()..shader = const LinearGradient(colors: [_beak, _beakDark], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(const Rect.fromLTWH(36, 86, 28, 8));
    for (final x in [42.0, 58.0]) {
      final r = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, 90.5), width: 10, height: 5.5), const Radius.circular(3));
      c.drawRRect(r, p);
    }
  }

  void _body(Canvas c) {
    const rect = Rect.fromLTWH(20, 26, 60, 66);
    final body = Path()
      // a soft egg shape: wider at the bottom
      ..moveTo(50, 26)
      ..cubicTo(70, 26, 81, 44, 81, 62)
      ..cubicTo(81, 80, 68, 92, 50, 92)
      ..cubicTo(32, 92, 19, 80, 19, 62)
      ..cubicTo(19, 44, 30, 26, 50, 26)
      ..close();
    c.drawShadow(body, Colors.black, 3, false);
    c.drawPath(
      body,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.45, -0.6),
          radius: 1.15,
          colors: [_bodyLight, _bodyMid, _bodyDark],
          stops: [0.0, 0.48, 1.0],
        ).createShader(rect),
    );
    // fluffy feather marks
    final feather = Paint()
      ..color = Colors.white.withValues(alpha: 0.13)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;
    for (final o in const [Offset(30, 46), Offset(70, 46), Offset(26, 58), Offset(74, 58), Offset(34, 38), Offset(66, 38)]) {
      c.drawArc(Rect.fromCenter(center: o, width: 6, height: 4), 0.3, 2.4, false, feather);
    }
    // belly
    final belly = Path()..addOval(Rect.fromCenter(center: const Offset(50, 72), width: 38, height: 34));
    c.drawPath(
      belly,
      Paint()..shader = const RadialGradient(center: Alignment(0, -0.5), radius: 0.9, colors: [_belly, _bellyShade]).createShader(const Rect.fromLTWH(31, 55, 38, 34)),
    );
    final bellyMark = Paint()
      ..color = _bellyShade
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (final o in const [Offset(44, 68), Offset(56, 68), Offset(50, 75), Offset(44, 81), Offset(56, 81)]) {
      c.drawArc(Rect.fromCenter(center: o, width: 5, height: 3.4), 0.4, 2.3, false, bellyMark);
    }
    // gloss highlight
    c.drawOval(
      Rect.fromCenter(center: const Offset(36, 36), width: 14, height: 8),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.32)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4),
    );
  }

  void _tuft(Canvas c) {
    final sway = 0.12 * math.sin(t * 2 * math.pi + 0.8);
    final p = Paint()..shader = const LinearGradient(colors: [_bodyLight, _bodyMid], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(const Rect.fromLTWH(40, 14, 20, 16));
    for (final (x, dir) in [(46.0, -1.0), (54.0, 1.0)]) {
      c.save();
      c.translate(x, 28);
      c.rotate(dir * 0.35 + sway);
      final f = Path()
        ..moveTo(0, 0)
        ..quadraticBezierTo(-4, -8, dir * 1.5, -13)
        ..quadraticBezierTo(4, -7, 0, 0)
        ..close();
      c.drawPath(f, p);
      c.restore();
    }
  }

  bool get _eyesClosed {
    if (pose == TaviPose.sleep) return true;
    if (pose == TaviPose.music) return math.sin(t * 2 * math.pi) > -0.3; // enjoying the song
    if (pose == TaviPose.shocked) return false;
    if (pose == TaviPose.celebrate) return false;
    // blink about once per loop
    return t > 0.46 && t < 0.5;
  }

  void _face(Canvas c) {
    // facial discs (owl-like)
    final disc = Paint()..shader = const RadialGradient(colors: [_disc, Color(0xFFFFC9D9)], stops: [0.6, 1]).createShader(const Rect.fromLTWH(26, 34, 48, 28));
    c.drawOval(Rect.fromCenter(center: const Offset(39.5, 48), width: 22, height: 21), disc);
    c.drawOval(Rect.fromCenter(center: const Offset(60.5, 48), width: 22, height: 21), disc);

    // where the eyes look
    var look = Offset.zero;
    switch (pose) {
      case TaviPose.search:
        look = Offset(2.2 * math.sin(t * 2 * math.pi), 0.6);
      case TaviPose.sad:
        look = const Offset(0, 1.6);
      case TaviPose.think:
        look = const Offset(1.8, -1.8);
      case TaviPose.peek:
        look = const Offset(1.4, 0.4);
      case TaviPose.mail:
        look = const Offset(0, 1.2);
      default:
        look = Offset(0.6 * math.sin(t * 2 * math.pi * 0.5), 0);
    }

    if (pose == TaviPose.celebrate || pose == TaviPose.love || pose == TaviPose.laugh || pose == TaviPose.thumbsUp) {
      // happy closed "^ ^" eyes
      final p = Paint()
        ..color = _ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round;
      for (final x in [39.5, 60.5]) {
        final path = Path()
          ..moveTo(x - 5, 50)
          ..quadraticBezierTo(x, 43.5, x + 5, 50);
        c.drawPath(path, p);
      }
    } else {
      for (final x in [39.5, 60.5]) {
        _eye(c, Offset(x, 48), look, big: pose == TaviPose.shocked);
      }
    }
    if (pose == TaviPose.laugh) {
      // happy tears
      for (final (x, d) in [(32.0, -1.0), (68.0, 1.0)]) {
        final p = (t * 2) % 1;
        c.drawOval(Rect.fromCenter(center: Offset(x + d * p * 3, 51 + p * 9), width: 3.2, height: 4.4),
            Paint()..color = const Color(0xFF5AB3F5).withValues(alpha: 0.9 * (1 - p)));
      }
    }
    if (pose == TaviPose.angry) {
      // angry brows: down toward the beak
      final p = Paint()
        ..color = _ink
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round;
      c.drawLine(const Offset(32, 38), const Offset(45, 42.5), p);
      c.drawLine(const Offset(68, 38), const Offset(55, 42.5), p);
    }

    // sad brows
    if (pose == TaviPose.sad) {
      final p = Paint()
        ..color = _ink.withValues(alpha: 0.8)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      c.drawLine(const Offset(34, 38.5), const Offset(43, 36.5), p);
      c.drawLine(const Offset(66, 38.5), const Offset(57, 36.5), p);
    }

    // cheeks
    final blush = Paint()
      ..color = (pose == TaviPose.angry ? const Color(0xFFFF3B3B) : const Color(0xFFFF6F91)).withValues(alpha: pose == TaviPose.love || pose == TaviPose.angry ? 0.55 : 0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6);
    c.drawOval(Rect.fromCenter(center: const Offset(31, 58), width: 8, height: 5), blush);
    c.drawOval(Rect.fromCenter(center: const Offset(69, 58), width: 8, height: 5), blush);

    // beak (opens a little when celebrating / waving)
    final open = switch (pose) {
      TaviPose.celebrate || TaviPose.wave => 1.6 + 0.8 * _wave.abs(),
      TaviPose.laugh => 3.0 + 1.2 * math.sin(t * 8 * math.pi).abs(),
      TaviPose.shocked => 3.4,
      TaviPose.music => 1.0 + 1.0 * math.sin(t * 4 * math.pi).abs(),
      _ => 0.0,
    };
    final top = Path()
      ..moveTo(45.5, 55)
      ..quadraticBezierTo(50, 52.5, 54.5, 55)
      ..quadraticBezierTo(52, 59.5, 50, 61 - open * 0.3)
      ..quadraticBezierTo(48, 59.5, 45.5, 55)
      ..close();
    c.drawPath(top, Paint()..shader = const LinearGradient(colors: [_beak, _beakDark], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(const Rect.fromLTWH(45, 52, 10, 10)));
    if (open > 0) {
      c.drawOval(Rect.fromCenter(center: Offset(50, 60 + open * 0.4), width: 4.4, height: open * 1.3), Paint()..color = const Color(0xFFB0233F));
    }
    c.drawCircle(const Offset(48.5, 55.2), 0.7, Paint()..color = Colors.white.withValues(alpha: 0.7));
  }

  void _eye(Canvas c, Offset center, Offset look, {bool big = false}) {
    if (_eyesClosed) {
      final p = Paint()
        ..color = _ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round;
      final path = Path()
        ..moveTo(center.dx - 5, center.dy)
        ..quadraticBezierTo(center.dx, center.dy + 4, center.dx + 5, center.dy);
      c.drawPath(path, p);
      return;
    }
    // white
    c.drawOval(Rect.fromCenter(center: center, width: big ? 18 : 15, height: big ? 19 : 16), Paint()..color = Colors.white);
    if (big) {
      // tiny surprised pupils
      final iris = center + look;
      c.drawCircle(iris, 3.6, Paint()..color = _ink);
      c.drawCircle(iris + const Offset(-1.2, -1.3), 1.2, Paint()..color = Colors.white);
      return;
    }
    // iris with a warm ring
    final iris = center + look;
    c.drawCircle(iris, 6.2, Paint()..shader = const RadialGradient(colors: [Color(0xFF3A2F7A), _ink], stops: [0.3, 1]).createShader(Rect.fromCircle(center: iris, radius: 6.2)));
    c.drawCircle(iris, 6.2, Paint()
      ..color = const Color(0xFFFFB534).withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9);
    c.drawCircle(iris, 3, Paint()..color = Colors.black);
    // catch-lights: what makes it look alive
    c.drawCircle(iris + const Offset(-2.2, -2.4), 1.9, Paint()..color = Colors.white);
    c.drawCircle(iris + const Offset(2.1, 2.0), 0.9, Paint()..color = Colors.white.withValues(alpha: 0.85));
  }

  void _wingsPaint(Canvas c, _Wings w) {
    _wing(c, Offset(23 + w.leftIn, 63 - w.leftLift), w.leftAngle, false, w.leftScale);
    _wing(c, Offset(77 - w.rightIn, 63 - w.rightLift), w.rightAngle, true, w.rightScale);
  }

  void _wing(Canvas c, Offset shoulder, double angle, bool right, [double scale = 1]) {
    c.save();
    c.translate(shoulder.dx, shoulder.dy);
    c.rotate(angle);
    c.scale(scale);
    final d = right ? 1.0 : -1.0;
    final path = Path()
      ..moveTo(0, -6)
      ..cubicTo(d * 8, -6, d * 9, 8, d * 4, 18)
      ..cubicTo(d * 2, 21, d * -2, 20, d * -3, 16)
      ..cubicTo(d * -5, 8, d * -5, -5, 0, -6)
      ..close();
    c.drawShadow(path, Colors.black, 1.6, false);
    c.drawPath(
      path,
      Paint()..shader = LinearGradient(colors: const [_wingA, _wingB], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(const Rect.fromLTWH(-10, -6, 20, 26)),
    );
    // feather lines
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..strokeCap = StrokeCap.round;
    for (final y in [6.0, 10.5, 15.0]) {
      c.drawLine(Offset(d * -1.5, y), Offset(d * 3.5, y - 2.5), p);
    }
    c.restore();
  }

  // ------------------------------------------------------------------ props
  void _magnifier(Canvas c) {
    final sweep = 5 * math.sin(t * 2 * math.pi);
    final center = Offset(72 + sweep * 0.4, 44 + sweep * 0.2);
    final handle = Paint()
      ..shader = const LinearGradient(colors: [Color(0xFF8A5A2B), Color(0xFF5A3714)]).createShader(Rect.fromCircle(center: center, radius: 16))
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    c.drawLine(center + const Offset(6.5, 6.5), center + const Offset(14, 14), handle);
    c.drawCircle(center, 9, Paint()..color = const Color(0xFFBFE8FF).withValues(alpha: 0.45));
    c.drawCircle(center + const Offset(-3, -3), 3, Paint()..color = Colors.white.withValues(alpha: 0.65));
    c.drawCircle(center, 9, Paint()
      ..shader = const LinearGradient(colors: [Color(0xFFE2E8F5), Color(0xFF8C97B5)]).createShader(Rect.fromCircle(center: center, radius: 10))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6);
  }

  void _envelope(Canvas c) {
    final lift = 1.2 * _wave;
    final r = Rect.fromLTWH(35, 63 + lift, 30, 20);
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(2.5));
    c.drawShadow(Path()..addRRect(rr), Colors.black, 2, false);
    c.drawRRect(rr, Paint()..color = Colors.white);
    final flap = Paint()
      ..color = const Color(0xFFD6D9E6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round;
    c.drawPath(Path()
      ..moveTo(r.left + 1, r.top + 1)
      ..lineTo(r.center.dx, r.top + 11)
      ..lineTo(r.right - 1, r.top + 1), flap);
    // little heart seal in the brand colour
    _heart(c, Offset(r.center.dx, r.top + 11), 3.6, const Color(0xFFF2557E));
  }

  void _heldHeart(Canvas c) {
    final s = 1 + 0.08 * math.sin(t * 4 * math.pi);
    _heart(c, Offset(50, 72 + _wave), 10 * s, const Color(0xFFFF3D6E), glossy: true);
  }

  void _sunglasses(Canvas c) {
    final p = Paint()..shader = const LinearGradient(colors: [Color(0xFF2A2A3A), Color(0xFF0A0A12)], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(const Rect.fromLTWH(28, 42, 44, 14));
    for (final x in [39.5, 60.5]) {
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, 48.5), width: 18, height: 12), const Radius.circular(5)), p);
      // shine moving across the lenses
      final sx = x - 6 + 12 * ((t * 1.5) % 1);
      c.drawLine(Offset(sx, 44.5), Offset(sx + 3, 52), Paint()
        ..color = Colors.white.withValues(alpha: 0.35)
        ..strokeWidth = 1.4);
    }
    c.drawLine(const Offset(48.5, 47), const Offset(51.5, 47), Paint()
      ..color = const Color(0xFF14141E)
      ..strokeWidth = 2);
  }

  void _cup(Canvas c) {
    final lift = 0.8 * _wave;
    final cup = RRect.fromRectAndCorners(Rect.fromLTWH(39, 64 + lift, 22, 18), bottomLeft: const Radius.circular(7), bottomRight: const Radius.circular(7), topLeft: const Radius.circular(2), topRight: const Radius.circular(2));
    c.drawShadow(Path()..addRRect(cup), Colors.black, 2, false);
    c.drawRRect(cup, Paint()..shader = const LinearGradient(colors: [Colors.white, Color(0xFFE3E6F0)]).createShader(cup.outerRect));
    // handle
    c.drawArc(Rect.fromLTWH(57, 67 + lift, 9, 10), -1.4, 2.8, false, Paint()
      ..color = const Color(0xFFE3E6F0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4);
    // coffee + a little heart on the cup
    c.drawOval(Rect.fromLTWH(40.5, 63.5 + lift, 19, 4), Paint()..color = const Color(0xFF7A4A2A));
    _heart(c, Offset(50, 74 + lift), 3.2, const Color(0xFFF2557E));
  }

  void _headphones(Canvas c) {
    final band = Paint()
      ..shader = const LinearGradient(colors: [Color(0xFF3A3F5C), Color(0xFF1C1F33)]).createShader(const Rect.fromLTWH(18, 18, 64, 30))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    c.drawArc(const Rect.fromLTWH(20, 22, 60, 50), math.pi * 1.08, math.pi * 0.84, false, band);
    for (final x in [21.0, 79.0]) {
      final pad = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, 48), width: 10, height: 16), const Radius.circular(5));
      c.drawRRect(pad, Paint()..shader = const LinearGradient(colors: [Color(0xFFFF5E8A), Color(0xFF8E54E9)], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(pad.outerRect));
    }
  }

  // ------------------------------------------------------------------ effects
  void _steam(Canvas c, Offset base, Color color) {
    for (var i = 0; i < 3; i++) {
      final p = (t * 1.2 + i / 3) % 1;
      c.drawCircle(base + Offset(math.sin((p + i) * 6) * 2.5, -p * 18), 2 + p * 3, Paint()..color = color.withValues(alpha: 0.55 * (1 - p)));
    }
  }

  void _angerMark(Canvas c) {
    final s = 1 + 0.15 * math.sin(t * 8 * math.pi);
    final p = Paint()
      ..color = const Color(0xFFFF3B3B)
      ..strokeWidth = 2.2 * s
      ..strokeCap = StrokeCap.round;
    const o = Offset(76, 20);
    for (final a in [0.0, math.pi / 2, math.pi, math.pi * 1.5]) {
      final d = Offset(math.cos(a), math.sin(a));
      c.drawLine(o + d * 1.5 * s, o + d * 5 * s + Offset(-d.dy, d.dx) * 1.5, p);
    }
  }

  void _exclaim(Canvas c) {
    final pop = math.max(0.0, math.sin(t * 2 * math.pi));
    for (final (x, a) in [(18.0, -0.3), (82.0, 0.3)]) {
      c.save();
      c.translate(x, 22 - pop * 3);
      c.rotate(a);
      final p = Paint()..color = const Color(0xFFFFB534).withValues(alpha: 0.4 + 0.6 * pop);
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-1.6, -8, 3.2, 9), const Radius.circular(1.6)), p);
      c.drawCircle(const Offset(0, 4.5), 1.8, p);
      c.restore();
    }
  }

  void _notes(Canvas c) {
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1;
      final x = (i.isEven ? 84.0 : 14.0) + math.sin(p * 6) * 3;
      final y = 40 - p * 34;
      final paint = Paint()..color = [const Color(0xFF8E54E9), const Color(0xFFFF5E8A), const Color(0xFF3CC8FF)][i].withValues(alpha: 1 - p);
      c.drawOval(Rect.fromCenter(center: Offset(x, y), width: 5, height: 3.8), paint);
      c.drawLine(Offset(x + 2.2, y), Offset(x + 2.2, y - 8), paint..strokeWidth = 1.3);
      c.drawLine(Offset(x + 2.2, y - 8), Offset(x + 5.5, y - 6), paint);
    }
  }

  void _badge(Canvas c) {
    // a round "great!" seal next to the raised wing
    final s = 1 + 0.08 * math.sin(t * 4 * math.pi);
    const o = Offset(84, 26);
    c.drawCircle(o, 8 * s, Paint()..shader = const LinearGradient(colors: [Color(0xFF2ED47A), Color(0xFF12A150)]).createShader(Rect.fromCircle(center: o, radius: 8)));
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    c.drawPath(Path()
      ..moveTo(o.dx - 3.5 * s, o.dy)
      ..lineTo(o.dx - 1 * s, o.dy + 2.8 * s)
      ..lineTo(o.dx + 3.8 * s, o.dy - 2.6 * s), p);
  }

  void _zzz(Canvas c) {
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1;
      final tp = TextPainter(
        text: TextSpan(
          text: 'z',
          style: TextStyle(fontSize: 7 + p * 7, fontWeight: FontWeight.w900, color: const Color(0xFF7B4FE0).withValues(alpha: 1 - p)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(70 + p * 14 + math.sin(p * 6) * 2, 30 - p * 26));
    }
  }

  void _confetti(Canvas c) {
    const colors = [Color(0xFFFFC94D), Color(0xFFFF5E8A), Color(0xFF8E54E9), Color(0xFF3CC8FF), Color(0xFF2ED47A)];
    final rnd = math.Random(7);
    for (var i = 0; i < 18; i++) {
      final x = 8 + rnd.nextDouble() * 84;
      final speed = 0.6 + rnd.nextDouble() * 0.8;
      final y = ((t * speed + rnd.nextDouble()) % 1) * 100 - 6;
      final rot = t * 2 * math.pi * (rnd.nextBool() ? 1 : -1) + i;
      c.save();
      c.translate(x + math.sin(t * 6 + i) * 3, y);
      c.rotate(rot);
      final paint = Paint()..color = colors[i % colors.length].withValues(alpha: 0.9);
      if (i.isEven) {
        c.drawRect(const Rect.fromLTWH(-1.6, -0.9, 3.2, 1.8), paint);
      } else {
        c.drawCircle(Offset.zero, 1.2, paint);
      }
      c.restore();
    }
  }

  void _floatingHearts(Canvas c) {
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1;
      final x = 22 + i * 26 + math.sin(p * 2 * math.pi) * 3;
      _heart(c, Offset(x, 34 - p * 30), 3.5 + p * 2, const Color(0xFFFF5E8A).withValues(alpha: 1 - p));
    }
  }

  void _rainCloud(Canvas c) {
    final cloud = Paint()..color = const Color(0xFFB9C1D9);
    final dx = 1.5 * _wave;
    for (final (o, r) in [(const Offset(42, 14), 6.0), (const Offset(50, 11), 7.5), (const Offset(58, 14), 6.0)]) {
      c.drawCircle(o + Offset(dx, 0), r, cloud);
    }
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(36 + dx, 13, 28, 7), const Radius.circular(4)), cloud);
    final drop = Paint()..color = const Color(0xFF5AB3F5);
    for (var i = 0; i < 3; i++) {
      final p = (t * 1.6 + i / 3) % 1;
      c.drawOval(Rect.fromCenter(center: Offset(43 + i * 7 + dx, 22 + p * 10), width: 1.6, height: 3), drop..color = const Color(0xFF5AB3F5).withValues(alpha: 1 - p));
    }
  }

  void _gears(Canvas c) {
    void gear(Offset o, double r, double a, Color color) {
      c.save();
      c.translate(o.dx, o.dy);
      c.rotate(a);
      final p = Paint()..color = color;
      for (var i = 0; i < 8; i++) {
        c.save();
        c.rotate(i * math.pi / 4);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(0, -r), width: r * 0.5, height: r * 0.5), Radius.circular(r * 0.1)), p);
        c.restore();
      }
      c.drawCircle(Offset.zero, r * 0.85, p);
      c.drawCircle(Offset.zero, r * 0.35, Paint()..color = Colors.white);
      c.restore();
    }

    gear(const Offset(78, 20), 6, t * 2 * math.pi, const Color(0xFF8E54E9));
    gear(const Offset(88, 31), 4, -t * 2 * math.pi * 1.5, const Color(0xFFF2557E));
    // a light bulb idea
    final glow = 0.5 + 0.5 * math.sin(t * 4 * math.pi);
    c.drawCircle(const Offset(66, 10), 4.5 + glow, Paint()
      ..color = const Color(0xFFFFE066).withValues(alpha: 0.35 * glow)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
    c.drawCircle(const Offset(66, 10), 3.4, Paint()..color = const Color(0xFFFFD43B));
    c.drawRect(const Rect.fromLTWH(64.6, 12.8, 2.8, 2.4), Paint()..color = const Color(0xFF8C97B5));
  }

  void _sparkles(Canvas c, int n) {
    for (var i = 0; i < n; i++) {
      final p = (t + i / n) % 1;
      final s = math.sin(p * math.pi) * 3.2;
      final o = [const Offset(84, 22), const Offset(14, 30), const Offset(88, 60)][i % 3];
      _star(c, o, s, const Color(0xFFFFC94D));
    }
  }

  // ------------------------------------------------------------------ shapes
  void _heart(Canvas c, Offset center, double size, Color color, {bool glossy = false}) {
    final s = size / 10;
    final path = Path()
      ..moveTo(center.dx, center.dy + 7 * s)
      ..cubicTo(center.dx - 11 * s, center.dy - 1 * s, center.dx - 6 * s, center.dy - 10 * s, center.dx, center.dy - 4 * s)
      ..cubicTo(center.dx + 6 * s, center.dy - 10 * s, center.dx + 11 * s, center.dy - 1 * s, center.dx, center.dy + 7 * s)
      ..close();
    c.drawPath(path, Paint()..color = color);
    if (glossy) {
      c.drawOval(Rect.fromCenter(center: center + Offset(-3.5 * s, -4 * s), width: 3 * s, height: 2 * s), Paint()..color = Colors.white.withValues(alpha: 0.6));
    }
  }

  void _star(Canvas c, Offset o, double r, Color color) {
    if (r <= 0.2) return;
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final rr = i.isEven ? r : r * 0.35;
      final p = o + Offset(math.cos(a) * rr, math.sin(a) * rr);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    c.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TaviPainter old) => old.t != t || old.pose != pose || old.blend != blend || old.from != from;
}

/// An empty state with Tavi: big animated mascot, title, text and an optional button.
class TaviEmptyState extends StatelessWidget {
  const TaviEmptyState({super.key, required this.pose, required this.title, this.text, this.action, this.size = 150});
  final TaviPose pose;
  final String title;
  final String? text;
  final Widget? action;
  final double size;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).brightness == Brightness.dark ? Colors.white70 : const Color(0xFF656C84);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TaviMascot(pose: pose, size: size),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
          if (text != null) ...[
            const SizedBox(height: 6),
            Text(text!, textAlign: TextAlign.center, style: TextStyle(fontSize: 14.5, height: 1.4, color: muted)),
          ],
          if (action != null) ...[const SizedBox(height: 18), action!],
        ]),
      ),
    );
  }
}
