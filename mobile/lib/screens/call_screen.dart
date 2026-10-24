import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../state/call_manager.dart';
import '../theme/brand.dart';
import '../widgets/avatar.dart';

/// Full-screen call UI: ringing (in/out), connecting, in call (voice or video), ended + rating.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final CallManager _calls;
  bool _popped = false;
  bool _controlsVisible = true;

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
    super.dispose();
  }

  void _onChange() {
    if (_calls.phase == CallPhase.idle && !_popped && mounted) {
      _popped = true;
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CallManager>();
    final peer = c.peer;
    final showRemoteVideo = c.video && c.hasRemoteVideo && !c.remoteVideoOff && c.phase == CallPhase.connected;
    final showLocalVideo = c.video && !c.cameraOff && c.phase != CallPhase.ended;

    return PopScope(
      canPop: c.phase == CallPhase.idle || c.phase == CallPhase.ended,
      child: Scaffold(
        backgroundColor: Brand.ink,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: showRemoteVideo ? () => setState(() => _controlsVisible = !_controlsVisible) : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // background: remote video, or the person's photo on a dark gradient
              if (showRemoteVideo)
                RTCVideoView(c.remoteRenderer,
                    objectFit: c.remoteSharing ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
              else if (showLocalVideo && c.phase != CallPhase.connected)
                // camera preview while ringing / connecting
                Opacity(
                  opacity: 0.55,
                  child: RTCVideoView(c.localRenderer, mirror: c.frontCamera, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                )
              else
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF2A3152), Brand.ink],
                    ),
                  ),
                ),

              // name + status
              SafeArea(
                child: AnimatedOpacity(
                  opacity: _controlsVisible || !showRemoteVideo ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 48),
                    child: Column(children: [
                      if (!showRemoteVideo && peer != null) ...[
                        Avatar(id: peer.id, name: peer.name, url: peer.avatarAbsolute, size: 120),
                        const SizedBox(height: 20),
                      ],
                      Text(
                        peer?.name ?? '',
                        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Text(c.statusText, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                      if (c.remoteMuted && c.phase == CallPhase.connected)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.mic_off, color: Colors.white70, size: 18),
                            const SizedBox(width: 4),
                            Text('${peer?.firstName ?? 'They'} muted the microphone', style: const TextStyle(color: Colors.white70)),
                          ]),
                        ),
                    ]),
                  ),
                ),
              ),

              // my camera, small, top-right
              if (showLocalVideo && c.phase == CallPhase.connected)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 12,
                  right: 12,
                  width: 110,
                  height: 160,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: RTCVideoView(c.localRenderer, mirror: c.frontCamera && !c.sharingScreen, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                  ),
                ),

              // call waiting: someone else is calling
              if (c.waitingCall != null)
                Positioned(
                  left: 12,
                  right: 12,
                  top: MediaQuery.of(context).padding.top + (showLocalVideo && c.phase == CallPhase.connected ? 180 : 12),
                  child: _WaitingBanner(c: c),
                ),

              // controls
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  child: AnimatedOpacity(
                    opacity: _controlsVisible || !showRemoteVideo ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), child: _controls(c)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls(CallManager c) {
    if (c.phase == CallPhase.incoming) {
      return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _RoundButton(icon: Icons.call_end, label: 'Decline', color: Colors.red, onTap: c.decline),
        _RoundButton(icon: c.video ? Icons.videocam : Icons.call, label: 'Accept', color: Brand.accent, onTap: c.accept),
      ]);
    }
    if (c.phase == CallPhase.ended) {
      if (!c.canRate) return const SizedBox(height: 90);
      return Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('How was the call quality?', style: TextStyle(color: Colors.white, fontSize: 16)),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            5,
            (i) => IconButton(
              iconSize: 38,
              icon: const Icon(Icons.star_rounded, color: Colors.amber),
              onPressed: () => c.rate(i + 1),
            ),
          ),
        ),
        TextButton(onPressed: c.close, child: const Text('Close', style: TextStyle(color: Colors.white70))),
      ]);
    }
    final inCall = c.phase == CallPhase.connected || c.phase == CallPhase.reconnecting || c.phase == CallPhase.connecting;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _RoundButton(
          icon: c.speaker ? Icons.volume_up : Icons.volume_down,
          label: 'Speaker',
          active: c.speaker,
          onTap: c.toggleSpeaker,
        ),
        if (c.video)
          _RoundButton(
            icon: c.cameraOff ? Icons.videocam_off : Icons.videocam,
            label: 'Camera',
            active: !c.cameraOff,
            onTap: c.toggleCamera,
          ),
        if (c.video && inCall && !c.sharingScreen)
          _RoundButton(icon: Icons.cameraswitch, label: 'Flip', onTap: c.switchCamera),
        if (c.video && c.phase == CallPhase.connected)
          _RoundButton(
            icon: c.sharingScreen ? Icons.stop_screen_share : Icons.screen_share_outlined,
            label: c.sharingScreen ? 'Stop' : 'Share',
            active: c.sharingScreen,
            onTap: () async {
              final err = await c.toggleScreenShare();
              if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
            },
          ),
        _RoundButton(
          icon: c.muted ? Icons.mic_off : Icons.mic,
          label: c.muted ? 'Unmute' : 'Mute',
          active: c.muted,
          onTap: c.toggleMute,
        ),
      ]),
      const SizedBox(height: 28),
      _RoundButton(icon: Icons.call_end, label: 'End call', color: Colors.red, size: 72, onTap: c.hangup),
    ]);
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.label, required this.onTap, this.color, this.active = false, this.size = 60});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (active ? Colors.white : Colors.white.withAlpha(40));
    final fg = color != null ? Colors.white : (active ? Brand.ink : Colors.white);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: size, height: size, child: Icon(icon, color: fg, size: size * 0.45)),
        ),
      ),
      const SizedBox(height: 6),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
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
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E2440).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white12),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 18, offset: Offset(0, 6))],
        ),
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
            style: IconButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
            onPressed: c.declineWaiting,
            icon: const Icon(Icons.call_end_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Brand.accent, padding: const EdgeInsets.symmetric(horizontal: 12)),
            onPressed: c.endAndAnswer,
            icon: const Icon(Icons.call_rounded, size: 18),
            label: const Text('End & answer'),
          ),
        ]),
      ),
    );
  }
}
