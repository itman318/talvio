import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import '../theme/brand.dart';
import '../theme/chat_theme.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../config.dart';
import '../core/prefs.dart';
import '../core/screen_guard.dart';
import '../core/services.dart';
import '../core/voice_playback.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';

/// Resolves a message's media to a local file (local upload path, cache, or download).
Future<File> resolveMediaFile(BuildContext context, Message m) {
  if (m.localFilePath != null && File(m.localFilePath!).existsSync()) return Future.value(File(m.localFilePath!));
  return context.read<AppServices>().media.get(m.media!);
}

/// Downloads a video / file in the background when the auto-download setting allows it.
/// Returns true when the file is (now) on the phone.
Future<bool> autoFetchMedia(BuildContext context, Message m, String kind) async {
  final media = m.media;
  if (media == null || media.id == 0) return false;
  final services = context.read<AppServices>();
  final prefs = context.read<AppPrefs>();
  if (m.localFilePath != null && File(m.localFilePath!).existsSync()) return true;
  if (await services.media.cached(media) != null) return true;
  final limit = kind == 'videos' ? 100 << 20 : 50 << 20;
  if (media.size > limit || !await prefs.autoDownload(kind)) return false;
  try {
    await services.media.get(media);
    return true;
  } catch (_) {
    return false;
  }
}

/// The inline thumb (≈40 px) blurred ONCE and kept: drawing it costs nothing per frame
/// (a live blur filter on every photo made chats slow to open and scroll).
final Map<int, Uint8List> _blurredThumbs = {};

Uint8List? blurredThumb(MediaInfo m) {
  final hit = _blurredThumbs[m.id];
  if (hit != null) return hit;
  final raw = m.thumbBytes;
  if (raw == null) return null;
  try {
    final src = img.decodeImage(raw);
    if (src == null) return raw;
    final out = Uint8List.fromList(img.encodePng(img.gaussianBlur(src, radius: 2), level: 1));
    if (_blurredThumbs.length > 400) _blurredThumbs.remove(_blurredThumbs.keys.first);
    return _blurredThumbs[m.id] = out;
  } catch (_) {
    return raw;
  }
}

class MessageImage extends StatefulWidget {
  const MessageImage({super.key, required this.message, this.maxWidth = 260});

  final Message message;
  final double maxWidth;

  @override
  State<MessageImage> createState() => _MessageImageState();
}

