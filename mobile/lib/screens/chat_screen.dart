import 'dart:async';
import 'dart:io';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import 'shared_media_screen.dart';
import 'chat_theme_screen.dart';
import '../theme/chat_theme.dart';
import '../widgets/video_note.dart';
import '../widgets/tali_emoji.dart';
import '../widgets/premium.dart';
import '../widgets/message_extras.dart';
import '../core/message_notifications.dart';
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
import 'image_editor_screen.dart';
import '../widgets/album_view.dart';
import 'thread_screen.dart';
import '../widgets/bot_widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'secret_screens.dart';
import 'channel_screens.dart';
import 'forward_screen.dart';
import 'group_info_screen.dart';
import 'user_profile_screen.dart';
import '../theme/brand.dart';
import '../core/chat_export.dart';
import '../widgets/sticker_widgets.dart';
import '../widgets/contact_card.dart';

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

  final _text = EmojiTextController();
  final _focus = FocusNode();
  bool _emojiOpen = false;
  int _panelTab = 0; // emoji panel: 0 emoji · 1 stickers · 2 GIFs
  String? _tag; // My Notes tag filter
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
    MessageNotifications.clearChat(widget.chatId);
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
    _focus.dispose();
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
            child: const Text('Remove ads with Talvio Plus ⭐', style: TextStyle(fontSize: 12)),
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
      if (!mounted) return;
      final liveOk = context.read<AuthState>().feature('live_location');
      final choice = await showModalBottomSheet<int>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(leading: const Icon(Icons.my_location_rounded), title: const Text('Send my current location'), onTap: () => Navigator.pop(ctx, 0)),
            if (liveOk) ...[
              const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 0), child: Align(alignment: Alignment.centerLeft, child: Text('Share live location', style: TextStyle(fontWeight: FontWeight.w700)))),
              ListTile(leading: const Icon(Icons.share_location_rounded), title: const Text('For 15 minutes'), onTap: () => Navigator.pop(ctx, 15)),
              ListTile(leading: const Icon(Icons.share_location_rounded), title: const Text('For 1 hour'), onTap: () => Navigator.pop(ctx, 60)),
              ListTile(leading: const Icon(Icons.share_location_rounded), title: const Text('For 8 hours'), onTap: () => Navigator.pop(ctx, 480)),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text('Your location updates while Talvio is open. You can stop sharing any time.', style: TextStyle(fontSize: 12, color: Brand.muted)),
              ),
            ],
          ]),
        ),
      );
      if (choice == null || !mounted) return;
      showInfo(context, 'Getting your location…');
      final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      if (!mounted) return;
      if (choice == 0) {
        await _store.sendLocation(chatId, pos.latitude, pos.longitude, title: 'My location');
      } else {
        await _store.sendLiveLocation(chatId, pos.latitude, pos.longitude, choice);
      }
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
      if (!mounted) return;
      setState(() {});
      showInfo(context, 'Scheduled for ${chatListTime(at)} ${messageTime(at)}');
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

  Future<void> _sendFile(String path, {required String type, String? name, int? duration, String? albumId}) async {
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
    if (!mounted) return; // the chat was closed while the photo was being read
    final caption = _text.text.trim();
    final noCaption = type == 'voice' || type == 'video_note';
    if (caption.isNotEmpty && !noCaption) _text.clear();
    final reply = _replyTo;
    setState(() => _replyTo = null);
    await _store.sendMedia(
      chatId,
      path,
      type: type,
      caption: noCaption ? '' : caption,
      mime: type == 'voice' ? 'audio/mp4' : type == 'video_note' ? 'video/mp4' : lookupMimeType(path),
      name: name,
      duration: duration,
      width: w,
      height: h,
      albumId: albumId,
      replyTo: reply,
    );
  }

  Future<void> _attach([String? preset]) async {
    final auth = context.read<AuthState>();
    final multi = _store.chatById(chatId)?.isMulti ?? _chat?.isMulti ?? false;
    final items = <(String, IconData, String, List<Color>)>[
      ('photo', Icons.photo_library_rounded, 'Gallery', const [Color(0xFF8E7CF8), Color(0xFF6C5BE3)]),
      ('camera', Icons.photo_camera_rounded, 'Camera', const [Color(0xFFFF7A9C), Color(0xFFE0417A)]),
      ('video', Icons.videocam_rounded, 'Video', const [Color(0xFFFF9A6E), Color(0xFFEF5A3C)]),
      ('file', Icons.insert_drive_file_rounded, 'Document', const [Color(0xFF6FB6F7), Color(0xFF3C83DE)]),
      ('checklist', Icons.checklist_rounded, 'Checklist', const [Color(0xFF6FCB8C), Color(0xFF2F9D5A)]),
      if (auth.feature('voice_messages')) ('videonote', Icons.radio_button_checked_rounded, 'Video note', const [Color(0xFF9AA3C8), Color(0xFF59628F)]),
      if (auth.feature('location')) ('location', Icons.location_on_rounded, 'Location', const [Color(0xFF4FD8A6), Color(0xFF10B37A)]),
      ('contact', Icons.person_rounded, 'Contact', const [Color(0xFF5FD0E6), Color(0xFF1597B8)]),
      if (multi && auth.feature('polls')) ('poll', Icons.bar_chart_rounded, 'Poll', const [Color(0xFFF7D27E), Color(0xFFE0A43A)]),
    ];
    final choice = preset ??
        await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                mainAxisSpacing: 18,
                childAspectRatio: 0.82,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final (key, icon, label, colors) in items)
                    InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => Navigator.pop(ctx, key),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
                            boxShadow: [BoxShadow(color: colors.last.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4))],
                          ),
                          child: Icon(icon, color: Colors.white, size: 27),
                        ),
                        const SizedBox(height: 8),
                        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      ]),
                    ),
                ],
              ),
            ),
          ),
        );
    if (choice == null) return;
    if (choice == 'checklist') {
      if (!mounted) return;
      final text = await buildChecklist(context);
      if (text != null && text.isNotEmpty) await _store.sendText(chatId, text);
      return;
    }
    if (choice == 'videonote') {
      await _recordVideoNote();
      return;
    }
    if (choice == 'location') {
      await _shareLocation();
      return;
    }
    if (choice == 'contact') {
      if (mounted) await pickAndShareContact(context, chatId);
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
          final picked = await picker.pickMultiImage(imageQuality: _prefs.uploadQuality, maxWidth: _prefs.uploadMaxSide, maxHeight: _prefs.uploadMaxSide, limit: 10);
          if (picked.isEmpty) break;
          if (picked.length == 1) {
            await _editAndSend(picked.first.path, picked.first.name);
          } else {
            // several photos → one album
            final albumId = 'a${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${picked.length}';
            for (final x in picked.take(10)) {
              await _sendFile(x.path, type: 'image', name: x.name, albumId: albumId);
            }
          }
          break;
        case 'camera':
          final x = await picker.pickImage(source: ImageSource.camera, imageQuality: _prefs.uploadQuality, maxWidth: _prefs.uploadMaxSide, maxHeight: _prefs.uploadMaxSide);
          if (x != null) await _editAndSend(x.path, x.name);
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

  Future<void> _recordVideoNote() async {
    final r = await Navigator.push<VideoNoteResult>(
      context,
      PageRouteBuilder(opaque: false, pageBuilder: (_, __, ___) => const VideoNoteRecorder()),
    );
    if (r == null || !mounted) return;
    await _sendFile(r.path, type: 'video_note', name: 'video_message.mp4', duration: r.seconds);
  }

  /// Opens the photo editor (crop, rotate, draw, text) before sending one photo.
  Future<void> _editAndSend(String path, String name) async {
    if (!mounted) return;
    final edited = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => ImageEditorScreen(path: path)));
    if (edited == null) return;
    await _sendFile(edited, type: 'image', name: edited == path ? name : 'photo.jpg');
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
                            color: m.myReaction == e ? Brand.primary.withValues(alpha: 0.15) : null,
                          ),
                          child: Text(e, style: const TextStyle(fontSize: 24)),
                        ),
                      ))
                  .toList(),
            ),
          ),
          // quick actions
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Row(children: [
              if (chat.canPost) _quick(ctx, Icons.reply_rounded, 'Reply', 'reply'),
              if (m.text.isNotEmpty) _quick(ctx, Icons.copy_rounded, 'Copy', 'copy'),
              if (m.type != 'poll' && m.type != 'call') _quick(ctx, Icons.shortcut_rounded, 'Forward', 'forward'),
              _quick(ctx, Icons.alarm_add_rounded, 'Remind', 'remind'),
            ]),
          ),
          const Divider(height: 1),
          if (chat.type == 'private' || chat.isAdmin)
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: Text(chat.pinnedMessage?.id == m.id ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.pop(ctx, chat.pinnedMessage?.id == m.id ? 'unpin' : 'pin'),
            ),
          if (canClosePoll) ListTile(leading: const Icon(Icons.stop_circle_outlined), title: const Text('Stop poll'), onTap: () => Navigator.pop(ctx, 'close_poll')),
          if (canEdit) ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Edit'), onTap: () => Navigator.pop(ctx, 'edit')),
          if (m.editedAt != null) ListTile(leading: const Icon(Icons.history_rounded), title: const Text('Edit history'), onTap: () => Navigator.pop(ctx, 'history')),
          ListTile(leading: const Icon(Icons.delete_outline_rounded, color: Colors.red), title: const Text('Delete', style: TextStyle(color: Colors.red)), onTap: () => Navigator.pop(ctx, 'delete')),
          if (!mine && !channelAdmin) ListTile(leading: const Icon(Icons.flag_outlined), title: const Text('Report'), onTap: () => Navigator.pop(ctx, 'report')),
        ]),
      ),
    );
    if (!mounted || a == null) return;
    if (a.startsWith('react:')) {
      final e = a.substring(6);
      if (m.myReaction != e) showReactionBurst(context, e);
      _store.react(m, e).catchError((err) {
        if (mounted) showError(context, err);
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
      case 'history':
        await showEditHistory(context, m);
        break;
      case 'remind':
        await pickReminder(context, chat, m);
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
        case 'disappearing':
          final secs = await showModalBottomSheet<int>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('New messages in this chat will delete themselves after:', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                for (final o in const [0, 3600, 86400, 604800, 7776000])
                  RadioListTile<int>(
                    value: o,
                    groupValue: chat.disappearAfterSec,
                    title: Text(o == 0 ? 'Off' : disappearLabel(o)),
                    onChanged: (v) => Navigator.pop(ctx, v),
                  ),
              ]),
            ),
          );
          if (secs != null && secs != chat.disappearAfterSec) await _store.setDisappearing(chatId, secs);
          break;
        case 'export':
          await exportChat(context, chat);
          break;
        case 'media':
          await Navigator.push(context, MaterialPageRoute(builder: (_) => SharedMediaScreen(chat: chat)));
          break;
        case 'theme':
          await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatThemeScreen(chatId: chat.id, title: chat.title)));
          break;
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
    final all = store.messagesOf(chatId);
    // My Notes: #tags to filter notes
    final tags = (chat.isSavedMessages) ? tagsIn(all) : const <String>[];
    if (_tag != null && !tags.contains(_tag)) _tag = null;
    final messages = _tag == null ? all : all.where((m) => messageHasTag(m, _tag!)).toList();
    final typing = store.typingText(chat);
    final auth = context.watch<AuthState>();
    String subtitle;
    if (chat.isBot) {
      subtitle = 'bot';
    } else if (typing != null) {
      subtitle = typing;
    } else if (chat.isMulti) {
      subtitle = chat.isChannel ? '${chat.memberCount} subscribers' : '${chat.memberCount} members';
    } else if (chat.peer != null) {
      subtitle = lastSeenText(chat.peer!);
    } else {
      subtitle = '';
    }

    final look = context.watch<AppPrefs>().chatAppearance(chatId);
    return PopScope(
      canPop: !_emojiOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _emojiOpen) setState(() => _emojiOpen = false);
      },
      child: ChatThemeScope(
      appearance: look,
      child: Scaffold(
      backgroundColor: ChatColors.of(context).background,
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => _openInfo(chat),
          child: Row(
            children: [
              Stack(clipBehavior: Clip.none, children: [
                Avatar(id: chat.id, name: chat.title, url: chat.avatarAbsolute, size: 40, icon: chat.isSavedMessages ? Icons.bookmark_rounded : null),
                if (chat.peer?.online == true && !chat.isSavedMessages && !chat.isBot)
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        color: Brand.accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: Theme.of(context).appBarTheme.backgroundColor ?? Theme.of(context).scaffoldBackgroundColor, width: 2),
                      ),
                    ),
                  ),
              ]),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(child: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, letterSpacing: -0.2))),
                      if (chat.isVerified) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified_rounded, size: 16, color: Brand.sky)),
                      if (chat.peer?.isPremium == true) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.star_rounded, size: 18, color: Brand.premium)),
                    ]),
                    if (typing != null)
                      Row(children: [
                        Flexible(
                          child: Text(typing.replaceAll('…', ''),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Brand.primary)),
                        ),
                        const SizedBox(width: 4),
                        const TypingDots(size: 4),
                      ])
                    else if (subtitle.isNotEmpty)
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: typing != null || chat.peer?.online == true ? FontWeight.w600 : FontWeight.w500,
                              color: typing != null ? Brand.primary : (chat.peer?.online == true ? Brand.accent : Brand.muted))),
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
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.videocam_outlined),
                onPressed: () => startCall(context, chat.peer!, video: true),
              ),
            IconButton(
              tooltip: 'Call',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.call_outlined),
              onPressed: () => startCall(context, chat.peer!, video: false),
            ),
          ],
          PopupMenuButton<String>(
            onSelected: (a) => _chatMenu(a, chat),
            itemBuilder: (_) => [
              _mi('mute', chat.isMuted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, chat.isMuted ? 'Unmute' : 'Mute'),
              _mi('media', Icons.perm_media_outlined, 'Shared media'),
              _mi('theme', Icons.palette_outlined, 'Theme & wallpaper'),
              if (auth.feature('disappearing') && !chat.isChannel && (chat.peer != null || chat.isAdmin) && !chat.isSavedMessages)
                _mi('disappearing', Icons.timer_outlined, chat.disappearAfterSec > 0 ? 'Disappearing: ${disappearLabel(chat.disappearAfterSec)}' : 'Disappearing messages'),
              if (chat.canPost) _mi('scheduled', Icons.schedule_send_outlined, 'Scheduled messages'),
              if (chat.isMulti && chat.isAdmin) _mi('stats', Icons.insights_outlined, 'Statistics'),
              if (chat.peer != null && !chat.isSavedMessages && !chat.peer!.deleted && !chat.isBot && auth.feature('secret_chats'))
                _mi('secret', Icons.lock_outline_rounded, 'Start vault chat'),
              _mi('export', Icons.ios_share_rounded, 'Export chat'),
              const PopupMenuDivider(),
              _mi('clear', Icons.cleaning_services_outlined, 'Clear history'),
              if (chat.peer != null) _mi('block', Icons.block_rounded, chat.peer!.blocked ? 'Unblock user' : 'Block user', danger: !chat.peer!.blocked),
              if (!chat.isSavedMessages) _mi('report', Icons.flag_outlined, 'Report'),
              _mi('leave', Icons.logout_rounded, chat.isChannel ? 'Leave channel' : (chat.isGroup ? 'Leave group' : 'Delete chat'), danger: true),
            ],
          ),
        ],
      ),
      body: ChatBackground(
        appearance: look,
        child: Column(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: store.connected
                ? const SizedBox(width: double.infinity)
                : Container(
                    margin: const EdgeInsets.fromLTRB(0, 6, 0, 2),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Brand.amber.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.8, color: Color(0xFFB7791F))),
                      SizedBox(width: 8),
                      Text('Connecting…', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFFB7791F))),
                    ]),
                  ),
          ),
          if (chat.pinnedMessage != null) _pinnedBar(chat),
          if (tags.isNotEmpty)
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                children: [
                  for (final t in [null, ...tags])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: ChoiceChip(
                        label: Text(t == null ? 'All notes' : '#$t'),
                        selected: _tag == t,
                        onSelected: (_) => setState(() => _tag = t),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(child: _messageList(chat, messages, store)),
          _bottomBar(chat),
        ],
      ),
      ),
    ),
    ),
    );
  }

  Widget _messageList(Chat chat, List<Message> messages, ChatStore store) {
    if (_loading && messages.isEmpty) return const Center(child: CircularProgressIndicator());
    if (messages.isEmpty && chat.isBot) {
      return BotIntro(chat: chat, onStart: () => _store.sendText(chatId, '/start'));
    }
    if (messages.isEmpty) {
      if (_error != null) return Center(child: SystemBubble(text: _error!));
      return Center(child: _emptyChat(chat));
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
        if (m.albumId != null && i > 0 && messages[i - 1].albumId == m.albumId) {
          return const SizedBox.shrink(); // drawn as part of the album below
        }
        final older0 = i + 1 < messages.length ? messages[i + 1] : null;
        if (m.albumId != null && older0?.albumId == m.albumId) {
          var j = i;
          while (j + 1 < messages.length && messages[j + 1].albumId == m.albumId) {
            j++;
          }
          final items = messages.sublist(i, j + 1).reversed.toList();
          final mineA = chat.isChannel ? m.isLocal : m.senderId == store.myId;
          return AlbumBubble(
            key: ValueKey('album-${m.albumId}'),
            items: items,
            isMine: mineA,
            senderName: chat.isGroup && !mineA ? m.sender?.name : null,
            onLongPress: () => _messageMenu(m, chat),
          );
        }
        final older = older0;
        final newDay = older == null ||
            older.createdAt.year != m.createdAt.year ||
            older.createdAt.month != m.createdAt.month ||
            older.createdAt.day != m.createdAt.day;
        final mine = chat.isChannel ? m.isLocal : m.senderId == store.myId;
        // stacks: same sender, same day, less than 5 minutes apart
        bool joined(Message? a, Message b) =>
            a != null &&
            !a.isSystem &&
            a.senderId == b.senderId &&
            a.albumId == null &&
            a.createdAt.year == b.createdAt.year &&
            a.createdAt.month == b.createdAt.month &&
            a.createdAt.day == b.createdAt.day &&
            a.createdAt.difference(b.createdAt).inMinutes.abs() < 5;
        final newer = i > 0 ? messages[i - 1] : null;
        final first = newDay || !joined(older, m);
        final last = !joined(newer, m) ||
            (newer != null && (newer.createdAt.year != m.createdAt.year || newer.createdAt.month != m.createdAt.month || newer.createdAt.day != m.createdAt.day));
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
                firstInGroup: first,
                lastInGroup: last,
                showAvatar: last && chat.isGroup && !mine,
                onLongPress: () => _messageMenu(m, chat),
                onTap: m.sendState == SendState.failed ? () => _messageMenu(m, chat) : null,
              ),
          ],
        );
      },
    );
  }

  /// A fresh chat: a friendly card with Tali and one-tap greetings.
  Widget _emptyChat(Chat chat) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final canSend = !chat.isChannel || chat.canPost;
    return SingleChildScrollView(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: dark ? Colors.black.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(26),
          boxShadow: dark ? null : [BoxShadow(color: Brand.ink.withValues(alpha: 0.08), blurRadius: 24, offset: const Offset(0, 8))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Image.asset('assets/emoji/tali/${chat.isSavedMessages ? 'think' : 'hello'}.png', width: 110, height: 110),
          const SizedBox(height: 10),
          Text(chat.isSavedMessages ? 'Your notes' : 'No messages yet',
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            chat.isSavedMessages
                ? 'Save notes, links and files here. Add #tags to find them later, or send a checklist.'
                : (canSend ? 'Send a message or tap a greeting below.' : 'Nothing has been posted yet.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.35, fontSize: 13.5),
          ),
          if (canSend && !chat.isSavedMessages) ...[
            const SizedBox(height: 14),
            Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
              for (final g in ['👋 Hi!', 'Hello 🙂', '${taliChar(0)} Hey'])
                ActionChip(
                  label: Text.rich(TextSpan(children: taliSpans(g, const TextStyle(fontWeight: FontWeight.w700)))),
                  onPressed: () => _store.sendText(chatId, g),
                ),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _pinnedBar(Chat chat) {
    final p = chat.pinnedMessage!;
    return Material(
      color: ChatColors.of(context).bar,
      child: InkWell(
        onTap: () => _showPins(chat),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.5)))),
          child: Row(children: [
            Container(width: 3, height: 34, decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(chat.pinnedCount > 1 ? 'Pinned message (${chat.pinnedCount})' : 'Pinned message',
                    style: const TextStyle(color: Brand.primary, fontWeight: FontWeight.w600, fontSize: 13)),
                Text(taliToPlain(p.preview), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              ]),
            ),
            if (chat.type == 'private' || chat.isAdmin)
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
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

  void _toggleEmoji() {
    if (_emojiOpen) {
      setState(() => _emojiOpen = false);
      _focus.requestFocus();
    } else {
      _focus.unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
      setState(() => _emojiOpen = true);
    }
  }

  /// The rounded message field: emoji / text / attach / camera, like modern messengers.
  Widget _inputPill(Chat chat) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = dark ? Colors.white70 : Brand.muted;
    final empty = _text.text.trim().isEmpty;
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1C2033) : Colors.white,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: dark ? Colors.white10 : const Color(0xFFE3E6EF)),
        boxShadow: dark ? null : [BoxShadow(color: Brand.ink.withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        IconButton(
          tooltip: _emojiOpen ? 'Keyboard' : 'Emoji, stickers & GIFs',
          icon: Icon(_emojiOpen ? Icons.keyboard_rounded : Icons.emoji_emotions_outlined, color: iconColor, size: 26),
          onPressed: _toggleEmoji,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: TextField(
              controller: _text,
              focusNode: _focus,
              minLines: 1,
              maxLines: 6,
              maxLength: 4096,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 16.5, height: 1.35),
              onTap: () {
                if (_emojiOpen) setState(() => _emojiOpen = false);
              },
              decoration: InputDecoration(
                hintText: chat.slowModeSec > 0 && !chat.isAdmin ? 'Message (slow mode: ${chat.slowModeSec}s)' : 'Message',
                hintStyle: TextStyle(color: iconColor, fontSize: 16.5),
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                counterText: '',
              ),
              onChanged: (v) {
                if (v.isNotEmpty) _store.sendTyping(chatId);
                setState(() {});
              },
            ),
          ),
        ),
        if (_editing == null)
          IconButton(
            tooltip: 'Attach',
            icon: Transform.rotate(angle: -0.6, child: Icon(Icons.attach_file_rounded, color: iconColor, size: 25)),
            onPressed: () => _attach(),
          ),
        if (_editing == null && empty)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: IconButton(
              tooltip: 'Camera',
              icon: Icon(Icons.photo_camera_outlined, color: iconColor, size: 25),
              onPressed: () => _attach('camera'),
            ),
          ),
      ]),
    );
  }

  Widget _roundAction({required IconData icon, required String tooltip, required VoidCallback onTap}) => Tooltip(
        message: tooltip,
        child: Material(
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: Ink(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: Brand.aurora,
              boxShadow: [BoxShadow(color: Brand.rose.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: InkWell(
              onTap: onTap,
              child: Icon(icon, color: Colors.white, size: 24),
            ),
          ),
        ),
      );

  Widget _emojiPanel() {
    final auth = context.read<AuthState>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF12152A) : Colors.white;
    // wait until the keyboard has gone down (both at once would not fit)
    if (MediaQuery.viewInsetsOf(context).bottom > 0) return const SizedBox.shrink();
    // small phones: keep room for the messages above
    final pickerH = (MediaQuery.of(context).size.height * 0.25).clamp(140.0, 300.0);
    final tabs = <(IconData, String, int)>[
      (Icons.emoji_emotions_rounded, 'Emoji', 0),
      if (auth.feature('stickers')) (Icons.sticky_note_2_rounded, 'Stickers', 1),
      if (auth.feature('gifs')) (Icons.gif_box_rounded, 'GIFs', 2),
    ];
    if (!tabs.any((t) => t.$3 == _panelTab)) _panelTab = 0;
    final selected = tabs.indexWhere((t) => t.$3 == _panelTab);
    final Widget body;
    switch (_panelTab) {
      case 1:
        body = SizedBox(height: pickerH + 55, child: StickerPanel(chatId: chatId));
        break;
      case 2:
        body = SizedBox(
          height: pickerH + 55,
          child: GifPanel(
            chatId: chatId,
            onSearchTap: () {
              setState(() => _emojiOpen = false);
              showStickerGifSheet(context, chatId, openGifs: true);
            },
          ),
        );
        break;
      default:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          TaliEmojiStrip(onPick: (c) => setState(() => _text.insert(c))),
          Divider(height: 1, color: dark ? Colors.white10 : const Color(0xFFE9ECF3)),
          SizedBox(
            height: pickerH,
            child: EmojiPicker(
              textEditingController: _text,
              onEmojiSelected: (_, __) => setState(() {}),
              onBackspacePressed: () => setState(() {}),
              config: Config(
                height: pickerH,
                checkPlatformCompatibility: true,
                emojiViewConfig: EmojiViewConfig(
                  backgroundColor: bg,
                  columns: 8,
                  emojiSizeMax: 28,
                  recentsLimit: 32,
                  gridPadding: const EdgeInsets.symmetric(horizontal: 6),
                  noRecents: const Text('No recent emoji', style: TextStyle(fontSize: 15, color: Brand.muted)),
                ),
                categoryViewConfig: CategoryViewConfig(
                  backgroundColor: bg,
                  indicatorColor: Brand.primary,
                  iconColorSelected: Brand.primary,
                  iconColor: Brand.muted,
                  dividerColor: Colors.transparent,
                  extraTab: CategoryExtraTab.BACKSPACE,
                  backspaceColor: Brand.muted,
                ),
                skinToneConfig: SkinToneConfig(dialogBackgroundColor: bg, indicatorColor: Brand.muted),
                bottomActionBarConfig: BottomActionBarConfig(
                  showBackspaceButton: false,
                  backgroundColor: bg,
                  buttonColor: bg,
                  buttonIconColor: Brand.muted,
                ),
                searchViewConfig: SearchViewConfig(backgroundColor: bg, buttonIconColor: Brand.muted),
              ),
            ),
          ),
        ]);
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: dark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFE9ECF3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: KeyedSubtree(key: ValueKey(_panelTab), child: body)),
        if (tabs.length > 1)
          PanelTabs(
            tabs: [for (final t in tabs) (t.$1, t.$2)],
            selected: selected,
            onSelect: (i) => setState(() => _panelTab = tabs[i].$3),
          ),
      ]),
    );
  }

  Widget _quick(BuildContext ctx, IconData icon, String label, String value) => Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.pop(ctx, value),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: Brand.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(15)),
                child: Icon(icon, color: Brand.primary),
              ),
              const SizedBox(height: 5),
              Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );

  PopupMenuItem<String> _mi(String value, IconData icon, String text, {bool danger = false}) => PopupMenuItem<String>(
        value: value,
        height: 44,
        child: Row(children: [
          Icon(icon, size: 20, color: danger ? Colors.red : Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Flexible(child: Text(text, style: TextStyle(color: danger ? Colors.red : null))),
        ]),
      );

  Widget _requestBar(Chat chat) {
    Future<void> act(Future<void> Function() f, {bool close = true}) async {
      try {
        await f();
        if (close && mounted) Navigator.pop(context);
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }

    return SafeArea(
      top: false,
      child: Container(
        color: ChatColors.of(context).bar,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${chat.title} is not in your contacts', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          const Text('Accept to reply and get notifications from this chat.', textAlign: TextAlign.center, style: TextStyle(color: Brand.muted, fontSize: 13)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red, minimumSize: const Size.fromHeight(46)),
                onPressed: () async {
                  final ok = await confirm(context, 'Block ${chat.title}?', 'They won\'t be able to message you, and the chat is reported as spam.', ok: 'Block & report', danger: true);
                  if (ok) await act(() => _store.declineRequest(chatId, block: true, report: true));
                },
                child: const Text('Block'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                onPressed: () => act(() => _store.declineRequest(chatId)),
                child: const Text('Delete'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(46)),
                onPressed: () => act(() => _store.acceptRequest(chatId), close: false),
                child: const Text('Accept'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _bottomBar(Chat chat) {
    if (chat.isRequest) return _requestBar(chat);
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
            Text(blockedText, textAlign: TextAlign.center, style: const TextStyle(color: Brand.muted)),
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
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: banner == null
                  ? const SizedBox(width: double.infinity)
                  : Container(
                      margin: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark ? Colors.white.withValues(alpha: 0.06) : Brand.primary.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: IntrinsicHeight(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Container(width: 4, decoration: const BoxDecoration(gradient: Brand.aurora)),
                          const SizedBox(width: 10),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Icon(_editing != null ? Icons.edit_rounded : Icons.reply_rounded, color: Brand.primary, size: 22),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                                Text(
                                  _editing != null ? 'Edit message' : 'Reply to ${banner.sender?.name ?? _store.userName(banner.senderId)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Brand.primary, fontWeight: FontWeight.w700, fontSize: 13),
                                ),
                                const SizedBox(height: 1),
                                Text(taliToPlain(banner.preview), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                              ]),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 20),
                            tooltip: 'Cancel',
                            onPressed: () => setState(() {
                              if (_editing != null) _text.clear();
                              _editing = null;
                              _replyTo = null;
                            }),
                          ),
                        ]),
                      ),
                    ),
            ),
            if (_recording)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 0, 2),
                child: Row(children: [
                  Expanded(
                    child: Container(
                      height: 52,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1C2033) : Colors.white,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.25)),
                      ),
                      child: Row(children: [
                        const RecordingDot(),
                        const SizedBox(width: 10),
                        Text(duration(_recSeconds), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
                        const SizedBox(width: 12),
                        const Expanded(child: RecordingWave()),
                        TextButton(
                          onPressed: () => _stopRecording(send: false),
                          style: TextButton.styleFrom(foregroundColor: Colors.red),
                          child: const Text('Cancel'),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _roundAction(icon: Icons.send_rounded, tooltip: 'Send voice message', onTap: () => _stopRecording(send: true)),
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
                  if (_editing != null) const SizedBox(width: 4),
                  Expanded(child: _inputPill(chat)),
                  const SizedBox(width: 6),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: child)),
                    child: _text.text.trim().isNotEmpty || _editing != null || !context.read<AuthState>().feature('voice_messages')
                        ? GestureDetector(
                            key: const ValueKey('send'),
                            onLongPress: _editing == null ? _sendOptions : null,
                            child: _roundAction(
                              icon: _editing != null ? Icons.check_rounded : Icons.send_rounded,
                              tooltip: 'Send (hold to schedule)',
                              onTap: _send,
                            ),
                          )
                        : GestureDetector(
                            key: const ValueKey('mic'),
                            onLongPress: _recordVideoNote,
                            child: _roundAction(icon: Icons.mic_rounded, tooltip: 'Voice message (hold for video)', onTap: _startRecording),
                          ),
                  ),
                ],
              ),
            if (_emojiOpen && !_recording) _emojiPanel(),
          ],
        ),
      ),
    );
  }
}
