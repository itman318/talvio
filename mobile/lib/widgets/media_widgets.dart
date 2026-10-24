import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/brand.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../core/prefs.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../utils/format.dart';

/// Resolves a message's media to a local file (local upload path, cache, or download).
Future<File> resolveMediaFile(BuildContext context, Message m) {
  if (m.localFilePath != null && File(m.localFilePath!).existsSync()) return Future.value(File(m.localFilePath!));
  return context.read<AppServices>().media.get(m.media!);
}

class MessageImage extends StatefulWidget {
  const MessageImage({super.key, required this.message, this.maxWidth = 260});

  final Message message;
  final double maxWidth;

  @override
  State<MessageImage> createState() => _MessageImageState();
}

class _MessageImageState extends State<MessageImage> {
  Future<File>? _file;
  bool _tapToLoad = false;

  @override
  void initState() {
    super.initState();
    _decide();
  }

  /// Own uploads and cached photos show at once; others follow the auto-download setting.
  Future<void> _decide() async {
    final msg = widget.message;
    final services = context.read<AppServices>();
    final prefs = context.read<AppPrefs>();
    final local = msg.localFilePath != null && File(msg.localFilePath!).existsSync();
    final cached = local || msg.media == null || msg.media!.id == 0 ? null : await services.media.cached(msg.media!);
    final auto = local || cached != null || await prefs.autoDownloadPhotos();
    if (!mounted) return;
    setState(() {
      if (auto) {
        _file = resolveMediaFile(context, msg);
      } else {
        _tapToLoad = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message.media!;
    final ratio = (m.width != null && m.height != null && m.height! > 0) ? m.width! / m.height! : 4 / 3;
    final w = widget.maxWidth;
    final h = (w / ratio).clamp(120.0, 360.0);
    return SizedBox(
      width: w,
      height: h,
      child: _tapToLoad
          ? InkWell(
              onTap: () => setState(() {
                _tapToLoad = false;
                _file = resolveMediaFile(context, widget.message);
              }),
              child: Container(
                color: Brand.faint,
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.download_rounded, color: Colors.white, size: 36),
                    Text(fileSize(m.size), style: const TextStyle(color: Colors.white)),
                  ]),
                ),
              ),
            )
          : FutureBuilder<File>(
        future: _file,
        builder: (ctx, snap) {
          if (snap.hasData) {
            return GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FullImageScreen(file: snap.data!))),
              child: Image.file(snap.data!, fit: BoxFit.cover, width: w, height: h),
            );
          }
          if (snap.hasError) {
            return InkWell(
              onTap: () => setState(() => _file = resolveMediaFile(context, widget.message)),
              child: const Center(child: Icon(Icons.refresh)),
            );
          }
          return Container(color: Colors.black12, child: const Center(child: CircularProgressIndicator(strokeWidth: 2)));
        },
      ),
    );
  }
}

class FullImageScreen extends StatelessWidget {
  const FullImageScreen({super.key, required this.file});
  final File file;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(child: InteractiveViewer(maxScale: 5, child: Image.file(file))),
    );
  }
}

class MessageVideo extends StatelessWidget {
  const MessageVideo({super.key, required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    final m = message.media!;
    return InkWell(
      onTap: message.isLocal
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoScreen(message: message))),
      child: Container(
        width: 240,
        height: 150,
        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10)),
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.play_circle_fill, color: Colors.white, size: 52),
            Positioned(
              left: 8,
              bottom: 6,
              child: Text(
                [if (m.duration != null) duration(m.duration!), fileSize(m.size)].join(' · '),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.message});
  final Message message;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  VideoPlayerController? _c;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final f = await resolveMediaFile(context, widget.message);
      final c = VideoPlayerController.file(f);
      await c.initialize();
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _c = c);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not play this video');
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white))
            : c == null
                ? const CircularProgressIndicator()
                : GestureDetector(
                    onTap: () {
                      c.value.isPlaying ? c.pause() : c.play();
                      setState(() {});
                    },
                    child: AspectRatio(
                      aspectRatio: c.value.aspectRatio,
                      child: Stack(alignment: Alignment.bottomCenter, children: [
                        VideoPlayer(c),
                        VideoProgressIndicator(c, allowScrubbing: true),
                      ]),
                    ),
                  ),
      ),
    );
  }
}

