import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/message_bubble.dart';
import '../widgets/report_dialog.dart';
import 'forward_screen.dart';
import 'group_info_screen.dart';
import 'user_profile_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chatId, this.initial});

  final int chatId;
  final Chat? initial;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatStore _store;
  Chat? _chat;
  bool _loading = true;
  String? _error;

  final _text = TextEditingController();
  final _scroll = ScrollController();
  Message? _replyTo;
  Message? _editing;

  final _recorder = AudioRecorder();
  bool _recording = false;
  int _recSeconds = 0;
  Timer? _recTimer;

  int get chatId => widget.chatId;

  @override
  void initState() {
    super.initState();
    _store = context.read<ChatStore>();
    _chat = widget.initial;
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
        _store.loadMore(chatId).catchError((_) {});
      }
    });
    _open();
  }

  Future<void> _open() async {
    try {
      _chat = await _store.getChat(chatId);
      await _store.openChat(chatId);
      if (_chat!.isGroup) _store.loadMembers(chatId).catchError((_) => <GroupMember>[]);
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _store.closeChat(chatId);
    _recTimer?.cancel();
    _recorder.dispose();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ sending
  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    if (_editing != null) {
      final m = _editing!;
      setState(() => _editing = null);
      _text.clear();
      try {
        await _store.editMessage(m, text);
      } catch (e) {
        if (mounted) showError(context, e);
      }
      return;
    }
    final reply = _replyTo;
    setState(() => _replyTo = null);
    _text.clear();
    await _store.sendText(chatId, text, replyTo: reply);
  }

  bool _checkSize(String path) {
    final maxMb = (context.read<AuthState>().appConfig['max_upload_mb'] as num?)?.toInt() ?? 50;
    if (File(path).lengthSync() > maxMb * 1024 * 1024) {
      showInfo(context, 'File is larger than $maxMb MB');
      return false;
    }
    return true;
  }

  Future<void> _sendFile(String path, {required String type, String? name, int? duration}) async {
    if (!_checkSize(path)) return;
    int? w;
    int? h;
    if (type == 'image') {
      try {
        final img = await decodeImageFromList(await File(path).readAsBytes());
        w = img.width;
        h = img.height;
        img.dispose();
      } catch (_) {}
    }
    final caption = _text.text.trim();
    if (caption.isNotEmpty && type != 'voice') _text.clear();
    final reply = _replyTo;
    setState(() => _replyTo = null);
    await _store.sendMedia(
      chatId,
      path,
      type: type,
      caption: type == 'voice' ? '' : caption,
      mime: type == 'voice' ? 'audio/mp4' : lookupMimeType(path),
      name: name,
      duration: duration,
      width: w,
      height: h,
      replyTo: reply,
    );
  }

  Future<void> _attach() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.photo), title: const Text('Photo'), onTap: () => Navigator.pop(ctx, 'photo')),
          ListTile(leading: const Icon(Icons.photo_camera), title: const Text('Camera'), onTap: () => Navigator.pop(ctx, 'camera')),
          ListTile(leading: const Icon(Icons.videocam), title: const Text('Video'), onTap: () => Navigator.pop(ctx, 'video')),
          ListTile(leading: const Icon(Icons.attach_file), title: const Text('File'), onTap: () => Navigator.pop(ctx, 'file')),
        ]),
      ),
    );
    if (choice == null) return;
    try {
      final picker = ImagePicker();
      switch (choice) {
        case 'photo':
        case 'camera':
          final x = await picker.pickImage(
            source: choice == 'photo' ? ImageSource.gallery : ImageSource.camera,
            imageQuality: 85,
            maxWidth: 2560,
            maxHeight: 2560,
          );
          if (x != null) await _sendFile(x.path, type: 'image', name: x.name);
          break;
        case 'video':
          final x = await picker.pickVideo(source: ImageSource.gallery);
          if (x != null) await _sendFile(x.path, type: 'video', name: x.name);
          break;
        case 'file':
          final r = await FilePicker.platform.pickFiles();
          final f = r?.files.single;
          if (f?.path != null) await _sendFile(f!.path!, type: 'file', name: f.name);
          break;
      }
    } catch (e) {
      if (mounted) showInfo(context, 'Could not attach: $e');
    }
  }

  // ------------------------------------------------------------------ voice notes
  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) showInfo(context, 'Allow microphone access to record voice messages');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100), path: path);
      HapticFeedback.mediumImpact();
      setState(() {
        _recording = true;
        _recSeconds = 0;
      });
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _recSeconds++);
        if (_recSeconds >= 15 * 60) _stopRecording(send: true);
      });
    } catch (e) {
      if (mounted) showInfo(context, 'Could not start recording');
    }
  }

  Future<void> _stopRecording({required bool send}) async {
    _recTimer?.cancel();
    final seconds = _recSeconds;
    setState(() => _recording = false);
    if (!send) {
      await _recorder.cancel();
      return;
    }
    final path = await _recorder.stop();
    if (path == null || seconds < 1) return;
    await _sendFile(path, type: 'voice', duration: seconds, name: 'voice.m4a');
  }

  // ------------------------------------------------------------------ message menu
  Future<void> _messageMenu(Message m, Chat chat) async {
    final mine = m.senderId == _store.myId;
    if (m.isLocal) {
      if (m.sendState != SendState.failed) return;
      final a = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Wrap(children: [
            ListTile(leading: const Icon(Icons.refresh), title: const Text('Try again'), onTap: () => Navigator.pop(ctx, 'retry')),
            ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete'), onTap: () => Navigator.pop(ctx, 'discard')),
          ]),
        ),
      );
      if (a == 'retry') _store.retry(m);
      if (a == 'discard') _store.discard(m);
      return;
    }
    if (m.isSystem) return;
    final canEdit = mine && m.forwardedFromName == null && (m.type == 'text' || m.text.isNotEmpty);
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          if (!chat.isSuspended) ListTile(leading: const Icon(Icons.reply), title: const Text('Reply'), onTap: () => Navigator.pop(ctx, 'reply')),
          if (m.text.isNotEmpty) ListTile(leading: const Icon(Icons.copy), title: const Text('Copy text'), onTap: () => Navigator.pop(ctx, 'copy')),
          if (canEdit) ListTile(leading: const Icon(Icons.edit), title: const Text('Edit'), onTap: () => Navigator.pop(ctx, 'edit')),
          ListTile(leading: const Icon(Icons.forward), title: const Text('Forward'), onTap: () => Navigator.pop(ctx, 'forward')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete'), onTap: () => Navigator.pop(ctx, 'delete')),
          if (!mine) ListTile(leading: const Icon(Icons.flag_outlined), title: const Text('Report'), onTap: () => Navigator.pop(ctx, 'report')),
        ]),
      ),
    );
    if (!mounted || a == null) return;
    switch (a) {
      case 'reply':
        setState(() {
          _replyTo = m;
          _editing = null;
        });
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        if (mounted) showInfo(context, 'Copied');
        break;
      case 'edit':
        setState(() {
          _editing = m;
          _replyTo = null;
          _text.text = m.text;
        });
        break;
      case 'forward':
        Navigator.push(context, MaterialPageRoute(builder: (_) => ForwardScreen(fromChatId: chatId, messageIds: [m.id])));
        break;
      case 'delete':
        await _delete(m, chat, mine);
        break;
      case 'report':
        await showReportDialog(context, targetType: 'message', targetId: m.id);
        break;
    }
  }

  Future<void> _delete(Message m, Chat chat, bool mine) async {
    final canForEveryone = mine || (chat.type == 'private' && !chat.isSavedMessages) || chat.isAdmin;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete message?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'me'), child: Text(chat.isSavedMessages ? 'Delete' : 'Delete for me')),
          if (canForEveryone && !chat.isSavedMessages)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'all'),
              child: const Text('Delete for everyone', style: TextStyle(color: Colors.red)),
            ),
        ],
      ),
    );
    if (choice == null) return;
    try {
      await _store.deleteMessages(chatId, [m.id], forEveryone: choice == 'all');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  // ------------------------------------------------------------------ chat menu
  Future<void> _chatMenu(String action, Chat chat) async {
    try {
      switch (action) {
        case 'mute':
          await _store.updateChatSettings(chatId, {'muted_until': chat.isMuted ? null : 'forever'});
          break;
        case 'clear':
          if (await confirm(context, 'Clear history?', 'Messages will be removed for you only.', ok: 'Clear', danger: true)) {
            await _store.clearHistory(chatId);
          }
          break;
        case 'block':
          final peer = chat.peer!;
          final api = context.read<AppServices>().api;
          if (peer.blocked) {
            await api.delete('/blocks/${peer.id}');
          } else if (await confirm(context, 'Block ${peer.name}?', 'They won’t be able to message you.', ok: 'Block', danger: true)) {
            await api.post('/blocks/${peer.id}');
          }
          await _store.refreshChat(chatId);
          _chat = await _store.getChat(chatId);
          if (mounted) setState(() {});
          break;
        case 'report':
          await showReportDialog(
            context,
            targetType: chat.isGroup ? 'chat' : 'user',
            targetId: chat.isGroup ? chat.id : chat.peer!.id,
          );
          break;
        case 'leave':
          final ok = await confirm(
            context,
            chat.isGroup ? 'Leave group?' : 'Delete chat?',
            chat.isGroup ? 'You will stop receiving messages from this group.' : 'The chat history will be removed for you.',
            ok: chat.isGroup ? 'Leave' : 'Delete',
            danger: true,
          );
          if (ok) {
            await _store.leaveOrDelete(chatId);
            if (mounted) Navigator.pop(context);
          }
          break;
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _openInfo(Chat chat) {
    if (chat.isGroup) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => GroupInfoScreen(chatId: chat.id)));
    } else if (chat.peer != null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfileScreen(userId: chat.peer!.id)));
    }
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final chat = store.chatById(chatId) ?? _chat;
    if (chat == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator()),
      );
    }
    final messages = store.messagesOf(chatId);
    final typing = store.typingText(chat);
    String subtitle;
    if (typing != null) {
      subtitle = typing;
    } else if (chat.isGroup) {
      subtitle = '${chat.memberCount} members';
    } else if (chat.peer != null) {
      subtitle = lastSeenText(chat.peer!);
    } else {
      subtitle = '';
    }

    return Scaffold(
      backgroundColor: const Color(0xFFDCE6EE),
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => _openInfo(chat),
          child: Row(
            children: [
              Avatar(id: chat.id, name: chat.title, url: chat.avatarAbsolute, size: 40, icon: chat.isSavedMessages ? Icons.bookmark : null),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
                    if (subtitle.isNotEmpty)
                      Text(subtitle,
                          style: TextStyle(fontSize: 13, color: typing != null || chat.peer?.online == true ? const Color(0xFF2AABEE) : Colors.black54)),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (a) => _chatMenu(a, chat),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'mute', child: Text(chat.isMuted ? 'Unmute' : 'Mute')),
              const PopupMenuItem(value: 'clear', child: Text('Clear history')),
              if (chat.peer != null) PopupMenuItem(value: 'block', child: Text(chat.peer!.blocked ? 'Unblock user' : 'Block user')),
              if (!chat.isSavedMessages) const PopupMenuItem(value: 'report', child: Text('Report')),
              PopupMenuItem(value: 'leave', child: Text(chat.isGroup ? 'Leave group' : 'Delete chat')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!store.connected)
            Container(
              width: double.infinity,
              color: Colors.amber.shade100,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: const Text('Connecting…', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
            ),
          Expanded(child: _messageList(chat, messages, store)),
          _bottomBar(chat),
        ],
      ),
    );
  }

  Widget _messageList(Chat chat, List<Message> messages, ChatStore store) {
    if (_loading && messages.isEmpty) return const Center(child: CircularProgressIndicator());
    if (messages.isEmpty) {
      return Center(child: SystemBubble(text: _error ?? (chat.isSavedMessages ? 'Save notes, links and files here' : 'No messages here yet. Say hi! 👋')));
    }
    final hasMore = store.hasMore(chatId);
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: messages.length + (hasMore ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i == messages.length) {
          return const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final m = messages[i];
        final older = i + 1 < messages.length ? messages[i + 1] : null;
        final newDay = older == null ||
            older.createdAt.year != m.createdAt.year ||
            older.createdAt.month != m.createdAt.month ||
            older.createdAt.day != m.createdAt.day;
        final mine = m.senderId == store.myId;
        final showSender = chat.isGroup && !mine && (older == null || older.senderId != m.senderId || older.isSystem || newDay);
        return Column(
          children: [
            if (newDay) DateChip(date: m.createdAt),
            if (m.isSystem)
              SystemBubble(text: systemText(m, store))
            else
              MessageBubble(
                key: ValueKey(m.isLocal ? m.clientId : m.id),
                message: m,
                chat: chat,
                isMine: mine,
                showSender: showSender,
                onLongPress: () => _messageMenu(m, chat),
                onTap: m.sendState == SendState.failed ? () => _messageMenu(m, chat) : null,
              ),
          ],
        );
      },
    );
  }

  Widget _bottomBar(Chat chat) {
    String? blockedText;
    Widget? blockedAction;
    if (chat.isSuspended) {
      blockedText = 'This group has been suspended by the moderators.';
    } else if (chat.peer?.deleted == true) {
      blockedText = 'This account was deleted.';
    } else if (chat.peer?.blocked == true) {
      blockedText = 'You blocked this user.';
      blockedAction = TextButton(onPressed: () => _chatMenu('block', chat), child: const Text('Unblock'));
    }
    if (blockedText != null) {
      return SafeArea(
        top: false,
        child: Container(
          color: Colors.white,
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(blockedText, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
            if (blockedAction != null) blockedAction,
          ]),
        ),
      );
    }

    final banner = _editing ?? _replyTo;
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.white,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (banner != null)
              Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 0, 0),
                child: Row(children: [
                  Icon(_editing != null ? Icons.edit : Icons.reply, color: const Color(0xFF2AABEE)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        _editing != null ? 'Edit message' : 'Reply to ${banner.sender?.name ?? _store.userName(banner.senderId)}',
                        style: const TextStyle(color: Color(0xFF2AABEE), fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                      Text(banner.preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    ]),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      if (_editing != null) _text.clear();
                      _editing = null;
                      _replyTo = null;
                    }),
                  ),
                ]),
              ),
            if (_recording)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(children: [
                  const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.fiber_manual_record, color: Colors.red, size: 16)),
                  Text(duration(_recSeconds), style: const TextStyle(fontSize: 16)),
                  const Spacer(),
                  TextButton(onPressed: () => _stopRecording(send: false), child: const Text('Cancel')),
                  IconButton(
                    icon: const Icon(Icons.send, color: Color(0xFF2AABEE)),
                    onPressed: () => _stopRecording(send: true),
                  ),
                ]),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_editing == null) IconButton(icon: const Icon(Icons.attach_file), onPressed: _attach),
                  if (_editing != null) const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 6,
                      maxLength: 4096,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(hintText: 'Message', border: InputBorder.none, counterText: ''),
                      onChanged: (v) {
                        if (v.isNotEmpty) _store.sendTyping(chatId);
                        setState(() {});
                      },
                    ),
                  ),
                  if (_text.text.trim().isNotEmpty || _editing != null)
                    IconButton(icon: Icon(_editing != null ? Icons.check : Icons.send, color: const Color(0xFF2AABEE)), onPressed: _send)
                  else
                    IconButton(icon: const Icon(Icons.mic_none), onPressed: _startRecording, tooltip: 'Record voice message'),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