/// photo bubble: the tiny inline thumb shows blurred at once, the bubble-size
/// preview (a few dozen KB) fades in over it, and the full photo is fetched only when opened.
class _MessageImageState extends State<MessageImage> {
  File? _shown;
  bool _isFull = false;
  bool _loading = false;
  bool _failed = false;
  bool _tapToLoad = false;
  final _progress = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _decide();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MessageImage old) {
    super.didUpdateWidget(old);
    // the upload finished: the message got its server media id
    if (old.message.media?.id != widget.message.media?.id && _shown == null) _decide();
  }

  bool get _hasLocal {
    final p = widget.message.localFilePath;
    return p != null && File(p).existsSync();
  }

  /// Own uploads and cached photos show at once; others follow the auto-download setting.
  Future<void> _decide() async {
    final msg = widget.message;
    if (_hasLocal) {
      setState(() {
        _shown = File(msg.localFilePath!);
        _isFull = true;
      });
      return;
    }
    final m = msg.media;
    if (m == null || m.id == 0) return;
    final services = context.read<AppServices>();
    final full = await services.media.cached(m);
    final have = full ?? await services.media.cachedPreview(m);
    if (!mounted) return;
    if (have != null) {
      setState(() {
        _shown = have;
        _isFull = full != null;
      });
      return;
    }
    final auto = await context.read<AppPrefs>().autoDownloadPhotos();
    if (!mounted) return;
    if (auto) {
      _load();
    } else {
      setState(() => _tapToLoad = true);
    }
  }

  Future<void> _load() async {
    final m = widget.message.media;
    if (m == null || _loading) return;
    setState(() {
      _tapToLoad = false;
      _failed = false;
      _loading = true;
    });
    try {
      final media = context.read<AppServices>().media;
      final f = await media.preview(m, onProgress: (x) {
        if (mounted && (x - _progress.value).abs() > 0.02) _progress.value = x;
      });
      final full = await media.cached(m);
      if (!mounted) return;
      setState(() {
        _shown = f;
        _isFull = full != null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  void _open() {
    final f = _shown;
    if (f == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FullImageScreen(file: f, full: _isFull ? null : resolveMediaFile(context, widget.message)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message.media!;
    final ratio = (m.width != null && m.height != null && m.height! > 0) ? m.width! / m.height! : 4 / 3;
    final w = widget.maxWidth;
    final h = (w / ratio).clamp(120.0, 360.0);
    final thumb = _shown == null ? blurredThumb(m) : null;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return SizedBox(
      width: w,
      height: h,
      child: Stack(fit: StackFit.expand, children: [
        // 1) instant: the blurred inline thumb (or a soft placeholder) — gone once the photo is there
        if (thumb != null)
          Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium)
        else if (_shown == null)
          const ColoredBox(color: Color(0x1F000000)),
        // 2) the real picture fades in over it; decode only the pixels the bubble shows
        if (_shown != null)
          GestureDetector(
            onTap: _open,
            child: Image.file(
              _shown!,
              key: ValueKey(_shown!.path),
              fit: BoxFit.cover,
              width: w,
              height: h,
              gaplessPlayback: true,
              cacheWidth: (math.max(w, h * ratio) * dpr).round(),
              frameBuilder: (ctx, child, frame, sync) => sync
                  ? child
                  : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 180), child: child),
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          )
        else if (_tapToLoad || _failed)
          InkWell(
            onTap: _load,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_failed ? Icons.refresh_rounded : Icons.download_rounded, color: Colors.white, size: 20),
                  const SizedBox(width: 6),
                  Text(_failed ? 'Retry' : fileSize(m.size), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          )
        else
          Center(
            child: SizedBox(
              width: 38,
              height: 38,
              child: DecoratedBox(
                decoration: const BoxDecoration(color: Colors.black38, shape: BoxShape.circle),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  // real progress once bytes arrive (a spinning ring before that)
                  child: ValueListenableBuilder<double>(
                    valueListenable: _progress,
                    builder: (_, v, __) => CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white, value: v > 0 ? v : null),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Saves a photo or video into the phone's gallery (a "Hushavia" album). Returns a message to show.
Future<String> saveToGallery(File file, {bool video = false}) async {
  try {
    if (!await Gal.hasAccess(toAlbum: true) && !await Gal.requestAccess(toAlbum: true)) return 'Allow Hushavia to add to your gallery first';
    if (video) {
      await Gal.putVideo(file.path, album: 'Hushavia');
    } else {
      await Gal.putImage(file.path, album: 'Hushavia');
    }
    return video ? '⬇️ Video saved to your gallery' : '⬇️ Photo saved to your gallery';
  } catch (_) {
    return 'Couldn’t save it — check storage space and try again';
  }
}

class FullImageScreen extends StatefulWidget {
  const FullImageScreen({super.key, required this.file, this.full, this.canSave});
  final File file;
  /// The full-size photo while [file] is only the preview: swapped in when it arrives.
  final Future<File>? full;
  final bool? canSave; // null: allowed unless a protected chat is open

  @override
  State<FullImageScreen> createState() => _FullImageScreenState();
}

class _FullImageScreenState extends State<FullImageScreen> {
  late File _file = widget.file;
  bool _loadingFull = false;

  @override
  void initState() {
    super.initState();
    final full = widget.full;
    if (full != null) {
      _loadingFull = true;
      full.then((f) {
        if (mounted) {
          setState(() {
            _file = f;
            _loadingFull = false;
          });
        }
      }).catchError((Object _) {
        if (mounted) setState(() => _loadingFull = false);
      });
    }
  }

  Future<void> _save() async {
    var f = _file;
    if (_loadingFull && widget.full != null) {
      showInfo(context, 'Getting the full-quality photo…');
      try {
        f = await widget.full!;
      } catch (_) {}
    }
    final msg = await saveToGallery(f);
    if (mounted) showInfo(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        bottom: _loadingFull
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2, backgroundColor: Colors.transparent))
            : null,
        actions: [
          if (widget.canSave ?? ScreenGuard.protectedOpen == 0)
            IconButton(tooltip: 'Save to gallery', icon: const Icon(Icons.download_rounded), onPressed: _save),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.file(_file, key: ValueKey(_file.path), gaplessPlayback: true),
        ),
      ),
    );
  }
}

class MessageVideo extends StatefulWidget {
  const MessageVideo({super.key, required this.message, this.isMine = false});
  final Message message;
  final bool isMine;

  @override
  State<MessageVideo> createState() => _MessageVideoState();
}

/// Video bubble: the poster frame shows at once (blurred thumb → sharp poster), it plays by streaming
/// on tap — no waiting for the whole file — and downloads in the background when the setting allows.
class _MessageVideoState extends State<MessageVideo> {
  File? _poster;
  bool _downloading = false;
  bool _onPhone = false;

  @override
  void initState() {
    super.initState();
    final message = widget.message;
    final m = message.media;
    if (message.isLocal || m == null) return;
    final services = context.read<AppServices>();
    if (m.hasPreview) {
      services.media.preview(m).then((f) {
        if (mounted) setState(() => _poster = f);
      }).catchError((Object _) {});
    }
    services.media.cached(m).then((f) {
      if (!mounted) return;
      if (f != null) {
        setState(() => _onPhone = true);
        return;
      }
      setState(() => _downloading = true);
      autoFetchMedia(context, message, 'videos').then((ok) {
        if (mounted) {
          setState(() {
            _downloading = false;
            _onPhone = ok;
          });
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final m = message.media!;
    final ratio = (m.width != null && m.height != null && m.height! > 0) ? m.width! / m.height! : 16 / 9;
    const w = 240.0;
    final h = (w / ratio).clamp(135.0, 320.0);
    final thumb = blurredThumb(m);
    return InkWell(
      onTap: message.isLocal ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoScreen(message: message))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(fit: StackFit.expand, children: [
            const ColoredBox(color: Colors.black87),
            if (thumb != null && _poster == null) Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium),
            if (_poster != null)
              Image.file(
                _poster!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: (w * MediaQuery.devicePixelRatioOf(context)).round(),
                frameBuilder: (ctx, child, frame, sync) =>
                    sync ? child : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 180), child: child),
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            Center(
              child: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36),
              ),
            ),
            if (_downloading)
              const Positioned(right: 10, top: 10, child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))),
            if (widget.isMine && !message.isLocal)
              Positioned(right: 8, bottom: 6, child: PlayedMark(played: message.played, video: true, onDark: true)),
            Positioned(
              left: 8,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  [
                    if (m.duration != null) duration(m.duration!),
                    if (!_onPhone) fileSize(m.size),
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ]),
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
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
    // someone else's video opened: the sender sees "Watched"
    final m = widget.message;
    if (!m.isLocal && m.senderId != null && m.senderId != context.read<ChatStore>().myId && !PlayedVoices.played(m.id)) {
      PlayedVoices.mark(m.id);
      context.read<AppServices>().api.post('/messages/${m.id}/played').catchError((_) => null);
    }
  }

  /// On the phone already → plays the file. Otherwise streams it from the server (starts in a
  /// second); if streaming fails, downloads it and plays the file.
  Future<void> _load() async {
    final msg = widget.message;
    final services = context.read<AppServices>();
    VideoPlayerController? c;
    try {
      final local = msg.localFilePath != null && File(msg.localFilePath!).existsSync() ? File(msg.localFilePath!) : null;
      final file = local ?? (msg.media == null ? null : await services.media.cached(msg.media!));
      if (file != null) {
        c = VideoPlayerController.file(file);
        await c.initialize();
      } else {
        try {
          c = VideoPlayerController.networkUrl(
            Uri.parse(AppConfig.absolute(msg.media!.url)),
            httpHeaders: services.api.authHeaders,
          );
          await c.initialize().timeout(const Duration(seconds: 20));
        } catch (_) {
          await c?.dispose();
          if (!mounted) return;
          c = VideoPlayerController.file(await resolveMediaFile(context, msg));
          await c.initialize();
        }
      }
      if (!mounted) {
        await c.dispose();
        return;
      }
      c.addListener(_tick);
      await c.play();
      setState(() => _c = c);
    } catch (_) {
      await c?.dispose();
      if (mounted) setState(() => _error = 'Could not play this video');
    }
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    showInfo(context, 'Saving the video…');
    try {
      final f = await resolveMediaFile(context, widget.message);
      final msg = await saveToGallery(f, video: true);
      if (mounted) showInfo(context, msg);
    } catch (_) {
      if (mounted) showInfo(context, 'Couldn’t save the video');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _c?.removeListener(_tick);
    _c?.dispose();
    super.dispose();
  }

  String _time(Duration d) => duration(d.inSeconds);

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final thumb = widget.message.media == null ? null : blurredThumb(widget.message.media!);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, actions: [
        if (ScreenGuard.protectedOpen == 0 && !widget.message.isLocal)
          IconButton(
            tooltip: 'Save to gallery',
            icon: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.download_rounded),
            onPressed: _save,
          ),
      ]),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white))
            : c == null
                ? Stack(alignment: Alignment.center, children: [
                    if (thumb != null) Image.memory(thumb, fit: BoxFit.contain, width: double.infinity, filterQuality: FilterQuality.medium),
                    const CircularProgressIndicator(color: Colors.white),
                  ])
                : GestureDetector(
                    onTap: () => c.value.isPlaying ? c.pause() : c.play(),
                    child: AspectRatio(
                      aspectRatio: c.value.aspectRatio,
                      child: Stack(alignment: Alignment.center, children: [
                        VideoPlayer(c),
                        if (c.value.isBuffering) const CircularProgressIndicator(color: Colors.white70),
                        if (!c.value.isPlaying && !c.value.isBuffering)
                          Container(
                            width: 64,
                            height: 64,
                            decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                            child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 44),
                          ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              child: Row(children: [
                                Text(_time(c.value.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
                                const Spacer(),
                                Text(_time(c.value.duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              ]),
                            ),
                            VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.fromLTRB(10, 6, 10, 10)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
      ),
    );
  }
}

/// Voice message player: loudness bars you can tap or drag to seek, 1× / 1.5× / 2× speed.
/// Playback itself lives in [VoicePlayback] (one at a time, auto-plays the next, mini player, earpiece).
class VoicePlayer extends StatefulWidget {
  const VoicePlayer({super.key, required this.message, required this.color, this.isMine = false, this.title = ''});
  final Message message;
  final Color color;
  final bool isMine;
  final String title; // shown in the mini player

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  double? _drag; // 0..1 while the finger is on the waveform
  late final List<double> _bars = voiceBars(widget.message, 42);

  @override
  void initState() {
    super.initState();
    PlayedVoices.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _toggle(VoicePlayback vp) async {
    try {
      await vp.toggle(widget.message, title: widget.title);
    } catch (_) {
      if (mounted) showInfo(context, 'Could not load the voice message');
    }
  }

  Future<void> _seek(VoicePlayback vp, double f) async {
    if (!vp.isCurrent(widget.message)) {
      await _toggle(vp);
    }
    await vp.seekFraction(f);
  }

  @override
  Widget build(BuildContext context) {
    final vp = context.watch<VoicePlayback>();
    final mine = vp.isCurrent(widget.message);
    final playing = mine && vp.playing;
    final loading = mine && vp.loading;
    final total = widget.message.media?.duration ?? 0;
    final c = widget.color;
    final local = widget.message.isLocal;
    final fresh = !widget.isMine && !local && !PlayedVoices.played(widget.message.id);
    return SizedBox(
      width: 248,
      child: StreamBuilder<Duration>(
        stream: mine ? vp.player.positionStream : const Stream<Duration>.empty(),
        builder: (ctx, snap) {
          final pos = mine ? (snap.data ?? Duration.zero) : Duration.zero;
          final len = mine && vp.player.duration != null ? vp.player.duration!.inMilliseconds : total * 1000;
          final frac = _drag ?? (len > 0 ? (pos.inMilliseconds / len).clamp(0.0, 1.0) : 0.0);
          final started = mine && (playing || pos > Duration.zero);
          return Row(children: [
            // play button with a ring that fills as it plays
            GestureDetector(
              onTap: local ? null : () => _toggle(vp),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Stack(alignment: Alignment.center, children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.isMine ? MineInk.fill(context) : null,
                      gradient: widget.isMine ? null : Brand.aurora,
                      boxShadow: widget.isMine ? null : [BoxShadow(color: Brand.rose.withValues(alpha: 0.28), blurRadius: 10, offset: const Offset(0, 3))],
                    ),
                    child: loading || local
                        ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                        : AnimatedSwitcher(
                            duration: const Duration(milliseconds: 150),
                            transitionBuilder: (ch, a) => ScaleTransition(scale: a, child: ch),
                            child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(playing), color: Colors.white, size: 28),
                          ),
                  ),
                  if (started)
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: CircularProgressIndicator(
                        value: frac,
                        strokeWidth: 2.2,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation(widget.isMine ? MineInk.line(context) : Brand.rose),
                      ),
                    ),
                ]),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                LayoutBuilder(
                  builder: (ctx, box) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: local ? null : (d) => _seek(vp, d.localPosition.dx / box.maxWidth),
                    onHorizontalDragStart: local ? null : (d) => setState(() => _drag = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)),
                    onHorizontalDragUpdate: local ? null : (d) => setState(() => _drag = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)),
                    onHorizontalDragEnd: local
                        ? null
                        : (_) {
                            final f = _drag ?? 0;
                            setState(() => _drag = null);
                            _seek(vp, f);
                          },
                    child: SizedBox(
                      height: 32,
                      width: box.maxWidth,
                      child: CustomPaint(
                        painter: VoiceWavePainter(_bars, frac, played: c, rest: c.withValues(alpha: 0.3), knob: started || _drag != null),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Row(children: [
                  Text(
                    started ? '${duration(pos.inSeconds)} / ${duration(total > 0 ? total : (len ~/ 1000))}' : duration(total),
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c.withValues(alpha: 0.9), fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                  if (fresh) ...[
                    const SizedBox(width: 6),
                    Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                  ],
                  if (widget.isMine && !local) ...[
                    const SizedBox(width: 6),
                    PlayedMark(played: widget.message.played, video: false, color: c),
                  ],
                  if (mine && vp.earpiece) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.hearing_rounded, size: 13, color: c),
                  ],
                  const Spacer(),
                  // speed only matters once it plays
                  if (!local && started)
                    GestureDetector(
                      onTap: vp.cycleSpeed,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: vp.speed == 1.0 ? c.withValues(alpha: 0.14) : c,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(speedLabel(vp.speed),
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: vp.speed == 1.0 ? c : (widget.isMine && !softMineOf(context) ? Brand.ink : Colors.white))),
                      ),
                    ),
                ]),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

/// An audio file (mp3, m4a…): plays right in the chat, with the title, a seek bar and the time.
class AudioFilePlayer extends StatelessWidget {
  const AudioFilePlayer({super.key, required this.message, required this.color, this.isMine = false});
  final Message message;
  final Color color;
  final bool isMine;

  static bool isAudio(Message m) {
    return m.type == 'file' && m.media?.isAudio == true;
  }

  @override
  Widget build(BuildContext context) {
    final vp = context.watch<VoicePlayback>();
    final md = message.media!;
    final mine = vp.isCurrent(message);
    final playing = mine && vp.playing;
    final loading = mine && vp.loading;
    final name = md.audioTitle;
    final c = color;
    return SizedBox(
      width: 250,
      child: StreamBuilder<Duration>(
        stream: mine ? vp.player.positionStream : const Stream<Duration>.empty(),
        builder: (ctx, snap) {
          final pos = mine ? (snap.data ?? Duration.zero) : Duration.zero;
          final lenMs = mine && vp.player.duration != null ? vp.player.duration!.inMilliseconds : (md.duration ?? 0) * 1000;
          final frac = lenMs > 0 ? (pos.inMilliseconds / lenMs).clamp(0.0, 1.0) : 0.0;
          return Row(children: [
            GestureDetector(
              onTap: message.isLocal
                  ? null
                  : () => vp.toggle(message, title: name).catchError((_) {
                        if (context.mounted) showInfo(context, 'Could not play this file');
                      }),
              child: Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: isMine ? null : const LinearGradient(colors: [Color(0xFFFF8A65), Color(0xFFE0417A)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  color: isMine ? MineInk.fill(context) : null,
                ),
                child: loading
                    ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                    : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 30),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Icon(Icons.music_note_rounded, size: 15, color: c),
                  const SizedBox(width: 3),
                  Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: isMine ? MineInk.text(context) : null))),
                ]),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LayoutBuilder(
                    builder: (ctx, box) => GestureDetector(
                      onTapUp: mine ? (d) => vp.seekFraction(d.localPosition.dx / box.maxWidth) : null,
                      child: LinearProgressIndicator(value: frac, minHeight: 4, backgroundColor: c.withValues(alpha: 0.2), valueColor: AlwaysStoppedAnimation(c)),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  Flexible(
                    child: Text(
                      mine && pos > Duration.zero
                          ? '${duration(pos.inSeconds)} / ${duration(lenMs ~/ 1000)}'
                          : '${md.duration != null ? '${duration(md.duration!)} · ' : ''}${fileSize(md.size)}',
                      maxLines: 1,
                      style: TextStyle(fontSize: 11.5, color: isMine ? MineInk.muted(context) : Brand.muted, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                  if (isMine && !message.isLocal) ...[const SizedBox(width: 6), PlayedMark(played: message.played, video: false, color: MineInk.muted(context))],
                ]),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

String speedLabel(double s) => s == 1.0 ? '1×' : (s == 1.5 ? '1.5×' : '2×');

/// Bars for a voice message: the recorded loudness (meta.waveform), or a calm generated shape.
List<double> voiceBars(Message m, int n) {
  final w = m.meta?['waveform'];
  if (w is List && w.length >= 8) {
    final raw = w.map((e) => ((e as num?)?.toDouble() ?? 0) / 31).toList();
    return resampleBars(raw, n);
  }
  final r = math.Random(m.id.abs() + 7);
  return List.generate(n, (i) => 0.25 + 0.55 * (0.5 + 0.5 * math.sin(i * 0.55 + r.nextDouble())) * (0.6 + 0.4 * r.nextDouble()));
}

List<double> resampleBars(List<double> src, int n) {
  if (src.isEmpty) return List.filled(n, 0.1);
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

/// Rounded loudness bars; the played part is drawn in full colour.
class VoiceWavePainter extends CustomPainter {
  VoiceWavePainter(this.bars, this.progress, {required this.played, required this.rest, this.knob = false});
  final List<double> bars;
  final double progress;
  final Color played;
  final Color rest;
  final bool knob; // a small playhead dot while playing or dragging

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
    if (knob) {
      final x = (size.width * progress).clamp(4.0, size.width - 4.0);
      canvas.drawCircle(Offset(x, size.height / 2), 5, Paint()..color = played);
      canvas.drawCircle(Offset(x, size.height / 2), 2.2, Paint()..color = rest.withValues(alpha: 1).computeLuminance() > 0.5 ? Colors.black26 : Colors.white70);
    }
  }

  @override
  bool shouldRepaint(covariant VoiceWavePainter old) => old.progress != progress || old.played != played || old.bars != bars || old.knob != knob;
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
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    if (!widget.message.isLocal) {
      autoFetchMedia(context, widget.message, 'files').then((ok) {
        if (mounted && ok) setState(() => _ready = true);
      });
    }
  }

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
                  : Icon(_ready || widget.message.isLocal ? Icons.insert_drive_file : Icons.download_rounded, color: Colors.white),
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


/// "Listened" / "Watched" on my own voice, audio and video messages (the other side played it).
class PlayedMark extends StatelessWidget {
  const PlayedMark({super.key, required this.played, required this.video, this.onDark = false, this.color});
  final bool played;
  final bool video; // eye (watched) instead of headphones (listened)
  final bool onDark; // drawn over a picture: white text on a dark pill
  final Color? color; // text colour inside a bubble

  @override
  Widget build(BuildContext context) {
    final darkBubble = onDark || (color != null && !softMineOf(context));
    final darkTheme = Theme.of(context).brightness == Brightness.dark;
    final dark = darkBubble || (color == null && darkTheme);
    final success = dark ? const Color(0xFFB8F7DE) : const Color(0xFF176B50);
    final label = played ? (video ? 'Watched' : 'Listened') : (video ? 'Not watched' : 'Not played');
    final icon = video ? (played ? Icons.visibility_rounded : Icons.visibility_outlined) : (played ? Icons.headphones_rounded : Icons.headset_off_rounded);
    final fg = played ? success : (onDark ? Colors.white70 : color ?? (darkTheme ? Colors.white70 : Brand.muted));
    return Tooltip(
      message: played ? (video ? 'They watched it' : 'They listened to it') : (video ? 'Not watched yet' : 'Not listened to yet'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        decoration: BoxDecoration(
          color: onDark ? Colors.black.withValues(alpha: 0.65) : (played ? (dark ? const Color(0xFF174C40) : const Color(0xFFDDF4E8)) : Colors.transparent),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
        ]),
      ),
    );
  }
}
