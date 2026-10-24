import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';

/// A view-once photo / video / voice message in the chat.
/// The receiver can open it one time; afterwards it shows "Opened". It can't be forwarded or saved.
class ViewOnceBubble extends StatefulWidget {
  const ViewOnceBubble({super.key, required this.message, required this.isMine, required this.color, required this.myId});
  final Message message;
  final bool isMine;
  final Color color;
  final int? myId;

  @override
  State<ViewOnceBubble> createState() => _ViewOnceBubbleState();
}

class _ViewOnceBubbleState extends State<ViewOnceBubble> {
  bool _busy = false;

  String get _what => switch (widget.message.type) { 'video' => 'Video', 'voice' => 'Voice message', _ => 'Photo' };
  IconData get _icon => switch (widget.message.type) { 'video' => Icons.videocam_rounded, 'voice' => Icons.mic_rounded, _ => Icons.photo_rounded };

  Future<void> _open() async {
    final m = widget.message;
    final services = context.read<AppServices>();
    final store = context.read<ChatStore>();
    setState(() => _busy = true);
    File? file;
    try {
      await store.openOnce(m);
      file = await services.media.get(m.media!);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => _OnceViewer(file: file!, type: m.type),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
    // gone from this phone too
    await services.media.remove(m.media!);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final c = widget.color;
    final opened = widget.isMine ? m.openedBy.isNotEmpty : m.openedBy.contains(widget.myId);
    final canOpen = !widget.isMine && !opened && !m.isLocal;
    final status = widget.isMine
        ? (m.isLocal ? 'Sending…' : (opened ? (m.openedBy.length > 1 ? 'Opened by ${m.openedBy.length}' : 'Opened') : 'Not opened yet'))
        : (opened ? 'Opened' : 'Tap to view once');
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: canOpen && !_busy ? _open : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: opened ? null : Brand.aurora,
              border: opened ? Border.all(color: c.withValues(alpha: 0.5), width: 2, style: BorderStyle.solid) : null,
            ),
            child: _busy
                ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                : Stack(alignment: Alignment.center, children: [
                    Icon(opened ? Icons.done_rounded : _icon, color: opened ? c.withValues(alpha: 0.7) : Colors.white, size: 22),
                    if (!opened)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          width: 14,
                          height: 14,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                          child: const Text('1', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Brand.rose, height: 1)),
                        ),
                      ),
                  ]),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('$_what · view once', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: c)),
            const SizedBox(height: 2),
            Text(status, style: TextStyle(fontSize: 12.5, color: c.withValues(alpha: 0.75))),
          ]),
          const SizedBox(width: 6),
        ]),
      ),
    );
  }
}

/// Full-screen, one-time view. Closing it ends the view.
class _OnceViewer extends StatefulWidget {
  const _OnceViewer({required this.file, required this.type});
  final File file;
  final String type;

  @override
  State<_OnceViewer> createState() => _OnceViewerState();
}

class _OnceViewerState extends State<_OnceViewer> {
  VideoPlayerController? _video;
  AudioPlayer? _audio;

  @override
  void initState() {
    super.initState();
    if (widget.type == 'video') {
      final c = VideoPlayerController.file(widget.file);
      _video = c;
      c.initialize().then((_) {
        if (mounted) setState(() {});
        c.play();
      });
    } else if (widget.type == 'voice') {
      final a = AudioPlayer();
      _audio = a;
      a.setFilePath(widget.file.path).then((_) => a.play()).catchError((_) => null);
      a.playerStateStream.listen((s) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    _audio?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (widget.type == 'video') {
      final c = _video!;
      body = c.value.isInitialized
          ? AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))
          : const CircularProgressIndicator(color: Colors.white);
    } else if (widget.type == 'voice') {
      final a = _audio!;
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 120,
          height: 120,
          decoration: const BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle),
          child: Icon(a.playing ? Icons.graphic_eq_rounded : Icons.mic_rounded, color: Colors.white, size: 56),
        ),
        const SizedBox(height: 18),
        StreamBuilder<Duration>(
          stream: a.positionStream,
          builder: (_, snap) => Text(
            '${duration((snap.data ?? Duration.zero).inSeconds)} / ${duration(a.duration?.inSeconds ?? 0)}',
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ]);
    } else {
      body = InteractiveViewer(maxScale: 4, child: Image.file(widget.file));
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('View once', style: TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(child: Center(child: body)),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('This can be viewed only once. Close it when you are done.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ]),
      ),
    );
  }
}
