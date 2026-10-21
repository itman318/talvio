import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/services.dart';
import '../core/socket_service.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/extras.dart';
import '../widgets/message_bubble.dart';
import 'group_info_screen.dart';
import '../theme/brand.dart';

const topicColors = [
  Color(0xFF6FB9F0), Color(0xFFFFD67E), Color(0xFFCB86DB), Color(0xFF8EEE98),
  Color(0xFFFF93B2), Color(0xFFFB6F5F), Color(0xFF8FA4F3), Color(0xFF5ECBC2),
];

/// Comments under a channel post ([root]) or one topic of a forum group ([topic]).
class ThreadScreen extends StatefulWidget {
  const ThreadScreen({super.key, required this.chat, this.root, this.topic});
  final Chat chat;
  final Message? root;
  final Topic? topic;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  final List<Message> _msgs = []; // newest first
  final _text = TextEditingController();
  StreamSubscription<SocketEvent>? _sub;
  bool _loading = true;
  bool _hasMore = false;
  bool _sending = false;

  bool get _isComments => widget.root != null;

  Map<String, String> get _filter => _isComments
      ? {'thread_id': '${widget.root!.id}'}
      : {'topic_id': widget.topic!.id == 0 ? 'general' : '${widget.topic!.id}'};

  bool _matches(Message m) {
    if (m.chatId != widget.chat.id) return false;
    if (_isComments) return m.threadId == widget.root!.id;
    if (m.threadId != null) return false;
    return widget.topic!.id == 0 ? m.topicId == null : m.topicId == widget.topic!.id;
  }

  @override
  void initState() {
    super.initState();
    _load();
    _sub = context.read<AppServices>().socket.events.listen(_onEvent);
    if (!_isComments) context.read<ChatStore>().markChatRead(widget.chat.id);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _text.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    try {
      final q = {..._filter, 'limit': '50', if (more && _msgs.isNotEmpty) 'before': '${_msgs.last.id}'};
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/chats/${widget.chat.id}/messages', query: q) as Map);
      final list = (r['messages'] as List).map((j) => Message.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      if (!mounted) return;
      setState(() {
        if (!more) _msgs.clear();
        _msgs.addAll(list);
        _hasMore = r['has_more'] == true;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  void _onEvent(SocketEvent e) {
    final d = e.data;
    switch (e.name) {
      case 'message:new':
        final m = Message.fromJson(Map<String, dynamic>.from(d['message'] as Map));
        if (!_matches(m) || _msgs.any((x) => x.id == m.id)) return;
        setState(() => _msgs.insert(0, m));
        break;
      case 'message:edited':
        final m = Message.fromJson(Map<String, dynamic>.from(d['message'] as Map));
        final i = _msgs.indexWhere((x) => x.id == m.id);
        if (i >= 0) setState(() => _msgs[i] = m);
        break;
      case 'message:deleted':
        final ids = ((d['message_ids'] as List?) ?? []).map((x) => (x as num).toInt()).toSet();
        setState(() => _msgs.removeWhere((x) => ids.contains(x.id)));
        break;
    }
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final body = <String, dynamic>{
        'chat_id': widget.chat.id,
        'type': 'text',
        'text': t,
        'client_id': 'c${DateTime.now().microsecondsSinceEpoch}',
        if (_isComments) 'thread_id': widget.root!.id,
        if (!_isComments && widget.topic!.id != 0) 'topic_id': widget.topic!.id,
      };
      final r = await context.read<AppServices>().socket.request('message:send', body);
      _text.clear();
      final m = Message.fromJson(Map<String, dynamic>.from(r['message'] as Map));
      if (mounted && !_msgs.any((x) => x.id == m.id)) setState(() => _msgs.insert(0, m));
    } on ApiException catch (e) {
      if (mounted) showInfo(context, e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final chat = store.chatById(widget.chat.id) ?? widget.chat;
    final colors = ChatColors.of(context);
    final closed = !_isComments && widget.topic!.isClosed && !chat.isAdmin;
    final canWrite = !chat.isSuspended && !closed && (_isComments ? chat.commentsEnabled : true);
    final items = <Widget>[];
    for (var i = 0; i < _msgs.length; i++) {
      final m = _msgs[i];
      final older = i + 1 < _msgs.length ? _msgs[i + 1] : null;
      items.add(MessageBubble(
        message: m,
        chat: chat,
        isMine: m.senderId == store.myId,
        showSender: m.senderId != store.myId && (older == null || older.senderId != m.senderId),
        commentMode: _isComments,
      ));
    }
    if (_hasMore) {
      items.add(Center(child: TextButton(onPressed: () => _load(more: true), child: const Text('Load older'))));
    }
    if (_isComments) {
      items.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(children: [
          MessageBubble(message: widget.root!, chat: chat, isMine: false, showSender: false),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(_msgs.isEmpty && !_loading ? 'No comments yet — be the first' : 'Comments', style: TextStyle(color: colors.meta, fontSize: 13)),
          ),
        ]),
      ));
    }

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_isComments ? 'Comments' : widget.topic!.title, style: const TextStyle(fontSize: 17)),
          Text(chat.title, style: TextStyle(fontSize: 13, color: colors.meta)),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(reverse: true, padding: const EdgeInsets.symmetric(vertical: 8), children: items),
        ),
        SafeArea(
          top: false,
          child: Container(
            color: colors.bar,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: canWrite
                ? Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _text,
                        minLines: 1,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(hintText: _isComments ? 'Write a comment' : 'Message', border: InputBorder.none),
                      ),
                    ),
                    IconButton(
                      icon: _sending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.arrow_upward_rounded),
                      color: Brand.primary,
                      onPressed: _send,
                    ),
                  ])
                : Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(closed ? 'This topic is closed' : 'You can’t write here', textAlign: TextAlign.center, style: TextStyle(color: colors.meta)),
                  ),
          ),
        ),
      ]),
    );
  }
}

