import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../core/prefs.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/extras.dart';
import '../widgets/message_bubble.dart';
import '../widgets/report_dialog.dart';
import 'calls_screen.dart';
import 'premium_screens.dart';
import 'thread_screen.dart';
import '../widgets/bot_widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'secret_screens.dart';
import 'channel_screens.dart';
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
  late final AppPrefs _prefs;
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

  Map<String, dynamic>? _ad; // sponsored message under a channel
  bool _adSeen = false;

  @override
  void initState() {
    super.initState();
    _store = context.read<ChatStore>();
    _prefs = context.read<AppPrefs>();
    _chat = widget.initial;
    _text.text = _prefs.draft(widget.chatId) ?? '';
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
      if (_chat!.isChannel && _chat!.isPublic && mounted) _loadAd();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _prefs.setDraft(chatId, _editing == null ? _text.text : '');
    _store.closeChat(chatId);
    _recTimer?.cancel();
    _recorder.dispose();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadAd() async {
    try {
      final r = await context.read<AppServices>().api.get('/chats/$chatId/sponsored') as Map;
      if (mounted && r['ad'] != null) setState(() => _ad = Map<String, dynamic>.from(r['ad'] as Map));
    } catch (_) {}
  }

  Widget _adCard() {
    final ad = _ad!;
    final api = context.read<AppServices>().api;
    if (!_adSeen) {
      _adSeen = true;
      api.post('/ads/${ad['id']}/view').catchError((_) => null);
    }
    final colors = ChatColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 40, 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: colors.other, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Sponsored · ${ad['advertiser']}', style: TextStyle(fontSize: 12, color: colors.meta, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('${ad['text']}', style: const TextStyle(fontSize: 15)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () async {
              try {
                final r = await api.post('/ads/${ad['id']}/click') as Map;
                final url = '${r['url'] ?? ad['url']}';
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              } catch (_) {}
            },
            child: Text('${ad['button_text']}'),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PremiumScreen())),
            child: const Text('Remove ads with Premium ⭐', style: TextStyle(fontSize: 12)),
          ),
        ),
      ]),
    );
  }

  // ------------------------------------------------------------------ sending
  Future<void> _send({bool silent = false}) async {
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
    await _store.sendText(chatId, text, replyTo: reply, silent: silent);
  }

  /// Long-press on send: send silently or schedule.
  Future<void> _sendOptions() async {
    if (_text.text.trim().isEmpty) return;
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.notifications_off_outlined), title: const Text('Send without sound'), onTap: () => Navigator.pop(ctx, 'silent')),
          ListTile(leading: const Icon(Icons.schedule), title: const Text('Schedule message'), onTap: () => Navigator.pop(ctx, 'schedule')),
        ]),
      ),
    );
    if (a == 'silent') await _send(silent: true);
    if (a == 'schedule') await _scheduleCurrent();
  }

  Future<void> _shareLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (mounted) showInfo(context, 'Allow location access to share your location');
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) showInfo(context, 'Turn on location (GPS) first');
        return;
      }
      if (mounted) showInfo(context, 'Getting your location…');
      final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      if (!mounted) return;
      final ok = await confirm(context, 'Send your location?',
          '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)} (±${pos.accuracy.round()} m)', ok: 'Send');
      if (ok) await _store.sendLocation(chatId, pos.latitude, pos.longitude, title: 'My location');
    } catch (e) {
      if (mounted) showInfo(context, 'Could not get your location');
    }
  }

  /// Pick a date & time and schedule the typed text.
  Future<void> _scheduleCurrent() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final now = DateTime.now();
    final day = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 365)), initialDate: now);
    if (day == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 10))));
    if (time == null || !mounted) return;
    final at = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    try {
      await _store.scheduleText(chatId, text, at);
      _text.clear();
      setState(() {});
      if (mounted) showInfo(context, 'Scheduled for ${chatListTime(at)} ${messageTime(at)}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
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
          if (context.read<AuthState>().feature('location'))
            ListTile(leading: const Icon(Icons.location_on_outlined), title: const Text('Location'), onTap: () => Navigator.pop(ctx, 'location')),
          if ((_store.chatById(chatId)?.isMulti ?? _chat?.isMulti ?? false) && context.read<AuthState>().feature('polls'))
            ListTile(leading: const Icon(Icons.poll_outlined), title: const Text('Poll or quiz'), onTap: () => Navigator.pop(ctx, 'poll')),
        ]),
      ),
    );
    if (choice == null) return;
    if (choice == 'location') {
      await _shareLocation();
      return;
    }
    if (choice == 'poll') {
      if (!mounted) return;
      final poll = await Navigator.push<Map<String, dynamic>>(context, MaterialPageRoute(builder: (_) => const CreatePollScreen()));
      if (poll == null) return;
      try {
        await _store.sendPoll(chatId, poll);
      } catch (e) {
        if (mounted) showError(context, e);
      }
      return;
    }
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
    final mine = m.senderId == _store.myId && !chat.isChannel;
    final channelAdmin = chat.isChannel && chat.isAdmin;
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
    final canEdit = (mine || channelAdmin) && m.forwardedFromName == null && m.type != 'poll' && (m.type == 'text' || m.text.isNotEmpty);
    final poll = m.poll;
    final canClosePoll = poll != null && !poll.closed && (mine || chat.isAdmin);
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Wrap(
              spacing: 2,
              children: ChatStore.reactionEmojis
                  .map((e) => InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => Navigator.pop(ctx, 'react:$e'),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: m.myReaction == e ? const Color(0x332AABEE) : null,
                          ),
                          child: Text(e, style: const TextStyle(fontSize: 24)),
                        ),
                      ))
                  .toList(),
            ),
          ),
          const Divider(height: 1),
          if (chat.type == 'private' || chat.isAdmin)
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: Text(chat.pinnedMessage?.id == m.id ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.pop(ctx, chat.pinnedMessage?.id == m.id ? 'unpin' : 'pin'),
            ),
          if (canClosePoll) ListTile(leading: const Icon(Icons.stop_circle_outlined), title: const Text('Stop poll'), onTap: () => Navigator.pop(ctx, 'close_poll')),
          if (chat.canPost) ListTile(leading: const Icon(Icons.reply), title: const Text('Reply'), onTap: () => Navigator.pop(ctx, 'reply')),
          if (m.text.isNotEmpty) ListTile(leading: const Icon(Icons.copy), title: const Text('Copy text'), onTap: () => Navigator.pop(ctx, 'copy')),
          if (canEdit) ListTile(leading: const Icon(Icons.edit), title: const Text('Edit'), onTap: () => Navigator.pop(ctx, 'edit')),
          if (m.type != 'poll' && m.type != 'call') ListTile(leading: const Icon(Icons.forward), title: const Text('Forward'), onTap: () => Navigator.pop(ctx, 'forward')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete'), onTap: () => Navigator.pop(ctx, 'delete')),
          if (!mine && !channelAdmin) ListTile(leading: const Icon(Icons.flag_outlined), title: const Text('Report'), onTap: () => Navigator.pop(ctx, 'report')),
        ]),
      ),
    );
    if (!mounted || a == null) return;
    if (a.startsWith('react:')) {
      _store.react(m, a.substring(6)).catchError((e) {
        if (mounted) showError(context, e);
      });
      return;
    }
    switch (a) {
      case 'pin':
      case 'unpin':
        try {
          if (a == 'pin') {
            await _store.pin(chatId, m.id);
          } else {
            await _store.unpin(chatId, m.id);
          }
        } catch (e) {
          if (mounted) showError(context, e);
        }
        break;
      case 'close_poll':
        if (await confirm(context, 'Stop poll?', 'Nobody will be able to vote after this. Results become final.', ok: 'Stop poll')) {
          try {
            await _store.closePoll(m);
          } catch (e) {
            if (mounted) showError(context, e);
          }
        }
        break;
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
        await _delete(m, chat, mine || channelAdmin);
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
        case 'secret':
          await startSecretChat(context, chat.peer!);
          break;
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
            targetType: chat.isMulti ? 'chat' : 'user',
            targetId: chat.isMulti ? chat.id : chat.peer!.id,
          );
          break;
        case 'scheduled':
          await Navigator.push(context, MaterialPageRoute(builder: (_) => ScheduledScreen(chatId: chatId)));
          break;
        case 'stats':
          await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatStatsScreen(chat: chat)));
          break;
        case 'leave':
          final what = chat.isChannel ? 'channel' : 'group';
          final ok = await confirm(
            context,
            chat.isMulti ? 'Leave $what?' : 'Delete chat?',
            chat.isMulti ? 'You will stop receiving messages from this $what.' : 'The chat history will be removed for you.',
            ok: chat.isMulti ? 'Leave' : 'Delete',
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
    if (chat.isMulti) {
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
    if (chat.isForum) return TopicsScreen(chat: chat);
    final messages = store.messagesOf(chatId);
    final typing = store.typingText(chat);
    final auth = context.watch<AuthState>();
    String subtitle;
    if (chat.isBot) {
      subtitle = 'bot';
    } else if (typing != null) {
      subtitle = typing;
    } else if (chat.isGroup) {
      subtitle = chat.isChannel ? '${chat.memberCount} subscribers' : '${chat.memberCount} members';
    } else if (chat.peer != null) {
      subtitle = lastSeenText(chat.peer!);
    } else {
      subtitle = '';
    }

    return Scaffold(
      backgroundColor: ChatColors.of(context).background,
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
                    Row(children: [
                      Flexible(child: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17))),
                      if (chat.peer?.isPremium == true) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.star_rounded, size: 18, color: Color(0xFF8E6CEF))),
                    ]),
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
          if (chat.peer != null && !chat.isSavedMessages && !chat.peer!.deleted && !chat.isBot && auth.feature('calls')) ...[
            if (auth.feature('video_calls'))
              IconButton(
                tooltip: 'Video call',
                icon: const Icon(Icons.videocam_outlined),
                onPressed: () => startCall(context, chat.peer!, video: true),
              ),
            IconButton(
              tooltip: 'Call',
              icon: const Icon(Icons.call_outlined),
              onPressed: () => startCall(context, chat.peer!, video: false),
            ),
          ],
          PopupMenuButton<String>(
            onSelected: (a) => _chatMenu(a, chat),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'mute', child: Text(chat.isMuted ? 'Unmute' : 'Mute')),
              const PopupMenuItem(value: 'clear', child: Text('Clear history')),
              if (chat.canPost) const PopupMenuItem(value: 'scheduled', child: Text('Scheduled messages')),
              if (chat.isMulti && chat.isAdmin) const PopupMenuItem(value: 'stats', child: Text('Statistics')),
              if (chat.peer != null && !chat.isSavedMessages && !chat.peer!.deleted && !chat.isBot && auth.feature('secret_chats'))
                const PopupMenuItem(value: 'secret', child: Text('Start secret chat')),
              if (chat.peer != null) PopupMenuItem(value: 'block', child: Text(chat.peer!.blocked ? 'Unblock user' : 'Block user')),
              if (!chat.isSavedMessages) const PopupMenuItem(value: 'report', child: Text('Report')),
              PopupMenuItem(value: 'leave', child: Text(chat.isChannel ? 'Leave channel' : (chat.isGroup ? 'Leave group' : 'Delete chat'))),
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
          if (chat.pinnedMessage != null) _pinnedBar(chat),
          Expanded(child: _messageList(chat, messages, store)),
          _bottomBar(chat),
        ],
      ),
    );
  }

  Widget _messageList(Chat chat, List<Message> messages, ChatStore store) {
    if (_loading && messages.isEmpty) return const Center(child: CircularProgressIndicator());
    if (messages.isEmpty && chat.isBot) {
      return BotIntro(chat: chat, onStart: () => _store.sendText(chatId, '/start'));
    }
    if (messages.isEmpty) {
      return Center(child: SystemBubble(text: _error ?? (chat.isSavedMessages ? 'Save notes, links and files here' : 'No messages here yet. Say hi! 👋')));
    }
    final hasMore = store.hasMore(chatId);
    if (chat.isChannel) {
      // Count views for the posts on screen (server ignores repeats).
      WidgetsBinding.instance.addPostFrameCallback((_) => store.recordViews(chatId, messages.take(40)));
    }
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: messages.length + (hasMore ? 1 : 0) + (_ad != null ? 1 : 0),
      itemBuilder: (ctx, idx) {
        if (_ad != null && idx == 0) return _adCard();
        final i = _ad != null ? idx - 1 : idx;
        if (i == messages.length) {
          return const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final m = messages[i];
        final older = i + 1 < messages.length ? messages[i + 1] : null;
        final newDay = older == null ||
            older.createdAt.year != m.createdAt.year ||
            older.createdAt.month != m.createdAt.month ||
            older.createdAt.day != m.createdAt.day;
        final mine = chat.isChannel ? m.isLocal : m.senderId == store.myId;
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

  Widget _pinnedBar(Chat chat) {
    final p = chat.pinnedMessage!;
    return Material(
      color: ChatColors.of(context).bar,
      child: InkWell(
        onTap: () => _showPins(chat),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.black12))),
          child: Row(children: [
            Container(width: 3, height: 34, color: const Color(0xFF2AABEE)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(chat.pinnedCount > 1 ? 'Pinned message (${chat.pinnedCount})' : 'Pinned message',
                    style: const TextStyle(color: Color(0xFF2AABEE), fontWeight: FontWeight.w600, fontSize: 13)),
                Text(p.preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              ]),
            ),
            if (chat.type == 'private' || chat.isAdmin)
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Unpin',
                onPressed: () => _store.unpin(chat.id, p.id).catchError((e) {
                  if (mounted) showError(context, e);
                }),
              ),
          ]),
        ),
      ),
    );
  }

  Future<void> _showPins(Chat chat) async {
    try {
      final pins = await _store.listPins(chat.id);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
            child: ListView(shrinkWrap: true, children: [
              ListTile(
                title: Text('${pins.length} pinned', style: const TextStyle(fontWeight: FontWeight.w600)),
                trailing: (chat.type == 'private' || chat.isAdmin) && pins.length > 1
                    ? TextButton(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _store.unpin(chat.id, 'all');
                        },
                        child: const Text('Unpin all'),
                      )
                    : null,
              ),
              ...pins.map((m) => ListTile(
                    leading: const Icon(Icons.push_pin_outlined),
                    title: Text(m.preview, maxLines: 3, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${m.sender?.name ?? chat.title} · ${chatListTime(m.createdAt)}'),
                  )),
            ]),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _bottomBar(Chat chat) {
    if (chat.isChannel && !chat.canPost && !chat.isSuspended) {
      return SafeArea(
        top: false,
        child: Container(
          color: ChatColors.of(context).bar,
          width: double.infinity,
          child: TextButton(
            onPressed: () => _chatMenu('mute', chat),
            child: Text(chat.isMuted ? 'Unmute' : 'Mute', style: const TextStyle(fontSize: 16)),
          ),
        ),
      );
    }
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
          color: ChatColors.of(context).bar,
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
        color: ChatColors.of(context).bar,
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
                  if (_editing == null && chat.isBot && chat.bot?.menuUrl != null)
                    IconButton(
                      tooltip: 'Open app',
                      icon: const Icon(Icons.apps),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => MiniAppScreen(botId: chat.peer!.id, url: chat.bot!.menuUrl!, title: chat.title)),
                      ),
                    ),
                  if (_editing == null && chat.isBot && (chat.bot?.commands.isNotEmpty ?? false))
                    IconButton(
                      tooltip: 'Commands',
                      icon: const Icon(Icons.terminal),
                      onPressed: () async {
                        final c = await pickBotCommand(context, chat.bot!);
                        if (c != null) _store.sendText(chatId, c);
                      },
                    ),
                  if (_editing == null) IconButton(icon: const Icon(Icons.attach_file), onPressed: _attach),
                  if (_editing != null) const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 6,
                      maxLength: 4096,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: chat.slowModeSec > 0 && !chat.isAdmin ? 'Message (slow mode: ${chat.slowModeSec}s)' : 'Message',
                        border: InputBorder.none,
                        counterText: '',
                      ),
                      onChanged: (v) {
                        if (v.isNotEmpty) _store.sendTyping(chatId);
                        setState(() {});
                      },
                    ),
                  ),
                  if (_text.text.trim().isNotEmpty || _editing != null)
                    GestureDetector(
                      onLongPress: _editing == null ? _sendOptions : null,
                      child: IconButton(
                        icon: Icon(_editing != null ? Icons.check : Icons.send, color: const Color(0xFF2AABEE)),
                        tooltip: 'Send (hold to schedule)',
                        onPressed: _send,
                      ),
                    )
                  else if (context.read<AuthState>().feature('voice_messages'))
                    IconButton(icon: const Icon(Icons.mic_none), onPressed: _startRecording, tooltip: 'Record voice message'),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
