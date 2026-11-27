import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Hushi — Hushavia's violet-cap duck. The Tavi identifiers remain for sticker compatibility.
/// Drawn in code (sharp at any size, tiny download) and animated: blinks, breathes, waves,
/// hides its eyes on password screens, searches with a magnifier, sleeps, celebrates…
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
              child: Transform.rotate(angle: tilt, alignment: Alignment.bottomCenter, child: child));
          },
        ),
      ),
    );
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