/// Topic list of a forum group.
class TopicsScreen extends StatefulWidget {
  const TopicsScreen({super.key, required this.chat});
  final Chat chat;

  @override
  State<TopicsScreen> createState() => _TopicsScreenState();
}

class _TopicsScreenState extends State<TopicsScreen> {
  Topic? _general;
  List<Topic>? _topics;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/chats/${widget.chat.id}/topics') as Map);
      if (!mounted) return;
      setState(() {
        _general = Topic.fromJson(Map<String, dynamic>.from(r['general'] as Map));
        _topics = (r['topics'] as List).map((j) => Topic.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _create() async {
    final title = TextEditingController();
    var color = 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('New topic'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, autofocus: true, maxLength: 128, decoration: const InputDecoration(hintText: 'e.g. Announcements')),
            Wrap(
              spacing: 8,
              children: List.generate(
                topicColors.length,
                (i) => GestureDetector(
                  onTap: () => set(() => color = i),
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: topicColors[i],
                    child: color == i ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                  ),
                ),
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true || title.text.trim().isEmpty || !mounted) return;
    try {
      await context.read<AppServices>().api.post('/chats/${widget.chat.id}/topics', {'title': title.text.trim(), 'icon_color': color});
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _menu(Topic t) async {
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.push_pin_outlined), title: Text(t.isPinned ? 'Unpin' : 'Pin'), onTap: () => Navigator.pop(ctx, 'pin')),
          ListTile(leading: Icon(t.isClosed ? Icons.lock_open : Icons.lock_outline), title: Text(t.isClosed ? 'Reopen topic' : 'Close topic'), onTap: () => Navigator.pop(ctx, 'close')),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('Delete topic', style: TextStyle(color: Colors.red)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ]),
      ),
    );
    if (a == null || !mounted) return;
    final api = context.read<AppServices>().api;
    try {
      if (a == 'delete') {
        if (!await confirm(context, 'Delete “${t.title}”?', 'All its messages will be deleted for everyone.', ok: 'Delete', danger: true)) return;
        await api.delete('/chats/${widget.chat.id}/topics/${t.id}');
      } else {
        await api.patch('/chats/${widget.chat.id}/topics/${t.id}', a == 'pin' ? {'is_pinned': !t.isPinned} : {'is_closed': !t.isClosed});
      }
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _tile(Topic t, Chat chat) {
    final last = t.lastMessage;
    return ListTile(
      leading: t.id == 0
          ? const CircleAvatar(child: Icon(Icons.tag))
          : CircleAvatar(
              backgroundColor: topicColors[t.iconColor % topicColors.length],
              child: Text(t.title.characters.first.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
      title: Row(children: [
        Flexible(child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
        if (t.isPinned) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.push_pin, size: 14)),
        if (t.isClosed) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.lock, size: 14)),
      ]),
      subtitle: Text(
        last == null ? 'No messages yet' : '${last.sender?.firstName ?? ''}${last.sender != null ? ': ' : ''}${last.preview}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: last == null ? null : Text(chatListTime(last.createdAt), style: const TextStyle(fontSize: 12)),
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => ThreadScreen(chat: chat, topic: t)));
        _load();
      },
      onLongPress: t.id != 0 && chat.isAdmin ? () => _menu(t) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final chat = store.chatById(widget.chat.id) ?? widget.chat;
    final topics = _topics;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GroupInfoScreen(chatId: chat.id))),
          child: Row(children: [
            Avatar(id: chat.id, name: chat.title, url: chat.avatarAbsolute, size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text('${chat.memberCount} members · topics', style: const TextStyle(fontSize: 13)),
              ]),
            ),
          ]),
        ),
      ),
      body: topics == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(children: [
                if (_general != null) _tile(_general!, chat),
                ...topics.map((t) => _tile(t, chat)),
              ]),
            ),
      floatingActionButton: chat.isAdmin ? FloatingActionButton(onPressed: _create, tooltip: 'New topic', child: const Icon(Icons.add_comment_outlined)) : null,
    );
  }
}