/// Voice message player: loudness bars you can tap or drag to seek, 1× / 1.5× / 2× speed,
/// one voice message plays at a time, and a dot marks voice messages you haven't played yet.
class VoicePlayer extends StatefulWidget {
  const VoicePlayer({super.key, required this.message, required this.color, this.isMine = false});
  final Message message;
  final Color color;
  final bool isMine;

  /// Playback speed shared by all voice messages (like the big messengers remember it).
  static double speed = 1.0;

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

/// Remembers which voice messages were played (the "new" dot).
class PlayedVoices {
  PlayedVoices._();
  static const _key = 'played_voice_ids';
  static final Set<int> _ids = {};
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final l = (await SharedPreferences.getInstance()).getStringList(_key) ?? const [];
      _ids.addAll(l.map(int.tryParse).whereType<int>());
    } catch (_) {}
  }

  static bool played(int id) => _ids.contains(id);

  static Future<void> mark(int id) async {
    if (!_ids.add(id)) return;
    try {
      final list = _ids.toList();
      await (await SharedPreferences.getInstance()).setStringList(_key, list.sublist(list.length > 600 ? list.length - 600 : 0).map((e) => '$e').toList());
    } catch (_) {}
  }
}

class _VoicePlayerState extends State<VoicePlayer> {
  static _VoicePlayerState? _current; // the one playing now
  final _player = AudioPlayer();
  bool _loading = false;
  bool _ready = false;
  double? _drag; // 0..1 while the finger is on the waveform
  StreamSubscription<PlayerState>? _stateSub;
  late final List<double> _bars = _waveform();

