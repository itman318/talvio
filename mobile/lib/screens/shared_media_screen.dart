import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/media_widgets.dart';
import '../widgets/video_note.dart';

/// Chat menu → Shared media: every photo, file, link and voice/video message of a chat.
class SharedMediaScreen extends StatefulWidget {
  const SharedMediaScreen({super.key, required this.chat});
  final Chat chat;

  @override
  State<SharedMediaScreen> createState() => _SharedMediaScreenState();
}

class _SharedMediaScreenState extends State<SharedMediaScreen> {
  static const _tabs = [('media', 'Media'), ('files', 'Files'), ('links', 'Links'), ('voice', 'Voice')];
  Map<String, int>? _counts;

  @override
  void initState() {
    super.initState();
    context.read<AppServices>().api.get('/chats/${widget.chat.id}/media-counts').then((r) {
      if (mounted) setState(() => _counts = Map<String, int>.from((r as Map).map((k, v) => MapEntry('$k', (v as num).toInt()))));
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.chat.title),
          bottom: TabBar(
            isScrollable: false,
            indicatorColor: Brand.primary,
            labelColor: Brand.primary,
            tabs: [
              for (final (key, label) in _tabs) Tab(text: _counts?[key] != null && _counts![key]! > 0 ? '$label ${_counts![key]}' : label),
            ],
          ),
        ),
        body: TabBarView(children: [for (final (key, _) in _tabs) _MediaList(chatId: widget.chat.id, filter: key)]),
      ),
    );
  }
}

class _MediaList extends StatefulWidget {
  const _MediaList({required this.chatId, required this.filter});
  final int chatId;
  final String filter;

  @override
  State<_MediaList> createState() => _MediaListState();
}

class _MediaListState extends State<_MediaList> with AutomaticKeepAliveClientMixin {
  final List<Message> _items = [];
  bool _loading = false;
  bool _more = true;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading || !_more) return;
    setState(() => _loading = true);
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/chats/${widget.chatId}/messages', query: {
        'filter': widget.filter,
        'limit': '60',
        if (_items.isNotEmpty) 'before': '${_items.last.id}',
      }) as Map);
      final list = (r['messages'] as List).map((j) => Message.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      _items.addAll(list);
      _more = r['has_more'] == true;
    } catch (e) {
      _error = e;
      _more = false;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _load();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_items.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(_emptyIcon, size: 56, color: Brand.faint),
            const SizedBox(height: 12),
            Text(_error != null ? friendlyError(_error!) : _emptyText, textAlign: TextAlign.center, style: const TextStyle(color: Brand.muted)),
          ]),
        ),
      );
    }
    final child = widget.filter == 'media'
        ? GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
            itemCount: _items.length,
            itemBuilder: (_, i) => _Thumb(message: _items[i]),
          )
        : ListView.separated(
            itemCount: _items.length,
            separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
            itemBuilder: (_, i) => _row(_items[i]),
          );
    return NotificationListener<ScrollNotification>(onNotification: _onScroll, child: child);
  }

  IconData get _emptyIcon => switch (widget.filter) {
        'media' => Icons.photo_library_outlined,
        'files' => Icons.insert_drive_file_outlined,
        'links' => Icons.link_rounded,
        _ => Icons.mic_none_rounded,
      };

  String get _emptyText => switch (widget.filter) {
        'media' => 'Photos and videos you share will appear here',
        'files' => 'Files you share will appear here',
        'links' => 'Links you share will appear here',
        _ => 'Voice and video messages will appear here',
      };

  Widget _row(Message m) {
    final when = chatListTime(m.createdAt);
    switch (widget.filter) {
      case 'files':
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(child: MessageFile(message: m, color: Brand.primary)),
            Text(when, style: const TextStyle(color: Brand.muted, fontSize: 12)),
          ]),
        );
      case 'links':
        final url = RegExp(r'https?://[^\s]+').firstMatch(m.text)?.group(0) ?? '${m.linkPreview?['url'] ?? ''}';
        final title = '${m.linkPreview?['title'] ?? ''}';
        return ListTile(
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: Brand.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.link_rounded, color: Brand.primary),
          ),
          title: Text(title.isNotEmpty ? title : url, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(title.isNotEmpty ? url : m.text, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(when, style: const TextStyle(color: Brand.muted, fontSize: 12)),
          onTap: url.isEmpty ? null : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        );
      default:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            if (m.type == 'video_note')
              VideoNoteBubble(message: m, size: 120)
            else
              Expanded(child: VoicePlayer(message: m, color: Brand.primary)),
            if (m.type == 'video_note') const Spacer(),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(m.sender?.name ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              Text(when, style: const TextStyle(color: Brand.muted, fontSize: 12)),
            ]),
          ]),
        );
    }
  }
}

class _Thumb extends StatefulWidget {
  const _Thumb({required this.message});
  final Message message;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Future<File>? _file;

  @override
  void initState() {
    super.initState();
    final m = widget.message;
    if (m.type == 'image' && m.media != null) _file = resolveMediaFile(context, m);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    if (m.type == 'gif') {
      final g = (m.meta?['gif'] as Map?) ?? const {};
      return Image.network('${g['preview'] ?? g['url'] ?? ''}', fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black12));
    }
    if (m.type == 'video') {
      return InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VideoScreen(message: m))),
        child: Container(
          color: Brand.ink,
          child: Stack(alignment: Alignment.center, children: [
            const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 40),
            if (m.media?.duration != null)
              Positioned(right: 6, bottom: 4, child: Text(duration(m.media!.duration!), style: const TextStyle(color: Colors.white, fontSize: 11))),
          ]),
        ),
      );
    }
    return FutureBuilder<File>(
      future: _file,
      builder: (_, snap) => snap.hasData
          ? InkWell(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FullImageScreen(file: snap.data!))),
              child: Image.file(snap.data!, fit: BoxFit.cover, cacheWidth: 300),
            )
          : const ColoredBox(color: Color(0x14000000)),
    );
  }
}
