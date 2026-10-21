import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
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
                color: Colors.black26,
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
      if (!mounted) return c.dispose();
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

class VoicePlayer extends StatefulWidget {
  const VoicePlayer({super.key, required this.message, required this.color});
  final Message message;
  final Color color;

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  final _player = AudioPlayer();
  bool _loading = false;
  bool _ready = false;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
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
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_player.playing) return _player.pause();
    if (!_ready) {
      setState(() => _loading = true);
      try {
        final f = await resolveMediaFile(context, widget.message);
        await _player.setFilePath(f.path);
        _ready = true;
      } catch (_) {
        if (mounted) showInfo(context, 'Could not load the voice message');
        return;
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
    _player.play();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.message.media?.duration ?? _player.duration?.inSeconds ?? 0;
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          IconButton(
            onPressed: widget.message.isLocal ? null : _toggle,
            icon: _loading
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_player.playing ? Icons.pause_circle_filled : Icons.play_circle_fill, size: 38, color: widget.color),
          ),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (ctx, snap) {
                final pos = snap.data ?? Duration.zero;
                final frac = total > 0 ? (pos.inMilliseconds / (total * 1000)).clamp(0.0, 1.0) : 0.0;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: frac, color: widget.color, backgroundColor: widget.color.withAlpha(50)),
                    const SizedBox(height: 4),
                    Text(
                      _player.playing || pos > Duration.zero ? duration(pos.inSeconds) : duration(total),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
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
