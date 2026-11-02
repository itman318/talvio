import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../state/call_manager.dart';
import '../state/chat_store.dart';
import '../widgets/avatar.dart';

/// Full-screen call UI: ringing (in/out), connecting, in call (voice or video), ended + rating.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with SingleTickerProviderStateMixin {
  late final CallManager _calls;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
  bool _popped = false;
  bool _controlsVisible = true;
  Offset? _pip; // my camera's position (dragged by the user)

  @override
  void initState() {
    super.initState();
    _calls = context.read<CallManager>();
    _calls.screenVisible = true;
    _calls.addListener(_onChange);
  }

  @override
  void dispose() {
    _calls.removeListener(_onChange);
    _calls.screenVisible = false;
    _pulse.dispose();
    super.dispose();
  }

  void _onChange() {
    if (_calls.phase == CallPhase.idle && !_popped && mounted) {
      _popped = true;
      Navigator.of(context).maybePop();
    }
  }

  /// Can't talk now: decline and send a quick message instead.
  Future<void> _declineWithMessage(CallManager c) async {
    final peer = c.peer;
    final text = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1B2140),
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final t in const ['Can’t talk now. I’ll call you back.', 'I’m in a meeting — text me?', 'On my way!', 'Call you in 5 minutes.'])
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded, color: Colors.white70),
              title: Text(t, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, t),
            ),
        ]),
      ),
    );
    if (text == null || peer == null || !mounted) return;
    final store = context.read<ChatStore>();
    await c.decline();
    try {
      final chat = await store.openPrivateWith(peer.id);
      await store.sendText(chat.id, text);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CallManager>();
    final peer = c.peer;
    final mq = MediaQuery.of(context);
    final showRemoteVideo = c.video && c.hasRemoteVideo && !c.remoteVideoOff && c.phase == CallPhase.connected;
    final showLocalVideo = c.video && !c.cameraOff && c.phase != CallPhase.ended;
    final controlsOn = _controlsVisible || !showRemoteVideo;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(systemNavigationBarColor: const Color(0xFF0B0E1E)),
      child: PopScope(
        canPop: c.phase != CallPhase.incoming, // back = minimize; the call keeps going in a floating window
        child: Scaffold(
          backgroundColor: const Color(0xFF0B0E1E),
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: showRemoteVideo ? () => setState(() => _controlsVisible = !_controlsVisible) : null,
            child: Stack(fit: StackFit.expand, children: [
              // ---------------- background
              if (showRemoteVideo)
                RTCVideoView(c.remoteRenderer,
                    objectFit: c.remoteSharing ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
              else if (showLocalVideo && c.phase != CallPhase.connected)
                Stack(fit: StackFit.expand, children: [
                  RTCVideoView(c.localRenderer, mirror: c.frontCamera, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                  Container(color: Colors.black.withValues(alpha: 0.45)),
                ])
              else
                _Backdrop(url: peer?.avatarAbsolute),

              // soft shade so white text stays readable over video
              if (showRemoteVideo)
                IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: controlsOn ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x99000000), Color(0x00000000), Color(0x00000000), Color(0xB3000000)],
                          stops: [0, 0.22, 0.6, 1],
                        ),
                      ),
                    ),
                  ),
                ),

              // ---------------- top bar: minimize, encryption, connection quality (pinned to the top)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: SafeArea(
                bottom: false,
                child: AnimatedOpacity(
                  opacity: controlsOn ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Row(children: [
                      if (c.inProgress) ...[
                        _Glass(
                          radius: 20,
                          child: InkWell(
                            onTap: () => Navigator.of(context).maybePop(),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 24),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      const _Glass(
                        radius: 16,
                        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.lock_rounded, size: 13, color: Colors.white70),
                          SizedBox(width: 5),
                          Text('Encrypted', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                      const Spacer(),
                      if (c.phase == CallPhase.connected && c.quality > 0) _QualityBars(level: c.quality),
                    ]),
                  ),
                ),
              ),
              ),

              // ---------------- who + status
              if (!showRemoteVideo)
                Align(
                  alignment: const Alignment(0, -0.38),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (peer != null)
                      AnimatedBuilder(
                        animation: _pulse,
                        builder: (_, __) => _AvatarRings(
                          t: _pulse.value,
                          ringing: c.phase == CallPhase.outgoing || c.phase == CallPhase.incoming || c.phase == CallPhase.connecting,
                          level: c.phase == CallPhase.connected ? c.remoteLevel : 0,
                          child: ClipOval(child: Avatar(id: peer.id, name: peer.name, url: peer.avatarAbsolute, size: 128)),
                        ),
                      ),
                    const SizedBox(height: 26),
                    _NameAndStatus(c: c),
                  ]),
                )
              else
                SafeArea(
                  child: AnimatedOpacity(
                    opacity: controlsOn ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Padding(padding: const EdgeInsets.only(top: 56), child: Align(alignment: Alignment.topCenter, child: _NameAndStatus(c: c, small: true))),
                  ),
                ),

              // ---------------- my camera: a small window you can drag to any corner
              if (showLocalVideo && c.phase == CallPhase.connected) _localPip(c, mq),

              // ---------------- someone else is calling
              if (c.waitingCall != null)
                Positioned(left: 12, right: 12, top: mq.padding.top + 56, child: _WaitingBanner(c: c)),

              // ---------------- controls
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  child: AnimatedSlide(
                    offset: controlsOn ? Offset.zero : const Offset(0, 0.4),
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: controlsOn ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 22), child: _controls(c)),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _localPip(CallManager c, MediaQueryData mq) {
    const w = 104.0, h = 150.0;
    final size = mq.size;
    final pos = _pip ?? Offset(size.width - w - 14, mq.padding.top + 60);
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      width: w,
      height: h,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() => _pip = Offset(
              (pos.dx + d.delta.dx).clamp(8, size.width - w - 8),
              (pos.dy + d.delta.dy).clamp(mq.padding.top + 8, size.height - h - mq.padding.bottom - 8),
            )),
        onPanEnd: (_) {
          // snap to the nearest corner
          final left = pos.dx + w / 2 < size.width / 2;
          final top = pos.dy + h / 2 < size.height / 2;
          setState(() => _pip = Offset(left ? 14 : size.width - w - 14, top ? mq.padding.top + 60 : size.height - h - mq.padding.bottom - 220));
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 1.5),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 16, offset: Offset(0, 6))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(17),
            child: RTCVideoView(c.localRenderer, mirror: c.frontCamera && !c.sharingScreen, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
          ),
        ),
      ),
    );
  }

  Widget _controls(CallManager c) {
    if (c.phase == CallPhase.incoming) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        TextButton.icon(
          onPressed: () => _declineWithMessage(c),
          style: TextButton.styleFrom(foregroundColor: Colors.white70),
          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
          label: const Text('Reply with message'),
        ),
        const SizedBox(height: 22),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _CallButton(icon: Icons.call_end_rounded, label: 'Decline', color: const Color(0xFFF0384F), size: 74, onTap: c.decline),
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, child) => Transform.scale(scale: 1 + 0.06 * math.sin(_pulse.value * math.pi * 2).abs(), child: child),
            child: _CallButton(icon: c.video ? Icons.videocam_rounded : Icons.call_rounded, label: 'Accept', color: const Color(0xFF22C55E), size: 74, onTap: c.accept),
          ),
        ]),
      ]);
    }
    if (c.phase == CallPhase.ended) {
      return _Glass(
        radius: 28,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (c.canRate) ...[
            const Text('How was the call?', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                5,
                (i) => IconButton(iconSize: 36, icon: const Icon(Icons.star_rounded, color: Color(0xFFFFC21A)), onPressed: () => c.rate(i + 1)),
              ),
            ),
            const SizedBox(height: 4),
          ],
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: c.close,
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24), minimumSize: const Size.fromHeight(48), shape: const StadiumBorder()),
                child: const Text('Close'),
              ),
            ),
            if (c.peer != null) ...[
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    final p = c.peer!;
                    final v = c.video;
                    c.close();
                    Future.delayed(const Duration(milliseconds: 250), () => c.start(p, video: v));
                  },
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF22C55E), minimumSize: const Size.fromHeight(48), shape: const StadiumBorder()),
                  icon: Icon(c.video ? Icons.videocam_rounded : Icons.call_rounded, size: 19),
                  label: const Text('Call again'),
                ),
              ),
            ],
          ]),
        ]),
      );
    }
    final buttons = <Widget>[
      _CallButton(icon: c.speaker ? Icons.volume_up_rounded : Icons.volume_down_rounded, label: 'Speaker', active: c.speaker, onTap: c.toggleSpeaker),
      if (c.video) _CallButton(icon: c.cameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded, label: 'Camera', active: !c.cameraOff, onTap: c.toggleCamera),
      if (c.video && !c.cameraOff && !c.sharingScreen) _CallButton(icon: Icons.cameraswitch_rounded, label: 'Flip', onTap: c.switchCamera),
      if (c.video && c.phase == CallPhase.connected)
        _CallButton(
          icon: c.sharingScreen ? Icons.stop_screen_share_rounded : Icons.screen_share_rounded,
          label: c.sharingScreen ? 'Stop' : 'Share',
          active: c.sharingScreen,
          onTap: () async {
            final messenger = ScaffoldMessenger.of(context);
            final err = await c.toggleScreenShare();
            if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
          },
        ),
      _CallButton(icon: c.muted ? Icons.mic_off_rounded : Icons.mic_rounded, label: c.muted ? 'Unmute' : 'Mute', active: c.muted, onTap: c.toggleMute),
    ];
    return _Glass(
      radius: 30,
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: buttons),
        const SizedBox(height: 18),
        _CallButton(icon: Icons.call_end_rounded, label: 'End', color: const Color(0xFFF0384F), size: 68, onTap: c.hangup),
      ]),
    );
  }
}

