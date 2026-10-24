import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_compress/video_compress.dart' as vc;
import 'package:video_player/video_player.dart';

import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/premium.dart';
import 'image_editor_screen.dart' show ViewOnceIcon;

/// What the video screen hands back: the (trimmed / smaller) file to send.
class VideoSendResult {
  VideoSendResult(this.path, this.seconds, this.viewOnce);
  final String path;
  final int seconds;
  final bool viewOnce;
}

/// Before sending a video: watch it, cut the start / end, pick a smaller quality.
class VideoSendScreen extends StatefulWidget {
  const VideoSendScreen({super.key, required this.path, this.allowViewOnce = true});
  final String path;
  final bool allowViewOnce;

  @override
  State<VideoSendScreen> createState() => _VideoSendScreenState();
}

class _VideoSendScreenState extends State<VideoSendScreen> {
  // (id, label, share of the original size — a rough guess for the size shown)
  static const _qualities = [
    ('original', 'Original', 1.0),
    ('hd', 'HD 720p', 0.45),
    ('sd', 'SD 480p', 0.22),
  ];

  late final VideoPlayerController _c = VideoPlayerController.file(File(widget.path));
  int _size = 0;
  double _total = 0; // seconds
  RangeValues _range = const RangeValues(0, 1);
  String _quality = 'hd';
  bool _viewOnce = false;
  bool _ready = false;
  double? _progress; // compressing 0..1

  // The plugin's progress stream can be listened to only once per app run, so one listener feeds this.
  static final _compressProgress = ValueNotifier<double>(0);
  static bool _listening = false;

  void _onProgress() {
    if (mounted && _progress != null) setState(() => _progress = _compressProgress.value);
  }

