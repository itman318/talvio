import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Poses used by Hushavia's illustrated duck stickers.
enum TaviPose {
  idle,
  wave, // hello / empty chats
  search, // nothing found / no contacts
  hideEyes, // password screens (wings over the eyes)
  peek, // password shown: one wing lowered
  celebrate, // success, Hushavia Plus
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

/// Tavi stickers people can send. The second half are Hushavia Plus only.
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

String _duckAsset(TaviPose pose) {
  final extension = pose == TaviPose.angry || pose == TaviPose.shocked ? 'png' : 'webp';
  return '${pose.name}.$extension';
}

class _TaviMascotState extends State<TaviMascot> with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(vsync: this, duration: const Duration(milliseconds: 2100));

  void _syncMotion() {
    final play = widget.animate && TickerMode.of(context) && !MediaQuery.disableAnimationsOf(context);
    if (play && !_motion.isAnimating) _motion.repeat();
    if (!play) _motion.reset();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(TaviMascot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final asset = _duckAsset(widget.pose);
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: AnimatedBuilder(
          animation: _motion,
          child: Image.asset('assets/mascot/duck-$asset', key: ValueKey(asset),
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(1, 512).toInt(),
            fit: BoxFit.contain),
          builder: (context, child) {
            final phase = _motion.value * 2 * math.pi;
            final sway = math.sin(phase);
            final (tilt, lift) = switch (widget.pose) {
              TaviPose.angry => (0.045 * math.sin(phase * 3), 0.0),
              TaviPose.celebrate || TaviPose.laugh || TaviPose.music => (0.055 * sway, 0.06 * sway.abs()),
              TaviPose.sleep || TaviPose.sad => (0.018 * sway, 0.008 * sway.abs()),
              TaviPose.shocked => (0.0, 0.055 * math.max(0.0, sway)),
              _ => (0.04 * sway, 0.025 * sway.abs()),
            };
            return Transform.translate(offset: Offset(0, -size * lift),
              child: Transform.rotate(angle: tilt, alignment: Alignment.bottomCenter,
                child: _DuckExpression(pose: widget.pose, phase: phase, child: child!)));
          },
        ),
      ),
    );
  }
}


/// Moves adjacent bands of the same artwork together at their shared edges.
/// The feet stay planted while the cap, face and jacket can move independently.
class _DuckExpression extends SingleChildRenderObjectWidget {
  const _DuckExpression({required this.pose, required this.phase, required super.child});
  final TaviPose pose;
  final double phase;

  @override
  _DuckExpressionBox createRenderObject(BuildContext context) => _DuckExpressionBox(pose, phase);

  @override
  void updateRenderObject(BuildContext context, _DuckExpressionBox box) {
    box.pose = pose;
    box.phase = phase;
    box.markNeedsPaint();
  }
}