// ------------------------------------------------------------------ pieces

/// Dark brand backdrop with the person's photo softly blurred behind.
class _Backdrop extends StatelessWidget {
  const _Backdrop({this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF2B1D5C), Color(0xFF151A36), Color(0xFF0B0E1E)]),
        ),
      ),
      if (url != null)
        Opacity(
          opacity: 0.35,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
            child: Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox()),
          ),
        ),
      // a warm brand glow at the top
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(center: Alignment(0, -0.75), radius: 0.9, colors: [Color(0x556D4AFF), Color(0x006D4AFF)]),
        ),
      ),
    ]);
  }
}

/// Avatar with ripples while ringing, and a glow that grows with the other person's voice.
class _AvatarRings extends StatelessWidget {
  const _AvatarRings({required this.t, required this.ringing, required this.level, required this.child});
  final double t;
  final bool ringing;
  final double level;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const base = 128.0;
    return SizedBox(
      width: 230,
      height: 230,
      child: Stack(alignment: Alignment.center, children: [
        if (ringing)
          for (var i = 0; i < 3; i++)
            Builder(builder: (_) {
              final p = (t + i / 3) % 1;
              return Container(
                width: base + 100 * p,
                height: base + 100 * p,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withValues(alpha: 0.28 * (1 - p)), width: 2)),
              );
            })
        else
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: base + 20 + 60 * math.min(1, level * 4),
            height: base + 20 + 60 * math.min(1, level * 4),
            decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF6D4AFF).withValues(alpha: 0.10 + 0.25 * math.min(1, level * 4))),
          ),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [Color(0xFF9A7BFF), Color(0xFF6D4AFF), Color(0xFF6C4BE0)])),
          child: child,
        ),
      ]),
    );
  }
}

