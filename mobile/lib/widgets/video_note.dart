import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/models.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'media_widgets.dart';

/// A round video message in the chat: plays muted on tap-less preview, tap → plays with sound.
class VideoNoteBubble extends StatefulWidget {
  const VideoNoteBubble({super.key, required this.message, this.size = 220});
  final Message message;
  final double size;

  @override
  State<VideoNoteBubble> createState() => _VideoNoteBubbleState();
}

class _VideoNoteBubbleState extends State<VideoNoteBubble> {
  VideoPlayerController? _c;
  bool _loading = false;
  bool _failed = false;

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final c = _c;
    if (c != null) {
      if (c.value.isPlaying) {
        await c.pause();
      } else {
        if (c.value.position >= c.value.duration) await c.seekTo(Duration.zero);
        await c.play();
      }
      if (mounted) setState(() {});
      return;
    }
    if (widget.message.media == null || _loading) return;
    setState(() => _loading = true);
    try {
      final f = await resolveMediaFile(context, widget.message);
      final ctrl = VideoPlayerController.file(f);
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose(); // scrolled away / chat closed while loading
        return;
      }
      _failed = false;
      ctrl.addListener(() {
        if (mounted) setState(() {});
      });
      _c = ctrl;
      await ctrl.play();
    } catch (_) {
      _failed = true;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    final progress = ready && c.value.duration.inMilliseconds > 0 ? c.value.position.inMilliseconds / c.value.duration.inMilliseconds : 0.0;
    final secs = widget.message.media?.duration;
    return GestureDetector(
      onTap: _toggle,
      child: SizedBox(
        width: s,
        height: s,
        child: Stack(alignment: Alignment.center, children: [
          Container(
            width: s,
            height: s,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [Brand.inkSoft, Brand.ink], begin: Alignment.topLeft, end: Alignment.bottomRight),
            ),
          ),
          if (ready)
            ClipOval(
              child: SizedBox(
                width: s - 8,
                height: s - 8,
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(width: c.value.size.width, height: c.value.size.height, child: VideoPlayer(c)),
                ),
              ),
            ),
          CustomPaint(size: Size(s, s), painter: _RingPainter(progress, ready && c.value.isPlaying)),
          if (!ready || !c.value.isPlaying)
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
              child: _loading
                  ? const Padding(padding: EdgeInsets.all(15), child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : Icon(_failed ? Icons.error_outline : Icons.play_arrow_rounded, color: Colors.white, size: 34),
            ),
          if (secs != null && (!ready || !c.value.isPlaying))
            Positioned(
              bottom: s * 0.1,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(10)),
                child: Text(duration(secs), style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
        ]),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.progress, this.playing);
  final double progress;
  final bool playing;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(2, 2, size.width - 4, size.height - 4);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.white.withValues(alpha: 0.25);
    canvas.drawArc(r, 0, math.pi * 2, false, base);
    if (progress > 0) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = Brand.primary;
      canvas.drawArc(r, -math.pi / 2, math.pi * 2 * progress, false, p);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.progress != progress || old.playing != playing;
}

/// Result of recording: the file and its length.
class VideoNoteResult {
  VideoNoteResult(this.path, this.seconds);
  final String path;
  final int seconds;
}

/// Full-screen recorder for a round video message (up to 60 s, front camera by default).
class VideoNoteRecorder extends StatefulWidget {
  const VideoNoteRecorder({super.key});

  static const maxSeconds = 60;

  @override
  State<VideoNoteRecorder> createState() => _VideoNoteRecorderState();
}

