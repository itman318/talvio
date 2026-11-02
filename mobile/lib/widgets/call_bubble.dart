import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../state/call_manager.dart';
import 'avatar.dart';

/// Floating call window shown over the app while a call is minimized: drag it anywhere,
/// tap it to go back to the call. Video calls show the other person's video; voice calls a compact pill.
class CallBubble extends StatefulWidget {
  const CallBubble({super.key});

  @override
  State<CallBubble> createState() => _CallBubbleState();
}

class _CallBubbleState extends State<CallBubble> {
  Offset? _pos;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CallManager>();
    if (!c.inProgress || c.screenVisible || c.peer == null) return const SizedBox.shrink();
    final mq = MediaQuery.of(context);
    final video = c.video && c.phase == CallPhase.connected && c.hasRemoteVideo && !c.remoteVideoOff;
    final w = video ? 112.0 : 196.0;
    final h = video ? 164.0 : 60.0;
    final size = mq.size;
    final pos = _pos ?? Offset(size.width - w - 12, mq.padding.top + 72);
    final clamped = Offset(pos.dx.clamp(8, size.width - w - 8), pos.dy.clamp(mq.padding.top + 8, size.height - h - mq.padding.bottom - 8));

    return Positioned(
      left: clamped.dx,
      top: clamped.dy,
      width: w,
      height: h,
      child: GestureDetector(
        onTap: c.showScreen,
        onPanUpdate: (d) => setState(() => _pos = clamped + d.delta),
        onPanEnd: (_) {
          // stick to the nearest side
          final left = clamped.dx + w / 2 < size.width / 2;
          setState(() => _pos = Offset(left ? 12 : size.width - w - 12, clamped.dy));
        },
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(video ? 18 : 30),
              gradient: video ? null : const LinearGradient(colors: [Color(0xFF6C4BE0), Color(0xFF6D4AFF)]),
              color: video ? Colors.black : null,
              boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 18, offset: Offset(0, 6))],
            ),
            clipBehavior: Clip.antiAlias,
            child: video ? _video(c) : _pill(c),
          ),
        ),
      ),
    );
  }

  Widget _video(CallManager c) => Stack(fit: StackFit.expand, children: [
        RTCVideoView(c.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 5),
            color: Colors.black45,
            child: Text(c.statusText,
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontFeatures: [FontFeature.tabularFigures()])),
          ),
        ),
        Positioned(top: 4, right: 4, child: _end(c, 28)),
      ]);

  Widget _pill(CallManager c) {
    final p = c.peer!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(children: [
        Avatar(id: p.id, name: p.name, url: p.avatarAbsolute, size: 44),
        const SizedBox(width: 9),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.firstName.isNotEmpty ? p.firstName : p.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5)),
            Text(c.statusText,
                maxLines: 1, style: const TextStyle(color: Colors.white70, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
          ]),
        ),
        GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            c.toggleMute();
          },
          child: Icon(c.muted ? Icons.mic_off_rounded : Icons.mic_rounded, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 8),
        _end(c, 36),
      ]),
    );
  }

  Widget _end(CallManager c, double s) => GestureDetector(
        onTap: c.hangup,
        child: Container(
          width: s,
          height: s,
          decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFF0384F)),
          child: Icon(Icons.call_end_rounded, color: Colors.white, size: s * 0.55),
        ),
      );
}

/// What the small Android picture-in-picture window shows during a call: just the other person.
class PipCallView extends StatelessWidget {
  const PipCallView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CallManager>();
    final p = c.peer;
    final video = c.video && c.hasRemoteVideo && !c.remoteVideoOff;
    return ColoredBox(
      color: const Color(0xFF0B0E1E),
      child: video
          ? RTCVideoView(c.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          : Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (p != null) Avatar(id: p.id, name: p.name, url: p.avatarAbsolute, size: 56),
                const SizedBox(height: 6),
                Text(c.statusText, style: const TextStyle(color: Colors.white70, fontSize: 12, decoration: TextDecoration.none)),
              ]),
            ),
    );
  }
}