class _DuckExpressionBox extends RenderProxyBox {
  _DuckExpressionBox(this.pose, this.phase);
  TaviPose pose;
  double phase;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || phase == 0) {
      super.paint(context, offset);
      return;
    }
    final beat = math.sin(phase);
    final pulse = (1 - math.cos(phase)) / 2;
    final blink = math.pow(math.max(0.0, math.sin(phase)), 18).toDouble();
    // Vertical displacement at the cap brim, eyes, bill and jacket.
    final (cap, eyes, bill, body) = switch (pose) {
      TaviPose.idle => (0.0, .035 * blink, 0.0, .006 * beat),
      TaviPose.wave => (-.018 * pulse, .013 * beat, .01 * beat, .012 * beat),
      TaviPose.cool => (.042 * pulse, .012 * pulse, .005 * pulse, 0.0),
      TaviPose.laugh => (.008 * beat, .012 * blink, .04 * math.sin(phase * 3), .012 * beat),
      TaviPose.sleep => (0.0, .01 * pulse, .008 * pulse, -.027 * pulse),
      TaviPose.shocked => (-.035 * pulse, -.016 * pulse, .035 * pulse, .009 * beat),
      TaviPose.angry => (.026 * pulse, .02 * pulse, -.012 * pulse, -.009 * beat),
      TaviPose.hideEyes => (.015 * pulse, .023 * pulse, .01 * beat, -.018 * pulse),
      TaviPose.peek => (-.016 * pulse, -.021 * pulse, .003 * beat, .008 * beat),
      TaviPose.coffee => (.009 * pulse, .018 * blink, -.022 * pulse, -.009 * pulse),
      TaviPose.music => (.032 * beat, .015 * beat, .011 * beat, -.013 * beat),
      TaviPose.celebrate => (-.021 * pulse, -.015 * pulse, .015 * pulse, .027 * beat),
      TaviPose.search => (-.012 * pulse, .02 * blink, .012 * beat, .009 * beat),
      TaviPose.mail => (.012 * pulse, .018 * blink, .008 * beat, -.016 * pulse),
      TaviPose.thumbsUp => (.025 * pulse, .012 * pulse, .009 * pulse, -.014 * pulse),
      TaviPose.think => (-.012 * beat, .018 * blink, -.011 * pulse, .006 * beat),
      TaviPose.sad => (.023 * pulse, .022 * pulse, .015 * pulse, .012 * pulse),
      TaviPose.love => (-.01 * pulse, .016 * blink, .012 * pulse, -.022 * pulse),
    };
    const source = [0.0, .22, .33, .46, .72, 1.0];
    final target = [0.0, .22 + cap, .33 + eyes, .46 + bill, .72 + body, 1.0];
    for (var i = 0; i < source.length - 1; i++) {
      final top = target[i] * size.height;
      final bottom = target[i + 1] * size.height;
      final scale = (target[i + 1] - target[i]) / (source[i + 1] - source[i]);
      final matrix = Matrix4.identity()
        ..setEntry(1, 1, scale)
        ..setEntry(1, 3, top - source[i] * size.height * scale);
      context.pushClipRect(needsCompositing, offset, Rect.fromLTRB(0, top, size.width, bottom),
        (ctx, at) => ctx.pushTransform(needsCompositing, at, matrix,
          (inner, origin) => inner.paintChild(child!, origin)), clipBehavior: Clip.hardEdge);
    }
  }
}

/// An empty state with Tavi: big animated mascot, title, text and an optional button.
class TaviEmptyState extends StatelessWidget {
  const TaviEmptyState({super.key, required this.pose, required this.title, this.text, this.action, this.size = 150, this.art});
  final TaviPose pose;
  final String? art;
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
          AppMascot(pose: pose, size: size, art: art),
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

/// Hushavia's contextual animated mascot. Each pose has its own expression, props and
/// motion; explicit illustrated artwork remains available for dedicated screens.
class AppMascot extends StatelessWidget {
  const AppMascot({super.key, required this.pose, this.size = 150, this.art, this.animate = true});
  final TaviPose pose;
  final double size;

  /// A specific picture instead of the pose's default: hide, wave, nocontacts, search, cool, sleep,
  /// delete, contacts, settings, secure.
  final String? art;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final still = !animate || MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context);
    final loop = art == 'nocontacts' || art == 'contacts' ? 'contacts' : pose == TaviPose.wave ? 'hello' : null;
    if (loop == null && !still) {
      return ExcludeSemantics(child: TaviMascot(pose: pose, size: size));
    }
    final asset = loop == null ? _duckAsset(pose) : still ? '$loop-still.webp' : '$loop.gif';
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: AnimatedSwitcher(
          duration: still ? Duration.zero : const Duration(milliseconds: 160),
          child: Image.asset('assets/mascot/duck-$asset', key: ValueKey(asset), cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(1, 512).toInt(), fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// Animated Hushi sticker artwork used in conversations and the sticker picker.
class HushiSticker extends StatelessWidget {
  const HushiSticker({super.key, required this.pose, this.size = 150, this.animate = true});
  final TaviPose pose;
  final double size;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final still = !animate || MediaQuery.disableAnimationsOf(context) || !TickerMode.of(context);
    if (still || !taviStickers.any((sticker) => sticker.$1 == pose)) {
      return AppMascot(pose: pose, size: size, animate: false);
    }
    return SizedBox.square(
      dimension: size,
      child: Image.asset(
        'assets/mascot/hushi-${pose.name}.webp',
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => AppMascot(pose: pose, size: size),
      ),
    );
  }
}

/// Groups only secret inputs. Leaving them for a hint, Done, or a dialog
/// action uncovers the eyes without inspecting or retaining the secret.
class SecretEntryMascot extends StatelessWidget {
  const SecretEntryMascot({super.key, required this.child, this.size = 90});
  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    child: Builder(builder: (context) => Column(mainAxisSize: MainAxisSize.min, children: [
      AppMascot(pose: Focus.of(context).hasFocus ? TaviPose.hideEyes : TaviPose.idle, size: size),
      child,
    ])),
  );
}