  @override
  void initState() {
    super.initState();
    PlayedVoices.load().then((_) {
      if (mounted) setState(() {});
    });
    _stateSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    if (_current == this) _current = null;
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// Bars from the recording (meta.waveform), or a calm generated shape for older messages.
  List<double> _waveform() {
    final w = widget.message.meta?['waveform'];
    if (w is List && w.length >= 8) {
      final raw = w.map((e) => ((e as num?)?.toDouble() ?? 0) / 31).toList();
      return _resample(raw, 42);
    }
    final r = math.Random(widget.message.id.abs() + 7);
    return List.generate(42, (i) => 0.25 + 0.55 * (0.5 + 0.5 * math.sin(i * 0.55 + r.nextDouble())) * (0.6 + 0.4 * r.nextDouble()));
  }

  static List<double> _resample(List<double> src, int n) {
    if (src.length == n) return src;
    return List.generate(n, (i) {
      final a = (i * src.length / n).floor();
      final b = math.max(a + 1, ((i + 1) * src.length / n).floor());
      var peak = 0.0;
      for (var k = a; k < b && k < src.length; k++) {
        peak = math.max(peak, src[k]);
      }
      return peak;
    });
  }

  Future<bool> _prepare() async {
    if (_ready) return true;
    setState(() => _loading = true);
    try {
      final f = await resolveMediaFile(context, widget.message);
      await _player.setFilePath(f.path);
      _ready = true;
      return true;
    } catch (_) {
      if (mounted) showInfo(context, 'Could not load the voice message');
      return false;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle() async {
    if (_player.playing) return _player.pause();
    if (!await _prepare()) return;
    if (_current != null && _current != this) await _current!._player.pause();
    _current = this;
    await _player.setSpeed(VoicePlayer.speed);
    if (!widget.message.isLocal) PlayedVoices.mark(widget.message.id);
    _player.play();
  }

  Future<void> _seekTo(double frac) async {
    if (!await _prepare()) return;
    final total = _player.duration ?? Duration(seconds: widget.message.media?.duration ?? 0);
    await _player.seek(Duration(milliseconds: (total.inMilliseconds * frac.clamp(0.0, 1.0)).round()));
  }

  void _cycleSpeed() {
    VoicePlayer.speed = VoicePlayer.speed == 1.0 ? 1.5 : (VoicePlayer.speed == 1.5 ? 2.0 : 1.0);
    _player.setSpeed(VoicePlayer.speed);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.message.media?.duration ?? _player.duration?.inSeconds ?? 0;
    final c = widget.color;
    final playing = _player.playing;
    final fresh = !widget.isMine && !widget.message.isLocal && !PlayedVoices.played(widget.message.id);
    return SizedBox(
      width: 236,
      child: Row(children: [
        // play / pause
        GestureDetector(
          onTap: widget.message.isLocal ? null : _toggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.isMine ? Colors.white.withValues(alpha: 0.16) : null,
              gradient: widget.isMine ? null : Brand.aurora,
              boxShadow: widget.isMine ? null : [BoxShadow(color: Brand.rose.withValues(alpha: 0.28), blurRadius: 10, offset: const Offset(0, 3))],
            ),
            child: _loading || widget.message.isLocal
                ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    transitionBuilder: (ch, a) => ScaleTransition(scale: a, child: ch),
                    child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(playing), color: Colors.white, size: 28),
                  ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: StreamBuilder<Duration>(
            stream: _player.positionStream,
            builder: (ctx, snap) {
              final pos = snap.data ?? Duration.zero;
              final frac = _drag ?? (total > 0 ? (pos.inMilliseconds / (total * 1000)).clamp(0.0, 1.0) : 0.0);
              final started = playing || pos > Duration.zero;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                LayoutBuilder(
                  builder: (ctx, box) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: widget.message.isLocal ? null : (d) => _seekTo(d.localPosition.dx / box.maxWidth),
                    onHorizontalDragStart: widget.message.isLocal ? null : (d) => setState(() => _drag = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)),
                    onHorizontalDragUpdate: widget.message.isLocal ? null : (d) => setState(() => _drag = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)),
                    onHorizontalDragEnd: widget.message.isLocal
                        ? null
                        : (_) {
                            final f = _drag ?? 0;
                            setState(() => _drag = null);
                            _seekTo(f);
                          },
                    child: SizedBox(
                      height: 30,
                      width: box.maxWidth,
                      child: CustomPaint(painter: _WavePainter(_bars, frac, played: c, rest: c.withValues(alpha: 0.32))),
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Row(children: [
                  Text(
                    started ? duration(pos.inSeconds) : duration(total),
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c.withValues(alpha: 0.9), fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                  if (fresh) ...[
                    const SizedBox(width: 5),
                    Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                  ],
                  const Spacer(),
                  if (started)
                    GestureDetector(
                      onTap: _cycleSpeed,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                        decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(10)),
                        child: Text(
                          VoicePlayer.speed == 1.0 ? '1×' : (VoicePlayer.speed == 1.5 ? '1.5×' : '2×'),
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: c),
                        ),
                      ),
                    ),
                ]),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

/// Rounded loudness bars; the played part is drawn in full colour.
class _WavePainter extends CustomPainter {
  _WavePainter(this.bars, this.progress, {required this.played, required this.rest});
  final List<double> bars;
  final double progress;
  final Color played;
  final Color rest;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final step = size.width / bars.length;
    final w = math.max(2.0, step * 0.55);
    final on = Paint()..color = played;
    final off = Paint()..color = rest;
    for (var i = 0; i < bars.length; i++) {
      final h = math.max(3.0, size.height * (0.12 + 0.88 * bars[i].clamp(0.0, 1.0)));
      final x = i * step + (step - w) / 2;
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, (size.height - h) / 2, w, h), Radius.circular(w / 2));
      canvas.drawRRect(r, (i + 0.5) / bars.length <= progress ? on : off);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => old.progress != progress || old.played != played || old.bars != bars;
}

class MessageFile extends StatefulWidget {
  const MessageFile({super.key, required this.message, required this.color});
  final Message message;
  final Color color;

  @override
  State<MessageFile> createState() => _MessageFileState();
}

class _MessageFileState extends State<MessageFile> {
  bool _busy = false;

  Future<void> _open() async {
    setState(() => _busy = true);
    try {
      final f = await resolveMediaFile(context, widget.message);
      final r = await OpenFilex.open(f.path);
      if (r.type != ResultType.done && mounted) showInfo(context, 'No app found to open this file');
    } catch (_) {
      if (mounted) showInfo(context, 'Could not download the file');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message.media!;
    return InkWell(
      onTap: widget.message.isLocal || _busy ? null : _open,
      child: SizedBox(
        width: 230,
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: widget.color,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.insert_drive_file, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.name.isEmpty ? 'File' : m.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(fileSize(m.size), style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