  @override
  void initState() {
    super.initState();
    _size = File(widget.path).lengthSync();
    _c.initialize().then((_) {
      if (!mounted) return;
      _total = _c.value.duration.inMilliseconds / 1000;
      setState(() {
        _range = RangeValues(0, _total <= 0 ? 1 : _total);
        _ready = true;
        // small videos don't need shrinking
        if (_size < 8 << 20) _quality = 'original';
      });
      _c.addListener(_loop);
      _c.play();
    }).catchError((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  /// Plays only the chosen part, over and over.
  void _loop() {
    if (!_c.value.isInitialized || !_c.value.isPlaying) return;
    final pos = _c.value.position.inMilliseconds / 1000;
    if (pos >= _range.end - 0.05 || pos < _range.start - 0.3) _c.seekTo(Duration(milliseconds: (_range.start * 1000).round()));
  }

  @override
  void dispose() {
    _compressProgress.removeListener(_onProgress);
    if (_progress != null) vc.VideoCompress.cancelCompression().catchError((_) {});
    _c.removeListener(_loop);
    _c.dispose();
    super.dispose();
  }

  bool get _trimmed => _total > 0 && (_range.start > 0.2 || _range.end < _total - 0.2);
  int get _seconds => (_trimmed ? _range.end - _range.start : _total).round().clamp(1, 1 << 30);

  int get _estimate {
    final share = _total > 0 ? (_range.end - _range.start) / _total : 1.0;
    final q = _qualities.firstWhere((x) => x.$1 == _quality).$3;
    return (_size * share * q).round();
  }

  Future<void> _send() async {
    if (_quality == 'original' && !_trimmed) {
      Navigator.pop(context, VideoSendResult(widget.path, _seconds, _viewOnce));
      return;
    }
    _c.pause();
    setState(() => _progress = 0);
    if (!_listening) {
      _listening = true;
      vc.VideoCompress.compressProgress$.subscribe((p) => _compressProgress.value = (p / 100).clamp(0.0, 1.0));
    }
    _compressProgress.value = 0;
    _compressProgress.addListener(_onProgress);
    try {
      final info = await vc.VideoCompress.compressVideo(
        widget.path,
        quality: switch (_quality) {
          'sd' => vc.VideoQuality.Res640x480Quality,
          'hd' => vc.VideoQuality.Res1280x720Quality,
          _ => vc.VideoQuality.HighestQuality,
        },
        startTime: _trimmed ? _range.start.floor() : null,
        duration: _trimmed ? (_range.end - _range.start.floor()).ceil() : null,
        includeAudio: true,
      );
      if (!mounted) return;
      final out = info?.path;
      if (info?.isCancel == true || out == null || !File(out).existsSync()) {
        setState(() => _progress = null);
        showInfo(context, 'Could not prepare this video');
        return;
      }
      Navigator.pop(context, VideoSendResult(out, _seconds, _viewOnce));
    } catch (_) {
      if (!mounted) return;
      setState(() => _progress = null);
      showInfo(context, 'Could not prepare this video — sending it as it is');
      Navigator.pop(context, VideoSendResult(widget.path, _total.round(), _viewOnce));
    } finally {
      _compressProgress.removeListener(_onProgress);
    }
  }

  String _t(double s) => duration(s.round());

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Send video', style: TextStyle(color: Colors.white)),
        actions: [
          if (widget.allowViewOnce)
            IconButton(
              tooltip: _viewOnce ? 'View once: on' : 'View once: off',
              onPressed: busy ? null : () => setState(() => _viewOnce = !_viewOnce),
              icon: ViewOnceIcon(on: _viewOnce),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Center(
              child: !_ready
                  ? const CircularProgressIndicator(color: Colors.white)
                  : _c.value.isInitialized
                      ? GestureDetector(
                          onTap: () => setState(() => _c.value.isPlaying ? _c.pause() : _c.play()),
                          child: Stack(alignment: Alignment.center, children: [
                            AspectRatio(aspectRatio: _c.value.aspectRatio, child: VideoPlayer(_c)),
                            if (!_c.value.isPlaying && !busy) const Icon(Icons.play_circle_fill_rounded, color: Colors.white70, size: 64),
                          ]),
                        )
                      : const Text('Preview not available', style: TextStyle(color: Colors.white70)),
            ),
          ),
          if (_total > 1) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                const Icon(Icons.content_cut_rounded, color: Colors.white70, size: 18),
                const SizedBox(width: 8),
                Text('${_t(_range.start)} – ${_t(_range.end)}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(_trimmed ? '${_t(_range.end - _range.start)} of ${_t(_total)}' : _t(_total), style: const TextStyle(color: Colors.white70)),
              ]),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(activeTrackColor: Brand.primary, inactiveTrackColor: Colors.white24, thumbColor: Colors.white),
              child: RangeSlider(
                values: _range,
                min: 0,
                max: _total,
                onChanged: busy
                    ? null
                    : (r) {
                        if (r.end - r.start < 1) return;
                        final movedStart = r.start != _range.start;
                        setState(() => _range = r);
                        _c.seekTo(Duration(milliseconds: ((movedStart ? r.start : r.end - 1) * 1000).round()));
                      },
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(spacing: 8, children: [
              for (final (id, label, _) in _qualities)
                ChoiceChip(
                  label: Text(label),
                  selected: _quality == id,
                  onSelected: busy ? null : (_) => setState(() => _quality = id),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              _quality == 'original' && !_trimmed ? fileSize(_size) : '${fileSize(_size)} → about ${fileSize(_estimate)}',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: busy
                ? Column(children: [
                    LinearProgressIndicator(value: _progress == 0 ? null : _progress, color: Brand.primary, backgroundColor: Colors.white12),
                    const SizedBox(height: 8),
                    Text('Preparing video… ${((_progress ?? 0) * 100).round()}%', style: const TextStyle(color: Colors.white70)),
                  ])
                : AuroraButton(label: 'Send', icon: Icons.send_rounded, onPressed: _ready ? _send : null),
          ),
        ]),
      ),
    );
  }
}