class _VideoNoteRecorderState extends State<VideoNoteRecorder> {
  List<CameraDescription> _cams = const [];
  CameraController? _c;
  bool _front = true;
  bool _recording = false;
  String? _error;
  int _ms = 0;
  Timer? _timer;
  String? _recorded;
  VideoPlayerController? _preview;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      _cams = await availableCameras();
      if (_cams.isEmpty) throw 'No camera found';
      final cam = _cams.firstWhere(
        (c) => c.lensDirection == (_front ? CameraLensDirection.front : CameraLensDirection.back),
        orElse: () => _cams.first,
      );
      final old = _c;
      final c = CameraController(cam, ResolutionPreset.medium, enableAudio: true);
      await c.initialize();
      await old?.dispose();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _c = c);
    } catch (e) {
      if (mounted) setState(() => _error = '$e'.contains('ermission') ? 'Allow camera and microphone access to record a video message' : 'Could not open the camera');
    }
  }

  Future<void> _start() async {
    final c = _c;
    if (c == null || _recording) return;
    try {
      await c.startVideoRecording();
      if (!mounted) return;
      _ms = 0;
      _timer = Timer.periodic(const Duration(milliseconds: 100), (t) {
        if (!mounted) return t.cancel();
        setState(() => _ms += 100);
        if (_ms >= VideoNoteRecorder.maxSeconds * 1000) _stop();
      });
      setState(() => _recording = true);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not start recording');
    }
  }

  Future<void> _stop() async {
    final c = _c;
    if (c == null || !_recording) return;
    _timer?.cancel();
    setState(() => _recording = false);
    try {
      final x = await c.stopVideoRecording();
      if (_ms < 1000) {
        File(x.path).delete().catchError((_) => File(x.path));
        return;
      }
      final p = VideoPlayerController.file(File(x.path));
      await p.initialize();
      await p.setLooping(true);
      await p.play();
      if (!mounted) {
        await p.dispose();
        return;
      }
      setState(() {
        _recorded = x.path;
        _preview = p;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Recording failed');
    }
  }

  void _discard() {
    _preview?.dispose();
    final f = _recorded;
    if (f != null) File(f).delete().catchError((_) => File(f));
    setState(() {
      _preview = null;
      _recorded = null;
      _ms = 0;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c?.dispose();
    _preview?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width * 0.78;
    final c = _c;
    final preview = _preview;
    Widget circle;
    if (preview != null) {
      circle = FittedBox(fit: BoxFit.cover, child: SizedBox(width: preview.value.size.width, height: preview.value.size.height, child: VideoPlayer(preview)));
    } else if (c != null && c.value.isInitialized) {
      final ps = c.value.previewSize;
      circle = FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(width: ps?.height ?? 480, height: ps?.width ?? 640, child: CameraPreview(c)),
      );
    } else {
      circle = Center(child: _error == null ? const CircularProgressIndicator(color: Colors.white) : const Icon(Icons.videocam_off, color: Colors.white54, size: 48));
    }
    return Scaffold(
      backgroundColor: const Color(0xF20B0D17),
      body: SafeArea(
        child: Column(children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
          ),
          const Spacer(),
          SizedBox(
            width: size + 12,
            height: size + 12,
            child: Stack(alignment: Alignment.center, children: [
              ClipOval(child: SizedBox(width: size, height: size, child: ColoredBox(color: Brand.ink, child: circle))),
              CustomPaint(
                size: Size(size + 12, size + 12),
                painter: _RingPainter(_recording ? _ms / (VideoNoteRecorder.maxSeconds * 1000) : (preview != null ? 1 : 0), _recording),
              ),
            ]),
          ),
          const SizedBox(height: 18),
          Text(
            _error ?? (_recording ? duration(_ms ~/ 1000) : preview != null ? 'Send this video message?' : 'Tap the button to record (up to 60 s)'),
            textAlign: TextAlign.center,
            style: TextStyle(color: _recording ? Brand.primaryLight : Colors.white70, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: preview != null
                ? Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    _circleBtn(Icons.delete_outline_rounded, Colors.white24, _discard, 'Delete'),
                    _circleBtn(Icons.send_rounded, Brand.primary, () {
                      preview.pause();
                      Navigator.pop(context, VideoNoteResult(_recorded!, (_ms / 1000).ceil()));
                    }, 'Send', big: true),
                  ])
                : Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    _circleBtn(Icons.cameraswitch_rounded, Colors.white24, _recording || _cams.length < 2
                        ? null
                        : () {
                            _front = !_front;
                            _open();
                          }, 'Flip'),
                    _circleBtn(_recording ? Icons.stop_rounded : Icons.fiber_manual_record_rounded, Colors.red, c == null ? null : (_recording ? _stop : _start),
                        _recording ? 'Stop' : 'Record', big: true),
                    const SizedBox(width: 60),
                  ]),
          ),
        ]),
      ),
    );
  }

  Widget _circleBtn(IconData icon, Color bg, VoidCallback? onTap, String label, {bool big = false}) => Column(mainAxisSize: MainAxisSize.min, children: [
        Material(
          color: onTap == null ? bg.withValues(alpha: 0.3) : bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: big ? 76 : 60, height: big ? 76 : 60, child: Icon(icon, color: Colors.white, size: big ? 38 : 28)),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]);
}
