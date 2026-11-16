import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/models.dart';
import 'avatar.dart';

/// Before a video call: see yourself first. Returns 'video', 'voice' or null (cancelled).
Future<String?> showCallPreview(BuildContext context, AppUser peer) {
  return Navigator.of(context).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _CallPreview(peer: peer)));
}

class _CallPreview extends StatefulWidget {
  const _CallPreview({required this.peer});
  final AppUser peer;

  @override
  State<_CallPreview> createState() => _CallPreviewState();
}

class _CallPreviewState extends State<_CallPreview> {
  final _renderer = RTCVideoRenderer();
  MediaStream? _stream;
  bool _front = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      await _renderer.initialize();
      final s = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': 'user', 'width': 640, 'height': 480},
      });
      if (!mounted) {
        await _stop(s);
        return;
      }
      _stream = s;
      _renderer.srcObject = s;
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = 'Camera not available. Allow camera access in your phone settings.');
    }
  }

  Future<void> _stop(MediaStream? s) async {
    if (s == null) return;
    for (final t in s.getTracks()) {
      try {
        await t.stop();
      } catch (_) {}
    }
    try {
      await s.dispose();
    } catch (_) {}
  }

  Future<void> _flip() async {
    final t = _stream?.getVideoTracks().firstOrNull;
    if (t == null) return;
    try {
      await Helper.switchCamera(t);
      setState(() => _front = !_front);
    } catch (_) {}
  }

  Future<void> _done(String? choice) async {
    final s = _stream;
    _stream = null;
    _renderer.srcObject = null;
    await _stop(s); // the call opens the camera itself
    if (mounted) Navigator.pop(context, choice);
  }

  @override
  void dispose() {
    _stop(_stream);
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.peer;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _done(null);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0E1E),
        body: Stack(fit: StackFit.expand, children: [
          if (_stream != null)
            RTCVideoView(_renderer, mirror: _front, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: _error == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 15)),
              ),
            ),
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0x00000000), Color(0x00000000), Color(0xCC000000)],
                  stops: [0, 0.25, 0.55, 1],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(children: [
                  IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close_rounded, color: Colors.white), onPressed: () => _done(null)),
                  const Spacer(),
                  if (_stream != null) IconButton(tooltip: 'Flip camera', icon: const Icon(Icons.cameraswitch_rounded, color: Colors.white), onPressed: _flip),
                ]),
              ),
              const SizedBox(height: 8),
              ClipOval(child: Avatar(id: p.id, name: p.name, url: p.avatarAbsolute, size: 64)),
              const SizedBox(height: 10),
              Text(p.name, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text('Check how you look before calling', style: TextStyle(color: Colors.white70, fontSize: 14)),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _done('voice'),
                      icon: const Icon(Icons.call_rounded, size: 19),
                      label: const Text('Voice call'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                        minimumSize: const Size.fromHeight(52),
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _done('video'),
                      icon: const Icon(Icons.videocam_rounded, size: 20),
                      label: const Text('Start video'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF22C55E),
                        minimumSize: const Size.fromHeight(52),
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