class _NameAndStatus extends StatelessWidget {
  const _NameAndStatus({required this.c, this.small = false});
  final CallManager c;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final peer = c.peer;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(
        peer?.name ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white, fontSize: small ? 20 : 28, fontWeight: FontWeight.w800, letterSpacing: -0.3, shadows: const [Shadow(color: Colors.black38, blurRadius: 8)]),
      ),
      const SizedBox(height: 6),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Text(
          c.statusText,
          key: ValueKey(c.phase),
          style: TextStyle(
            color: c.phase == CallPhase.reconnecting ? const Color(0xFFFFC21A) : Colors.white70,
            fontSize: small ? 14 : 16,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
      if (c.remoteMuted && c.phase == CallPhase.connected)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: _Glass(
            radius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.mic_off_rounded, color: Colors.white70, size: 15),
              const SizedBox(width: 5),
              Text('${peer?.firstName ?? 'They'} is muted', style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
            ]),
          ),
        ),
    ]);
  }
}

class _QualityBars extends StatelessWidget {
  const _QualityBars({required this.level});
  final int level; // 1..3

  @override
  Widget build(BuildContext context) {
    final color = level >= 3 ? const Color(0xFF22C55E) : (level == 2 ? const Color(0xFFFFC21A) : const Color(0xFFF0384F));
    return _Glass(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var i = 1; i <= 3; i++)
          Container(
            width: 4,
            height: 5.0 + i * 4,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(color: i <= level ? color : Colors.white24, borderRadius: BorderRadius.circular(2)),
          ),
        const SizedBox(width: 3),
        Text(level >= 3 ? 'Good' : (level == 2 ? 'Fair' : 'Weak'), style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Frosted glass panel.
class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.radius = 20, this.padding = EdgeInsets.zero});
  final Widget child;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({required this.icon, required this.label, required this.onTap, this.color, this.active = false, this.size = 56});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (active ? Colors.white : Colors.white.withValues(alpha: 0.14));
    final fg = color != null ? Colors.white : (active ? const Color(0xFF151A36) : Colors.white);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bg,
          boxShadow: color != null ? [BoxShadow(color: color!.withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 6))] : null,
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: Icon(icon, color: fg, size: size * 0.44),
          ),
        ),
      ),
      const SizedBox(height: 7),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500)),
    ]);
  }
}

class _WaitingBanner extends StatelessWidget {
  const _WaitingBanner({required this.c});
  final CallManager c;

  @override
  Widget build(BuildContext context) {
    final w = c.waitingCall!;
    final who = w.peer;
    return Material(
      color: Colors.transparent,
      child: _Glass(
        radius: 20,
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(children: [
          if (who != null) Avatar(id: who.id, name: who.name, url: who.avatarAbsolute, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(who?.name ?? 'Someone', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              Text(w.video ? 'Waiting · video call' : 'Waiting · voice call', style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
            ]),
          ),
          IconButton(
            tooltip: 'Decline',
            style: IconButton.styleFrom(backgroundColor: const Color(0xFFF0384F)),
            onPressed: c.declineWaiting,
            icon: const Icon(Icons.call_end_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF22C55E), padding: const EdgeInsets.symmetric(horizontal: 12)),
            onPressed: c.endAndAnswer,
            icon: const Icon(Icons.call_rounded, size: 18),
            label: const Text('End & answer'),
          ),
        ]),
      ),
    );
  }
}
