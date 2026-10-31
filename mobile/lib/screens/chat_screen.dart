import 'voice_chat_screen.dart';
import '../state/voice_chat_manager.dart';
import 'dart:async';
import 'dart:io';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';
import '../widgets/mascot.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shared_media_screen.dart';
import 'business_screen.dart' show QuickReplies;
import 'chat_theme_screen.dart';
import '../theme/chat_theme.dart';
import '../widgets/video_note.dart';
import '../widgets/tali_emoji.dart';
import '../widgets/emoji_bar.dart';
import '../widgets/message_menu.dart';
import 'global_search_screen.dart';
import '../config.dart';
import '../widgets/premium.dart';
import '../widgets/voice_mini_player.dart';
import '../widgets/message_effects.dart';
import '../widgets/message_extras.dart';
import '../core/message_notifications.dart';
import '../core/voice_playback.dart';
import '../core/chat_lock.dart';
import '../core/screen_guard.dart';
import '../core/chat_passcode.dart';
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
import 'home_screen.dart' show activityIcon;
import 'premium_screens.dart';
import 'image_editor_screen.dart';
import 'album_send_screen.dart';
import 'video_send_screen.dart';
import 'live_map_screen.dart';
import '../widgets/swipe_reply.dart';
import '../widgets/media_widgets.dart' show VoiceWavePainter, resampleBars;
import '../widgets/album_view.dart';
import 'thread_screen.dart';
import '../widgets/bot_widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'secret_screens.dart';
import 'channel_screens.dart';
import 'forward_screen.dart';
import 'group_info_screen.dart';
import 'group_admin_screens.dart';
import 'user_profile_screen.dart';
import '../theme/brand.dart';
import '../core/chat_export.dart';
import '../widgets/sticker_widgets.dart';
import '../widgets/contact_card.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chatId, this.initial, this.quote});

  final int chatId;
  final Chat? initial;

  /// Private reply: a group message to answer in this private chat.
  final Message? quote;

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
  final _msgKeys = <int, GlobalKey>{};
  int? _flashId; // briefly highlighted after jumping to it
  bool _slashShown = false; // quick replies panel was showing

  /// Tap on a reply: scroll to the original message (loading older ones if needed) and light it up.
  Future<void> _jumpToMessage(int id) async {
    var list = _store.messagesOf(chatId);
    var tries = 0;
    while (!list.any((x) => x.id == id) && _store.hasMore(chatId) && tries < 15) {
      tries++;
      await _store.loadMore(chatId);
      list = _store.messagesOf(chatId);
    }
    if (!mounted) return;
    final index = list.indexWhere((x) => x.id == id);
    if (index < 0) {
      showInfo(context, 'The original message is no longer available');
      return;
    }
    // the list is built lazily: move towards it until it is on screen, then centre it
    for (var step = 0; step < 60 && _msgKeys[id]?.currentContext == null; step++) {
      if (!_scroll.hasClients) break;
      final pos = _scroll.position;
      final target = (pos.pixels + pos.viewportDimension * 0.9).clamp(0.0, pos.maxScrollExtent);
      if (target == pos.pixels) break;
      _scroll.jumpTo(target);
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    final ctx = _msgKeys[id]?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
    if (!mounted) return;
    setState(() => _flashId = id);
    HapticFeedback.selectionClick();
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (mounted && _flashId == id) setState(() => _flashId = null);
    });
  }
  String? _emojiOnly; // the message box holds exactly one emoji
  bool _unlocked = ChatLock.isOpen; // locked chats: fingerprint first
  final Set<int> _selected = {}; // multi-select (message ids)
  Message? _quote; // private reply
  StreamSubscription<String>? _noticeSub;
  int _panelTab = 0; // emoji panel: 0 emoji · 1 stickers · 2 GIFs
  String? _tag; // My Notes tag filter
  final _scroll = ScrollController();
  Message? _replyTo;
  Message? _editing;

  final _recorder = AudioRecorder();
  bool _recording = false;
  bool _recPaused = false;
  int _recSeconds = 0;
  StreamSubscription<Amplitude>? _ampSub;
  // voice review (listen before sending)
  String? _reviewPath;
  int _reviewSeconds = 0;
  List<int>? _reviewWave;
  bool _reviewOnce = false;
  final _preview = AudioPlayer();
  StreamSubscription<(int, String)>? _fxSub;
  final List<double> _levels = []; // loudness 0..1, ~every 100 ms (live bars + the waveform we send)
  Timer? _recTimer;

  int get chatId => widget.chatId;

  Map<String, dynamic>? _ad; // sponsored message under a channel
  bool _adSeen = false;

  bool _guarded = false;

  // floating glass header & message bar: their heights pad the message list
  static const double _headerH = 66;
  double _topH = 0;
  double _bottomH = 72;

  /// Header: one frosted capsule — back, avatar + name, actions.
  PreferredSizeWidget _glassHeader({required Widget title, required List<Widget> actions}) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(_headerH),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
          child: GlassPanel(
            radius: 26,
            child: SizedBox(
              height: 54,
              child: IconTheme.merge(
                data: IconThemeData(color: Theme.of(context).colorScheme.onSurface),
                child: Row(children: [
                  IconButton(
                    tooltip: 'Back',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  Expanded(child: DefaultTextStyle.merge(style: TextStyle(color: Theme.of(context).colorScheme.onSurface), child: title)),
                  ...actions,
                  const SizedBox(width: 2),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // "jump to the newest message" button, with how many came in while scrolled up
  bool _showDown = false;
  int _newBelow = 0;
  int? _newestSeen;

  int? _online; // groups: members online now
  bool _formatOpen = false; // the B / I / S / code / spoiler bar above the message box

  // ---- bot inline mode: "@goldprice_bot 24k" → the bot's results above the message box
  static final _inlineRe = RegExp(r'^@([A-Za-z][A-Za-z0-9_]{1,30}bot) (.*)$', caseSensitive: false, dotAll: true);
  Timer? _inlineDebounce;
  String? _inlineKey; // "<bot>|<query>" of the last request
  Map<String, dynamic>? _inline; // {bot, query_id, results}
  bool _inlineLoading = false;

  Widget _quickRepliesPanel() {
    final list = QuickReplies.match(_text.text);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1C2036) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.3 : 0.08), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 4), children: [
        for (final r in list)
          ListTile(
            dense: true,
            leading: const CircleAvatar(radius: 16, backgroundColor: Color(0x1FF2557E), child: Icon(Icons.bolt_rounded, size: 18, color: Brand.primary)),
            title: Text('/${r['shortcut']}', style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text('${r['text']}', maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              final t = '${r['text']}';
              _text.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
              setState(() {});
            },
          ),
      ]),
    );
  }

  void _onInlineText() {
    final m = _inlineRe.firstMatch(_text.text);
    if (m == null || _editing != null) {
      if (_inline != null || _inlineLoading) setState(() {
        _inline = null;
        _inlineLoading = false;
        _inlineKey = null;
      });
      return;
    }
    final key = '${m.group(1)!.toLowerCase()}|${m.group(2)!.trim()}';
    if (key == _inlineKey) return;
    _inlineDebounce?.cancel();
    _inlineDebounce = Timer(const Duration(milliseconds: 450), () async {
      _inlineKey = key;
      if (mounted) setState(() => _inlineLoading = true);
      try {
        final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/bots/inline', query: {'username': m.group(1)!, 'q': m.group(2)!.trim()}) as Map);
        if (!mounted || _inlineKey != key) return;
        setState(() {
          _inline = r['bot'] == null ? null : r;
          _inlineLoading = false;
        });
      } catch (_) {
        if (mounted && _inlineKey == key) setState(() => _inlineLoading = false);
      }
    });
  }

  Future<void> _sendInline(Map<String, dynamic> result) async {
    final inline = _inline;
    if (inline == null) return;
    final reply = _replyTo;
    setState(() {
      _inline = null;
      _inlineKey = null;
      _replyTo = null;
      _text.clear();
    });
    try {
      await context.read<AppServices>().api.post('/bots/inline/send', {
        'query_id': inline['query_id'],
        'result_id': result['id'],
        'chat_id': chatId,
        if (reply != null) 'reply_to_id': reply.id,
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _inlinePanel() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final inline = _inline;
    final results = ((inline?['results'] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final bot = inline?['bot'] as Map?;
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1A1F35).withValues(alpha: 0.98) : Colors.white.withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Row(children: [
            const Icon(Icons.smart_toy_rounded, size: 16, color: Brand.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                bot == null ? 'Asking the bot…' : '@${bot['username']}${(bot['placeholder'] ?? '').toString().isNotEmpty ? ' · ${bot['placeholder']}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Brand.muted),
              ),
            ),
            if (_inlineLoading) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
        ),
        if (!_inlineLoading && results.isEmpty)
          const Padding(padding: EdgeInsets.fromLTRB(14, 4, 14, 14), child: Text('No results', style: TextStyle(color: Brand.muted))),
        Flexible(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 6), children: [
            for (final r in results)
              ListTile(
                dense: true,
                leading: r['thumb_url'] != null
                    ? ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network('${r['thumb_url']}', width: 40, height: 40, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.article_outlined)))
                    : Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.article_rounded, color: Colors.white, size: 20),
                      ),
                title: Text('${r['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                subtitle: '${r['description'] ?? ''}'.isEmpty ? null : Text('${r['description']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => _sendInline(r),
              ),
          ]),
        ),
      ]),
    );
  }

  /// Puts [mark] around the selected text (or removes it when it's already there).
  void _wrapSelection(String mark) {
    final sel = _text.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final t = _text.text;
    final before = sel.textBefore(t);
    final inner = sel.textInside(t);
    final after = sel.textAfter(t);
    if (before.endsWith(mark) && after.startsWith(mark)) {
      final b = before.substring(0, before.length - mark.length);
      _text.value = TextEditingValue(
        text: '$b$inner${after.substring(mark.length)}',
        selection: TextSelection(baseOffset: b.length, extentOffset: b.length + inner.length),
      );
    } else {
      _text.value = TextEditingValue(
        text: '$before$mark$inner$mark$after',
        selection: TextSelection(baseOffset: before.length + mark.length, extentOffset: before.length + mark.length + inner.length),
      );
    }
    HapticFeedback.selectionClick();
    setState(() {});
  }

  Widget _formatBar() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget b(String tip, Widget child, String mark) => Tooltip(
          message: tip,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _wrapSelection(mark),
            child: SizedBox(width: 44, height: 38, child: Center(child: child)),
          ),
        );
    const st = TextStyle(fontSize: 17);
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1A1F35).withValues(alpha: 0.97) : Colors.white.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Row(children: [
        b('Bold', const Text('B', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)), '**'),
        b('Italic', const Text('I', style: TextStyle(fontSize: 17, fontStyle: FontStyle.italic, fontWeight: FontWeight.w600)), '_'),
        b('Strikethrough', const Text('S', style: TextStyle(fontSize: 17, decoration: TextDecoration.lineThrough, fontWeight: FontWeight.w600)), '~'),
        b('Monospace', const Text('</>', style: TextStyle(fontSize: 14, fontFamily: 'monospace', fontWeight: FontWeight.w700)), '`'),
        b('Spoiler', const Icon(Icons.blur_on_rounded, size: 20), '||'),
        const Spacer(),
        Text('Format', style: st.copyWith(fontSize: 12.5, color: Brand.muted, fontWeight: FontWeight.w700)),
        IconButton(
          tooltip: 'Close',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close_rounded, size: 18),
          onPressed: () => setState(() => _formatOpen = false),
        ),
      ]),
    );
  }

  /// Groups with rules: show them once when I first open the group (and again when they change).
  Future<void> _showRulesOnce() async {
    final chat = _store.chatById(chatId) ?? _chat;
    if (chat == null || chat.rules.trim().isEmpty || chat.isAdmin) return;
    final key = 'rules.seen.${chat.id}';
    final sig = '${chat.rules.hashCode}';
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getString(key) == sig || !mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Center(child: AppMascot(pose: TaviPose.think, size: 96)),
              Text('Rules of ${chat.title}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.45),
                child: SingleChildScrollView(child: Text(chat.rules, style: const TextStyle(fontSize: 15, height: 1.45))),
              ),
              const SizedBox(height: 16),
              AuroraButton(label: 'I agree', icon: Icons.check_rounded, onPressed: () => Navigator.pop(ctx)),
            ]),
          ),
        ),
      );
      await p.setString(key, sig);
    } catch (_) {}
  }

  Future<void> _loadOnline() async {
    try {
      final r = await context.read<AppServices>().api.get('/chats/$chatId/online') as Map;
      if (mounted) setState(() => _online = (r['online'] as num?)?.toInt());
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ((_store.chatById(chatId) ?? _chat)?.isGroup ?? false)) {
        _loadOnline();
        _showRulesOnce();
      }
    });
    _store = context.read<ChatStore>();
    _prefs = context.read<AppPrefs>();
    _chat = widget.initial;
    _text.text = _prefs.draft(widget.chatId) ?? '';
    _text.addListener(_onInlineText);
    QuickReplies.load(context.read<AppServices>());
    _text.addListener(() {
      final t = _text.text.trim();
      final one = t.isNotEmpty && t.length <= 16 && bigEmojiCount(t) == 1 ? t : null;
      if (one != _emojiOnly && mounted) setState(() => _emojiOnly = one);
      final slash = _text.text.startsWith('/') && QuickReplies.list.isNotEmpty;
      if ((slash || _slashShown) && mounted) setState(() => _slashShown = slash);
      if (_formatOpen && (!_text.selection.isValid || _text.selection.isCollapsed) && mounted) setState(() => _formatOpen = false);
    });
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
        _store.loadMore(chatId).catchError((_) {});
      }
      final down = _scroll.hasClients && _scroll.position.pixels > 600;
      if (down != _showDown) {
        setState(() {
          _showDown = down;
          if (!down) _newBelow = 0;
        });
      }
    });
    _open();
    MessageNotifications.clearChat(widget.chatId);
    _quote = widget.quote;
    _noticeSub = _store.notices.stream.listen((t) {
      if (mounted) showInfo(context, t);
    });
    _fxSub = _store.effects.stream.listen((e) {
      if (e.$1 == chatId && mounted) playMessageEffect(context, e.$2);
    });
    _preview.playerStateStream.listen((st) {
      if (st.processingState == ProcessingState.completed) {
        _preview.pause();
        _preview.seek(Duration.zero);
      }
    });
  }

  Future<void> _open() async {
    try {
      _chat = await _store.getChat(chatId);
      final unread = _chat!.unreadCount;
      await _store.openChat(chatId);
      _placeUnreadMarker(unread);
      if (_chat!.isGroup) _store.loadMembers(chatId).catchError((_) => <GroupMember>[]);
      if (_chat!.isChannel && _chat!.isPublic && mounted) _loadAd();
      if (mounted) WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowRules());
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Groups with rules: shown once (again when the rules change) with "I agree".
  Future<void> _maybeShowRules() async {
    final chat = _store.chatById(chatId) ?? _chat;
    if (chat == null || !chat.isMulti || chat.rules.trim().isEmpty || chat.isAdmin || !mounted) return;
    final key = 'rules_ok_${chat.id}_${chat.rules.hashCode}';
    final sp = await SharedPreferences.getInstance();
    if (sp.getBool(key) == true || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const GradientIcon(Icons.gavel_rounded, color: Brand.violet, size: 40),
                const SizedBox(width: 12),
                Expanded(child: Text('${chat.title} rules', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
              ]),
              const SizedBox(height: 14),
              Flexible(child: SingleChildScrollView(child: MessageText(chat.rules, style: const TextStyle(fontSize: 15, height: 1.45)))),
              const SizedBox(height: 16),
              AuroraButton(label: 'I agree', icon: Icons.check_rounded, onPressed: () => Navigator.pop(ctx)),
            ]),
          ),
        ),
      ),
    );
    await sp.setBool(key, true);
  }

  @override
  void dispose() {
    _inlineDebounce?.cancel();
    if (_guarded) ScreenGuard.release();
    final draft = _editing == null ? _text.text : '';
    if (draft != (_prefs.draft(chatId) ?? '')) _store.syncDraft(chatId, draft);
    _prefs.setDraft(chatId, draft);
    _store.closeChat(chatId);
    _recTimer?.cancel();
    _ampSub?.cancel();
    _fxSub?.cancel();
    _noticeSub?.cancel();
    _preview.dispose();
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
        if (context.read<AuthState>().plusAvailable)
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
  Future<void> _send({bool silent = false, String? effect, bool asDraft = false}) async {
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
    final fx = asDraft ? null : (effect ?? autoEffectFor(text));
    if (fx != null) playMessageEffect(context, fx);
    final quote = _quote;
    if (quote != null) setState(() => _quote = null);
    await _store.sendText(chatId, text, replyTo: reply, silent: silent, effect: effect, quote: quote, asDraft: asDraft);
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
          if ((_store.chatById(chatId) ?? _chat)?.isChannel == true)
            ListTile(
              leading: const Icon(Icons.drafts_outlined),
              title: const Text('Save as draft'),
              subtitle: const Text('Other admins can review and publish it'),
              onTap: () => Navigator.pop(ctx, 'draft'),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Send with effect', style: TextStyle(fontWeight: FontWeight.w700, color: Brand.muted, fontSize: 13)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Row(children: [
              for (final (id, emoji, label) in messageEffects)
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => Navigator.pop(ctx, 'fx:$id'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(children: [
                        Container(
                          width: 50,
                          height: 50,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(gradient: Brand.auroraSoft(Theme.of(ctx).brightness == Brightness.dark), shape: BoxShape.circle),
                          child: Text(emoji, style: const TextStyle(fontSize: 26)),
                        ),
                        const SizedBox(height: 5),
                        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
    if (a != null && a.startsWith('fx:')) await _send(effect: a.substring(3));
    if (a == 'silent') await _send(silent: true);
    if (a == 'draft') await _send(asDraft: true);
    if (a == 'schedule') await _scheduleCurrent();
  }

  bool _kbHidden = false;

  /// The newest bot message that set or removed a reply keyboard → its keyboard (or null).
  Message? _botKeyboard(Chat chat) {
    if (!chat.isBot && !chat.isGroup) return null;
    final msgs = _store.messagesOf(chatId);
    for (var i = 0; i < msgs.length && i < 60; i++) {
      final m = msgs[i]; // newest first
      if (m.removesKeyboard) return null;
      if (m.replyKeyboard != null) return m;
    }
    return null;
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

  Future<void> _sendFile(String path, {required String type, String? name, int? duration, String? albumId, List<int>? waveform, bool viewOnce = false}) async {
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
      waveform: waveform,
      viewOnce: viewOnce,
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
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
              child: GridView(
                // fixed row height: narrow phones and bigger font sizes no longer overflow the tile
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 5, mainAxisSpacing: 6, crossAxisSpacing: 2, mainAxisExtent: 84),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final (key, icon, label, colors) in items)
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => Navigator.pop(ctx, key),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(15),
                            gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
                            boxShadow: [BoxShadow(color: colors.last.withValues(alpha: 0.28), blurRadius: 8, offset: const Offset(0, 3))],
                          ),
                          child: Icon(icon, color: Colors.white, size: 22),
                        ),
                        const SizedBox(height: 6),
                        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, textScaler: MediaQuery.textScalerOf(ctx).clamp(maxScaleFactor: 1.2), style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
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
            // several photos: look through, edit, remove, add more, caption → one album
            if (!mounted) break;
            final r = await Navigator.push<AlbumSendResult>(
              context,
              MaterialPageRoute(
                builder: (_) => AlbumSendScreen(
                  paths: picked.take(10).map((x) => x.path).toList(),
                  caption: _text.text.trim(),
                  imageQuality: _prefs.uploadQuality,
                  maxSide: _prefs.uploadMaxSide,
                ),
              ),
            );
            if (r == null || r.paths.isEmpty) break;
            _text.text = r.caption; // goes with the first photo
            if (r.paths.length == 1) {
              await _sendFile(r.paths.first, type: 'image', name: 'photo.jpg');
              break;
            }
            final albumId = 'a${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${r.paths.length}';
            for (final p in r.paths) {
              await _sendFile(p, type: 'image', name: p.split('/').last, albumId: albumId);
            }
          }
          break;
        case 'camera':
          final x = await picker.pickImage(source: ImageSource.camera, imageQuality: _prefs.uploadQuality, maxWidth: _prefs.uploadMaxSide, maxHeight: _prefs.uploadMaxSide);
          if (x != null) await _editAndSend(x.path, x.name);
          break;
        case 'video':
          final x = await picker.pickVideo(source: ImageSource.gallery);
          if (x != null && mounted) {
            final chat = _store.chatById(chatId) ?? _chat;
            final r = await Navigator.push<VideoSendResult>(
              context,
              MaterialPageRoute(
                builder: (_) => VideoSendScreen(path: x.path, allowViewOnce: !((chat?.isChannel ?? false) || (chat?.isSavedMessages ?? false))),
              ),
            );
            if (r != null) await _sendFile(r.path, type: 'video', name: r.path == x.path ? x.name : 'video.mp4', duration: r.seconds, viewOnce: r.viewOnce);
          }
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
    final chat = _store.chatById(chatId) ?? _chat;
    final once = (chat?.isChannel ?? false) || (chat?.isSavedMessages ?? false) ? null : ValueNotifier(false);
    final edited = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => ImageEditorScreen(path: path, viewOnce: once)));
    if (edited == null) return;
    await _sendFile(edited, type: 'image', name: edited == path ? name : 'photo.jpg', viewOnce: once?.value ?? false);
  }

  // ------------------------------------------------------------------ voice notes
  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) showInfo(context, 'Allow microphone access to record voice messages');
        return;
      }
      if (!mounted) return;
      final vp = context.read<VoicePlayback>();
      if (vp.playing) await vp.pause();
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100), path: path);
      if (!mounted) {
        await _recorder.cancel();
        return;
      }
      HapticFeedback.mediumImpact();
      _levels.clear();
      _ampSub?.cancel();
      _ampSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((a) {
        if (_recPaused || !mounted) return;
        // dBFS (-60 quiet … 0 loud) → 0..1
        setState(() => _levels.add(((a.current + 55) / 55).clamp(0.0, 1.0)));
      });
      setState(() {
        _recording = true;
        _recPaused = false;
        _recSeconds = 0;
      });
      _store.sendTyping(chatId, action: 'recording_voice');
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _recPaused) return;
        setState(() => _recSeconds++);
        if (_recSeconds % 3 == 0) _store.sendTyping(chatId, action: 'recording_voice');
        if (_recSeconds >= 15 * 60) _stopRecording(send: true);
      });
    } catch (e) {
      if (mounted) showInfo(context, 'Could not start recording');
    }
  }

  /// Pause / continue the same voice message.
  Future<void> _togglePause() async {
    try {
      if (_recPaused) {
        await _recorder.resume();
        HapticFeedback.selectionClick();
        _store.sendTyping(chatId, action: 'recording_voice');
      } else {
        await _recorder.pause();
        HapticFeedback.selectionClick();
        _store.sendTyping(chatId, action: 'cancel');
      }
      if (mounted) setState(() => _recPaused = !_recPaused);
    } catch (_) {
      if (mounted) showInfo(context, 'Pause is not supported on this phone');
    }
  }

  /// The loudness bars sent with the voice message (up to 64 values, 0–31).
  List<int> _waveformFromLevels() {
    if (_levels.isEmpty) return const [];
    const n = 64;
    final out = <int>[];
    for (var i = 0; i < n; i++) {
      final a = (i * _levels.length / n).floor();
      final b = (((i + 1) * _levels.length) / n).ceil().clamp(a + 1, _levels.length);
      var peak = 0.0;
      for (var k = a; k < b; k++) {
        if (_levels[k] > peak) peak = _levels[k];
      }
      out.add((peak * 31).round());
    }
    return out;
  }

  /// Stop and listen before sending (the recording can't be continued after this).
  Future<void> _stopForReview() async {
    _recTimer?.cancel();
    await _ampSub?.cancel();
    _ampSub = null;
    final seconds = _recSeconds;
    final wave = _waveformFromLevels();
    _store.sendTyping(chatId, action: 'cancel');
    final path = await _recorder.stop();
    if (!mounted) return;
    setState(() {
      _recording = false;
      _recPaused = false;
    });
    if (path == null || seconds < 1) {
      showInfo(context, 'Hold on a bit longer — the voice message is too short');
      return;
    }
    try {
      await _preview.setFilePath(path);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _reviewPath = path;
      _reviewSeconds = seconds;
      _reviewWave = wave.length >= 8 ? wave : null;
      _reviewOnce = false;
    });
  }

  Future<void> _finishReview({required bool send}) async {
    final path = _reviewPath;
    if (path == null) return;
    await _preview.stop();
    final seconds = _reviewSeconds;
    final wave = _reviewWave;
    final once = _reviewOnce;
    setState(() => _reviewPath = null);
    if (send) {
      await _sendFile(path, type: 'voice', duration: seconds, name: 'voice.m4a', waveform: wave, viewOnce: once);
    } else {
      File(path).delete().catchError((_) => File(path));
    }
  }

  Widget _reviewBar(Chat chat) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bars = resampleBars((_reviewWave ?? const <int>[]).map((e) => e / 31).toList(), 40);
    final canOnce = !chat.isChannel && !chat.isSavedMessages;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 0, 2),
      child: Row(children: [
        Expanded(
          child: Container(
            height: 46,
            padding: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF1C2033) : Colors.white,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: Brand.primary.withValues(alpha: 0.25)),
            ),
            child: Row(children: [
              IconButton(
                tooltip: 'Delete recording',
                icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFE5484D)),
                onPressed: () => _finishReview(send: false),
              ),
              StreamBuilder<PlayerState>(
                stream: _preview.playerStateStream,
                builder: (_, snap) {
                  final st = snap.data;
                  final playing = st?.playing == true && st?.processingState != ProcessingState.completed;
                  return GestureDetector(
                    onTap: () => playing ? _preview.pause() : _preview.play(),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle),
                      child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 22),
                    ),
                  );
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StreamBuilder<Duration>(
                  stream: _preview.positionStream,
                  builder: (_, snap) {
                    final total = _preview.duration?.inMilliseconds ?? _reviewSeconds * 1000;
                    final pos = snap.data ?? Duration.zero;
                    final f = total > 0 ? (pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
                    return Row(children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (_, box) => GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (d) => _preview.seek(Duration(milliseconds: (total * (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)).round())),
                            child: SizedBox(
                              height: 28,
                              child: CustomPaint(
                                size: Size(box.maxWidth, 28),
                                painter: VoiceWavePainter(bars, f, played: Brand.primary, rest: Brand.primary.withValues(alpha: 0.28)),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(duration(pos > Duration.zero ? pos.inSeconds : _reviewSeconds),
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
                    ]);
                  },
                ),
              ),
              if (canOnce)
                IconButton(
                  tooltip: _reviewOnce ? 'View once: on' : 'View once',
                  onPressed: () {
                    setState(() => _reviewOnce = !_reviewOnce);
                    showInfo(context, _reviewOnce ? 'View once: it can be played only one time' : 'View once is off');
                  },
                  icon: ViewOnceIcon(on: _reviewOnce, size: 24, color: Brand.muted),
                ),
            ]),
          ),
        ),
        const SizedBox(width: 6),
        _roundAction(icon: Icons.send_rounded, tooltip: 'Send voice message', onTap: () => _finishReview(send: true)),
      ]),
    );
  }

  Future<void> _stopRecording({required bool send}) async {
    _recTimer?.cancel();
    await _ampSub?.cancel();
    _ampSub = null;
    final seconds = _recSeconds;
    final wave = _waveformFromLevels();
    if (mounted) {
      setState(() {
        _recording = false;
        _recPaused = false;
      });
    }
    _store.sendTyping(chatId, action: 'cancel');
    if (!send) {
      await _recorder.cancel();
      HapticFeedback.lightImpact();
      return;
    }
    final path = await _recorder.stop();
    if (path == null || seconds < 1) {
      if (mounted && seconds < 1) showInfo(context, 'Hold on a bit longer — the voice message is too short');
      return;
    }
    await _sendFile(path, type: 'voice', duration: seconds, name: 'voice.m4a', waveform: wave.length >= 8 ? wave : null);
  }

  /// Clear history: null = cancelled, false = only me, true = for everyone too.
  Future<bool?> _askClearHistory(Chat chat) {
    final canBoth = chat.type == 'private' && !chat.isSavedMessages && chat.peer != null && !chat.isBot;
    final canAll = chat.isMulti && chat.can('delete_messages');
    var both = false;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          icon: const Icon(Icons.cleaning_services_rounded, color: Color(0xFFE5484D)),
          title: const Text('Clear history?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(both
                ? (canBoth ? 'All messages will be removed for you and ${chat.peer!.name}.' : 'All messages will be removed for every member.')
                : 'All messages will be removed for you only.'),
            if (canBoth || canAll) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: both,
                onChanged: (v) => setD(() => both = v == true),
                title: Text(canBoth ? 'Also clear for ${chat.peer!.name}' : 'Clear for all members'),
              ),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
              onPressed: () => Navigator.pop(ctx, both),
              child: const Text('Clear'),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ message menu
  Future<void> _messageMenu(Message m, Chat chat, [BuildContext? anchorCtx]) async {
    final mine = m.senderId == _store.myId && !chat.isChannel;
    final channelAdmin = chat.isChannel && chat.can('post_messages');
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
    final canEdit = (mine || channelAdmin) && m.forwardedFromName == null && m.type != 'poll' && !m.viewOnce && (m.type == 'text' || m.text.isNotEmpty);
    final poll = m.poll;
    final canClosePoll = poll != null && !poll.isClosed && (mine || chat.isAdmin);
    final publicLink = (chat.isChannel || chat.isGroup) && (chat.username ?? '').isNotEmpty ? '${AppConfig.serverUrl}/c/${chat.username}/${m.id}' : null;
    final items = <MessageMenuItem>[
      if (chat.canPost) const MessageMenuItem('reply', Icons.reply_rounded, 'Reply'),
      if (m.text.isNotEmpty && !chat.noForwards) const MessageMenuItem('copy', Icons.copy_rounded, 'Copy'),
      if (publicLink != null && !chat.noForwards) const MessageMenuItem('copy_link', Icons.link_rounded, 'Copy link'),
      if (m.type != 'poll' && m.type != 'call' && !m.viewOnce && !chat.noForwards) const MessageMenuItem('forward', Icons.shortcut_rounded, 'Forward'),
      if (chat.type == 'private' || chat.can('pin_messages'))
        MessageMenuItem(chat.pinnedMessage?.id == m.id ? 'unpin' : 'pin', Icons.push_pin_outlined, chat.pinnedMessage?.id == m.id ? 'Unpin' : 'Pin'),
      if (canEdit) const MessageMenuItem('edit', Icons.edit_outlined, 'Edit'),
      if (chat.isGroup && !mine && m.senderId != null && m.sender?.deleted != true && !chat.protectedContent)
        const MessageMenuItem('private_reply', Icons.reply_all_rounded, 'Reply privately'),
      if (canClosePoll) const MessageMenuItem('close_poll', Icons.stop_circle_outlined, 'Stop poll'),
      const MessageMenuItem('select', Icons.check_circle_outline_rounded, 'Select'),
      const MessageMenuItem('remind', Icons.alarm_add_rounded, 'Remind me'),
      _store.bookmarked.contains(m.id)
          ? const MessageMenuItem('unbookmark', Icons.bookmark_remove_outlined, 'Remove from Read later')
          : const MessageMenuItem('bookmark', Icons.bookmark_add_outlined, 'Read later'),
      if (mine && !chat.isSavedMessages && !chat.isChannel) const MessageMenuItem('info', Icons.info_outline_rounded, 'Message info'),
      if (m.editedAt != null) const MessageMenuItem('history', Icons.history_rounded, 'Edit history'),
      if (!mine && !chat.isAdmin) const MessageMenuItem('report', Icons.flag_outlined, 'Report'),
      const MessageMenuItem('delete', Icons.delete_outline_rounded, 'Delete', danger: true),
    ];
    Rect anchor = Rect.fromLTWH(12, MediaQuery.of(context).size.height / 2 - 40, MediaQuery.of(context).size.width - 24, 80);
    final box = anchorCtx?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) anchor = box.localToGlobal(Offset.zero) & box.size;
    final when = m.editedAt ?? m.createdAt;
    final header = '${m.editedAt != null ? 'edited' : (chat.isChannel ? 'posted' : (mine ? 'sent' : 'received'))} ${chatListTime(when) == messageTime(when) ? 'today' : chatListTime(when)} at ${messageTime(when)}';
    if (!mounted) return;
    final a = await showMessageMenu(
      context,
      anchor: anchor,
      alignRight: mine,
      reactions: ChatStore.reactionEmojis.where((e) => chat.allowedReactions == null || chat.allowedReactions!.contains(e)).toList(),
      myReaction: m.myReaction,
      header: header,
      items: items,
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
        _startReply(m);
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        if (mounted) showInfo(context, 'Copied');
        break;
      case 'bookmark':
      case 'unbookmark':
        try {
          await _store.setBookmark(m, a == 'bookmark');
          if (mounted) showInfo(context, a == 'bookmark' ? 'Saved to Read later' : 'Removed from Read later');
        } catch (e) {
          if (mounted) showError(context, e);
        }
        break;
      case 'copy_link':
        await Clipboard.setData(ClipboardData(text: '${AppConfig.serverUrl}/c/${chat.username}/${m.id}'));
        if (mounted) showInfo(context, 'Link copied');
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
        await _delete(m, chat, mine || (chat.isChannel && chat.can('delete_messages')));
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
      case 'select':
        setState(() => _selected.add(m.id));
        break;
      case 'info':
        await showMessageInfo(context, m);
        break;
      case 'private_reply':
        try {
          final pc = await _store.openPrivateWith(m.senderId!);
          if (!mounted) return;
          Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: pc.id, initial: pc, quote: m)));
        } catch (e) {
          if (mounted) showError(context, e);
        }
        break;
    }
  }

  // ------------------------------------------------------------------ multi-select
  Future<void> _selectionAction(String action, Chat chat) async {
    final list = _store.messagesOf(chatId).where((m) => _selected.contains(m.id)).toList()..sort((a, b) => a.id.compareTo(b.id));
    if (list.isEmpty) return;
    switch (action) {
      case 'copy':
        final text = list.where((m) => m.text.isNotEmpty).map((m) => list.length > 1 && chat.isGroup ? '${m.sender?.name ?? ''}: ${m.text}' : m.text).join('\n\n');
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) showInfo(context, list.length == 1 ? 'Copied' : '${list.length} messages copied');
        break;
      case 'forward':
        final ids = list.where((m) => !m.viewOnce && m.type != 'poll' && m.type != 'call').map((m) => m.id).toList();
        if (ids.isEmpty) return;
        await Navigator.push(context, MaterialPageRoute(builder: (_) => ForwardScreen(fromChatId: chatId, messageIds: ids)));
        break;
      case 'delete':
        final myId = _store.myId;
        final allMine = list.every((m) => m.senderId == myId);
        final canAll = !chat.isSavedMessages && (allMine || chat.type == 'private' || chat.can('delete_messages'));
        final String? choice = chat.isMulti && canAll
            ? (await confirm(context, 'Delete ${list.length} message${list.length == 1 ? '' : 's'}?', 'They will be removed for everyone.', ok: 'Delete', danger: true) ? 'all' : null)
            : await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${list.length} message${list.length == 1 ? '' : 's'}?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, 'me'), child: const Text('Delete for me')),
              if (canAll) TextButton(onPressed: () => Navigator.pop(ctx, 'all'), child: const Text('Delete for everyone', style: TextStyle(color: Colors.red))),
            ],
          ),
        );
        if (choice == null) return;
        try {
          await _store.deleteMessages(chatId, list.map((m) => m.id).toList(), forEveryone: choice == 'all');
        } catch (e) {
          if (mounted) showError(context, e);
          return;
        }
        break;
    }
    if (mounted) setState(_selected.clear);
  }

  PreferredSizeWidget _selectionBar(Chat chat) {
    final noFwd = chat.noForwards;
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(_selected.clear)),
      title: Text('${_selected.length} selected'),
      actions: [
        if (!noFwd) IconButton(tooltip: 'Copy', icon: const Icon(Icons.copy_rounded), onPressed: () => _selectionAction('copy', chat)),
        if (!noFwd) IconButton(tooltip: 'Forward', icon: const Icon(Icons.shortcut_rounded), onPressed: () => _selectionAction('forward', chat)),
        IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline_rounded), onPressed: () => _selectionAction('delete', chat)),
      ],
    );
  }

  Future<void> _delete(Message m, Chat chat, bool mine) async {
    final canForEveryone = mine || (chat.type == 'private' && !chat.isSavedMessages) || chat.can('delete_messages');
    // groups & channels: whoever may delete removes it for everyone, no "for me / for everyone" question
    if (chat.isMulti && canForEveryone) {
      if (!await confirm(context, 'Delete this message?', 'It will be removed for everyone in “${chat.title}”.', ok: 'Delete', danger: true)) return;
      try {
        await _store.deleteMessages(chatId, [m.id], forEveryone: true);
      } catch (e) {
        if (mounted) showError(context, e);
      }
      return;
    }
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
        case 'video':
          if (chat.peer != null) startCall(context, chat.peer!, video: true);
          break;
        case 'search':
          Navigator.push(context, MaterialPageRoute(builder: (_) => GlobalSearchScreen(chatId: chat.id)));
          break;
        case 'voice_chat':
          await openVoiceChat(context, chat, start: chat.voiceChat == null);
          break;
        case 'passcode':
          await _passcodeMenu(chat);
          break;
        case 'live':
          Navigator.push(context, MaterialPageRoute(builder: (_) => LiveMapScreen(chat: chat)));
          break;
        case 'lock':
          // one place for both kinds of lock: fingerprint/screen lock, or a passcode just for this chat
          final how = await showModalBottomSheet<String>(
            context: context,
            showDragHandle: true,
            builder: (ctx) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                  leading: const Icon(Icons.fingerprint_rounded),
                  title: Text(chat.isLocked ? 'Turn off fingerprint lock' : 'Lock with fingerprint'),
                  subtitle: const Text('The chat moves to “Locked chats”'),
                  onTap: () => Navigator.pop(ctx, 'bio'),
                ),
                ListTile(
                  leading: const Icon(Icons.pin_rounded),
                  title: Text(ChatPasscode.has(chat.id) ? 'Passcode settings' : 'Lock with a passcode'),
                  subtitle: const Text('A PIN only for this chat'),
                  onTap: () => Navigator.pop(ctx, 'pin'),
                ),
              ]),
            ),
          );
          if (how == 'pin') {
            await _passcodeMenu(chat);
            break;
          }
          if (how != 'bio' || !mounted) break;
          if (!await ChatLock.unlock(context, reason: chat.isLocked ? 'Unlock this chat' : 'Lock this chat')) return;
          await _store.setLocked(chat.id, !chat.isLocked);
          if (mounted) showInfo(context, chat.isLocked ? 'Chat unlocked' : 'Chat locked — it now lives in “Locked chats”');
          break;
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
          final r = await _askClearHistory(chat);
          if (r != null) {
            await _store.clearHistory(chatId, forEveryone: r);
            if (mounted) showInfo(context, r ? 'History cleared for everyone' : 'History cleared for you');
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
    // locked & protected chats: no screenshots
    final guard = chat.isLocked || chat.protectedContent || ChatPasscode.has(chat.id);
    if (guard != _guarded) {
      _guarded = guard;
      guard ? ScreenGuard.acquire() : ScreenGuard.release();
    }
    if (chat.isLocked && !_unlocked) return _lockGate(chat);
    if (ChatPasscode.needsCode(chat.id)) return _passcodeGate(chat);
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
      final n = NumberFormat.decimalPattern().format(chat.memberCount);
      subtitle = chat.isChannel
          ? '$n subscriber${chat.memberCount == 1 ? '' : 's'}'
          : '$n member${chat.memberCount == 1 ? '' : 's'}${(_online ?? 0) > 1 ? ', ${_online!} online' : ''}';
    } else if (chat.peer != null) {
      subtitle = lastSeenText(chat.peer!);
    } else {
      subtitle = '';
    }

    final look = context.watch<AppPrefs>().chatAppearance(chatId);
    return PopScope(
      canPop: !_emojiOpen && _selected.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selected.isNotEmpty) {
          setState(_selected.clear);
        } else if (_emojiOpen) {
          setState(() => _emojiOpen = false);
        }
      },
      child: ChatThemeScope(
      appearance: look,
      child: Scaffold(
      backgroundColor: ChatColors.of(context).background,
      extendBodyBehindAppBar: true,
      appBar: _selected.isNotEmpty ? _selectionBar(chat) : _glassHeader(
        title: InkWell(
          onTap: () => _openInfo(chat),
          child: Row(
            children: [
              Stack(clipBehavior: Clip.none, children: [
                Avatar(id: chat.id, name: chat.title, url: chat.avatarAbsolute, size: 38, icon: chat.isSavedMessages ? Icons.bookmark_rounded : null),
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
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      Flexible(child: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.2))),
                      if (chat.isVerified) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified_rounded, size: 16, color: Brand.sky)),
                      if (chat.peer?.isPremium == true) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.star_rounded, size: 18, color: Brand.premium)),
                    ]),
                    if (typing != null)
                      Row(children: [
                        if (activityIcon(store.typingAction(chat)) != null)
                          Padding(padding: const EdgeInsets.only(right: 3), child: Icon(activityIcon(store.typingAction(chat)), size: 14, color: Brand.primary)),
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
              if (chat.peer != null && !chat.isSavedMessages && !chat.peer!.deleted && !chat.isBot && auth.feature('calls') && auth.feature('video_calls'))
                _mi('video', Icons.videocam_outlined, 'Video call'),
              _mi('search', Icons.search_rounded, 'Search messages'),
              if (chat.isMulti && (chat.voiceChat != null || chat.can('manage_voice_chats')))
                _mi('voice_chat', Icons.graphic_eq_rounded, chat.voiceChat != null ? 'Join voice chat' : 'Start voice chat'),
              _mi('mute', chat.isMuted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, chat.isMuted ? 'Unmute' : 'Mute'),
              _mi('media', Icons.perm_media_outlined, 'Shared media'),
              if (!chat.isChannel && !chat.isSavedMessages) _mi('live', Icons.share_location_rounded, 'Live locations'),
              _mi('theme', Icons.palette_outlined, 'Theme & wallpaper'),
              if (!chat.isRequest)
                _mi('lock', chat.isLocked || ChatPasscode.has(chat.id) ? Icons.lock_rounded : Icons.lock_outline_rounded,
                    chat.isLocked || ChatPasscode.has(chat.id) ? 'Chat lock' : 'Lock chat'),
              if (auth.feature('disappearing') && !chat.isChannel && (chat.peer != null || chat.isAdmin) && !chat.isSavedMessages)
                _mi('disappearing', Icons.timer_outlined, chat.disappearAfterSec > 0 ? 'Disappearing: ${disappearLabel(chat.disappearAfterSec)}' : 'Disappearing messages'),
              if (chat.canPost) _mi('scheduled', Icons.schedule_send_outlined, 'Scheduled messages'),
              if (chat.peer != null && !chat.isSavedMessages && !chat.peer!.deleted && !chat.isBot && auth.feature('secret_chats'))
                _mi('secret', Icons.lock_outline_rounded, 'Start vault chat'),
              _mi('export', Icons.ios_share_rounded, 'Export chat'),
              const PopupMenuDivider(),
              // in groups and channels only admins who may delete messages see this
              if (!chat.isMulti || chat.can('delete_messages')) _mi('clear', Icons.cleaning_services_outlined, 'Clear history'),
              if (chat.peer != null) _mi('block', Icons.block_rounded, chat.peer!.blocked ? 'Unblock user' : 'Block user', danger: !chat.peer!.blocked),
              if (!chat.isSavedMessages) _mi('report', Icons.flag_outlined, 'Report'),
              _mi('leave', Icons.logout_rounded, chat.isChannel ? 'Leave channel' : (chat.isGroup ? 'Leave group' : 'Delete chat'), danger: true),
            ],
          ),
        ],
      ),
      body: ChatBackground(
        appearance: look,
        // the message list runs under the floating header and message bar (they're frosted glass)
        child: Stack(children: [
          Positioned.fill(child: _messageList(chat, messages, store)),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: MeasureHeight(
              onHeight: (h) {
                if (mounted && (h - _topH).abs() > 0.5) setState(() => _topH = h);
              },
              child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(height: MediaQuery.paddingOf(context).top + _headerH),
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
          VoiceMiniPlayer(onOpen: (id) {
            if (id != chatId) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: id)));
          }),
          if (chat.voiceChat != null && context.watch<VoiceChatManager>().chatId != chat.id) _voiceChatBar(chat),
          if (chat.pinnedMessage != null) _pinnedBar(chat),
          if (chat.isChannel && chat.isAdmin && chat.queueCount > 0)
            Material(
              color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2A2412) : const Color(0xFFFFF4DC),
              child: InkWell(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PostQueueScreen(chat: chat))),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Row(children: [
                    const Icon(Icons.pending_actions_rounded, color: Color(0xFFB7791F), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('${chat.queueCount} post${chat.queueCount == 1 ? '' : 's'} waiting for review',
                          style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFB7791F))),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: Color(0xFFB7791F)),
                  ]),
                ),
              ),
            ),
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
              ]),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: MeasureHeight(
              onHeight: (h) {
                if (mounted && (h - _bottomH).abs() > 0.5) setState(() => _bottomH = h);
              },
              // messages scrolling under the floating bar fade out instead of showing through around it
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, 0.45, 1],
                    colors: [
                      ChatColors.of(context).background.withValues(alpha: 0),
                      ChatColors.of(context).background.withValues(alpha: 0.85),
                      ChatColors.of(context).background,
                    ],
                  ),
                ),
                child: _bottomBar(chat),
              ),
            ),
          ),
          Positioned(right: 12, bottom: _bottomH + 10, child: _downButton(messages)),
        ]),
      ),
    ),
    ),
    );
  }

  /// "N unread messages" line above the first message I haven't read; the chat opens there.
  int? _unreadMarkerId;
  int _unreadAtOpen = 0;
  final _unreadKey = GlobalKey();

  void _placeUnreadMarker(int unread) {
    if (unread <= 0) return;
    final msgs = _store.messagesOf(chatId);
    final myId = _store.myId;
    var n = 0;
    for (final m in msgs) {
      if (m.isLocal || m.senderId == myId) continue;
      n++;
      if (n == unread) {
        _unreadMarkerId = m.id;
        break;
      }
    }
    // more unread than loaded: mark the oldest one we have
    if (_unreadMarkerId == null && n > 0) _unreadMarkerId = msgs.lastWhere((m) => !m.isLocal && m.senderId != myId).id;
    _unreadAtOpen = unread;
    if (unread < 6 || _unreadMarkerId == null) return; // a few new ones fit on screen anyway
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToUnread());
  }

  Future<void> _scrollToUnread() async {
    for (var k = 0; k < 30 && mounted; k++) {
      final ctx = _unreadKey.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(ctx, alignment: 0.85, duration: const Duration(milliseconds: 250));
        return;
      }
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (_scroll.offset >= max) return;
      _scroll.jumpTo((_scroll.offset + 500).clamp(0.0, max));
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Widget _unreadDivider() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: _unreadKey,
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 6),
      color: (dark ? Colors.white : Brand.ink).withAlpha(dark ? 16 : 12),
      alignment: Alignment.center,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.keyboard_double_arrow_down_rounded, size: 16, color: Brand.primary),
        const SizedBox(width: 6),
        Text(_unreadAtOpen > 99 ? '99+ unread messages' : '$_unreadAtOpen unread message${_unreadAtOpen == 1 ? '' : 's'}',
            style: const TextStyle(color: Brand.primary, fontWeight: FontWeight.w700, fontSize: 12.5)),
      ]),
    );
  }

  void _startReply(Message m) {
    setState(() {
      _replyTo = m;
      _editing = null;
    });
    _focus.requestFocus();
  }

  Widget _downButton(List<Message> messages) {
    final newest = messages.isEmpty ? null : messages.first.id;
    if (newest != null && _newestSeen != null && newest > _newestSeen! && _showDown && messages.first.senderId != _store.myId) {
      _newBelow += messages.takeWhile((x) => x.id > _newestSeen!).length;
    }
    _newestSeen = newest;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedScale(
      scale: _showDown ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      child: Stack(clipBehavior: Clip.none, children: [
        Material(
          color: dark ? const Color(0xFF1E2238) : Colors.white,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: Colors.black26,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () {
              _scroll.animateTo(0, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
              setState(() => _newBelow = 0);
            },
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.keyboard_double_arrow_down_rounded, color: dark ? Colors.white70 : Brand.ink),
            ),
          ),
        ),
        if (_newBelow > 0)
          Positioned(
            top: -6,
            left: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              constraints: const BoxConstraints(minWidth: 20),
              decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(10)),
              child: Text(_newBelow > 99 ? '99+' : '$_newBelow',
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ),
      ]),
    );
  }

  Widget _messageList(Chat chat, List<Message> messages, ChatStore store) {
    final top = (_topH > 0 ? _topH : MediaQuery.paddingOf(context).top + _headerH) + 6;
    final bottom = _bottomH + 6;
    Widget padded(Widget w) => Padding(padding: EdgeInsets.only(top: top, bottom: bottom), child: w);
    if (_loading && messages.isEmpty) return padded(const Center(child: CircularProgressIndicator()));
    if (messages.isEmpty && chat.isBot) {
      return padded(BotIntro(chat: chat, onStart: () => _store.sendText(chatId, '/start')));
    }
    if (messages.isEmpty) {
      if (_error != null) return padded(Center(child: SystemBubble(text: _error!)));
      return padded(Center(child: SingleChildScrollView(child: _emptyChat(chat))));
    }
    final hasMore = store.hasMore(chatId);
    if (chat.isChannel) {
      // Count views for the posts on screen (server ignores repeats).
      WidgetsBinding.instance.addPostFrameCallback((_) => store.recordViews(chatId, messages.take(40)));
    }
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: EdgeInsets.only(top: top, bottom: bottom),
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
        final selecting = _selected.isNotEmpty;
        final picked = _selected.contains(m.id);
        return Column(
          children: [
            if (newDay) DateChip(date: m.createdAt),
            if (m.id == _unreadMarkerId) _unreadDivider(),
            if (m.isSystem)
              SystemBubble(text: systemText(m, store))
            else
              _selectable(
                selecting: selecting && !m.isLocal,
                picked: picked,
                onTap: () => setState(() => picked ? _selected.remove(m.id) : _selected.add(m.id)),
                child: SwipeReply(
                onReply: selecting || m.isLocal || !chat.canPost ? null : () => _startReply(m),
                onDoubleTap: null, // one tap opens the menu right away (❤️ is the first reaction there)
                child: Builder(builder: (bctx) => AnimatedContainer(
                key: _msgKeys.putIfAbsent(m.id, () => GlobalKey()),
                duration: const Duration(milliseconds: 400),
                color: _flashId == m.id ? Brand.primary.withValues(alpha: 0.16) : Colors.transparent,
                child: MessageBubble(
                key: ValueKey(m.isLocal ? m.clientId : m.id),
                onReplyTap: m.replyTo == null ? null : () => _jumpToMessage(m.replyTo!.id),
                        onCommand: (chat.isBot || chat.isGroup) && chat.canPost ? (c) { HapticFeedback.selectionClick(); _store.sendText(chatId, c); } : null,
                message: m,
                chat: chat,
                isMine: mine,
                showSender: showSender,
                firstInGroup: first,
                lastInGroup: last,
                showAvatar: last && chat.isGroup && !mine,
                // one tap (or a long press) opens the message menu; long press while selecting adds to the selection
                onLongPress: () => selecting ? setState(() => _selected.add(m.id)) : _messageMenu(m, chat, bctx),
                onTap: selecting ? null : () => _messageMenu(m, chat, bctx),
                onDiscuss: chat.isChannel && chat.linkedChat != null ? () => _openChat(chat.linkedChat!.id) : null,
                onForward: chat.isChannel && !chat.noForwards && !selecting
                    ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => ForwardScreen(fromChatId: chatId, messageIds: [m.id])))
                    : null,
              ))),
              ),
              ),
          ],
        );
      },
    );
  }

  /// The tapped message, drawn again above the blur while its menu is open.
  Widget _lockGate(Chat chat) {
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle),
            child: const Icon(Icons.lock_rounded, color: Colors.white, size: 44),
          ),
          const SizedBox(height: 16),
          const Text('This chat is locked', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('Use your fingerprint or screen lock to open it.', style: TextStyle(color: Brand.muted)),
          const SizedBox(height: 20),
          SizedBox(
            width: 200,
            child: AuroraButton(
              label: 'Unlock',
              icon: Icons.fingerprint_rounded,
              onPressed: () async {
                if (await ChatLock.unlock(context, reason: 'Open ${chat.title}') && mounted) setState(() => _unlocked = true);
              },
            ),
          ),
        ]),
      ),
    );
  }

  bool _askedCode = false;

  Future<void> _enterCode(Chat chat) async {
    final code = await ChatPasscode.askCode(context, title: 'Enter passcode', subtitle: chat.title, verify: (c) => ChatPasscode.check(chat.id, c));
    if (code != null && mounted) setState(() {});
  }

  Widget _passcodeGate(Chat chat) {
    if (!_askedCode) {
      _askedCode = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _enterCode(chat);
      });
    }
    return Scaffold(
      appBar: AppBar(title: Text(chat.title)),
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle),
            child: const Icon(Icons.pin_rounded, color: Colors.white, size: 44),
          ),
          const SizedBox(height: 16),
          const Text('This chat has a passcode', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 20),
          SizedBox(width: 220, child: AuroraButton(label: 'Enter passcode', icon: Icons.dialpad_rounded, onPressed: () => _enterCode(chat))),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () async {
              if (await ChatPasscode.resetWithDevice(context, chat.id) && mounted) {
                setState(() {});
                showInfo(context, 'Passcode removed');
              }
            },
            child: const Text('Forgot passcode?'),
          ),
        ]),
      ),
    );
  }

  /// Chat menu → Passcode: set, change or remove (removing asks for the current one).
  Future<void> _passcodeMenu(Chat chat) async {
    if (!ChatPasscode.has(chat.id)) {
      final code = await ChatPasscode.askNew(context);
      if (code == null) return;
      await ChatPasscode.set(chat.id, code);
      if (mounted) showInfo(context, 'Passcode set — this chat now asks for it when opened');
      setState(() {});
      return;
    }
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.password_rounded), title: const Text('Change passcode'), onTap: () => Navigator.pop(ctx, 'change')),
          ListTile(leading: const Icon(Icons.no_encryption_gmailerrorred_rounded), title: const Text('Remove passcode'), onTap: () => Navigator.pop(ctx, 'remove')),
        ]),
      ),
    );
    if (a == null || !mounted) return;
    final current = await ChatPasscode.askCode(context, title: 'Current passcode', verify: (c) => ChatPasscode.check(chat.id, c));
    if (current == null || !mounted) return;
    if (a == 'remove') {
      await ChatPasscode.remove(chat.id);
      if (mounted) showInfo(context, 'Passcode removed');
    } else {
      final code = await ChatPasscode.askNew(context);
      if (code == null) return;
      await ChatPasscode.set(chat.id, code);
      if (mounted) showInfo(context, 'Passcode changed');
    }
    if (mounted) setState(() {});
  }

  void _openChat(int id) => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: id, initial: _store.chatById(id))));

  /// In selection mode a message row gets a round check on the left and a tint; taps toggle it.
  Widget _selectable({required bool selecting, required bool picked, required VoidCallback onTap, required Widget child}) {
    if (!selecting) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        color: picked ? Brand.primary.withValues(alpha: 0.10) : Colors.transparent,
        child: Row(children: [
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: picked ? Brand.aurora : null,
                border: picked ? null : Border.all(color: Brand.muted, width: 1.6),
              ),
              child: picked ? const Icon(Icons.check_rounded, color: Colors.white, size: 15) : null,
            ),
          ),
          Expanded(child: IgnorePointer(child: child)),
        ]),
      ),
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
          GestureDetector(
            onTap: canSend && !chat.isSavedMessages ? () => _store.sendTavi(chatId, TaviPose.wave.name, '👋') : null,
            child: AppMascot(pose: chat.isSavedMessages ? TaviPose.think : (chat.isBot ? TaviPose.coffee : TaviPose.wave), size: 130),
          ),
          if (canSend && !chat.isSavedMessages)
            const Text('Tap Tavi to say hi', style: TextStyle(fontSize: 12, color: Brand.muted, fontWeight: FontWeight.w600)),
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
              for (final g in ['👋 Hi!', 'Hello 🙂', 'Salam 🤝'])
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

  /// "Voice chat · 4 participants   [Join]" under the header while a voice chat is live here.
  Widget _voiceChatBar(Chat chat) {
    final vc = chat.voiceChat!;
    final n = (vc['count'] as num?)?.toInt() ?? 0;
    final title = '${vc['title'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => openVoiceChat(context, chat),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
            decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(18)),
            child: Row(children: [
              const Icon(Icons.graphic_eq_rounded, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title.isEmpty ? 'Voice chat' : title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
                  Text('$n ${n == 1 ? 'participant' : 'participants'} · live now', style: const TextStyle(color: Colors.white, fontSize: 12)),
                ]),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                child: const Text('Join', style: TextStyle(color: Brand.primary, fontWeight: FontWeight.w800)),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _pinnedBar(Chat chat) {
    final p = chat.pinnedMessage!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
      child: GlassPanel(
      radius: 18,
      ring: false,
      child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showPins(chat),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
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
            if (chat.type == 'private' || chat.can('pin_messages'))
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
                trailing: (chat.type == 'private' || chat.can('pin_messages')) && pins.length > 1
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
    return GlassPanel(
      radius: 23,
      opacity: dark ? 0.82 : 0.9,
      child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 46),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        SizedBox(
          width: 42,
          height: 46,
          child: IconButton(
            tooltip: _emojiOpen ? 'Keyboard' : 'Emoji, stickers & GIFs',
            padding: const EdgeInsets.only(left: 4),
            icon: Icon(_emojiOpen ? Icons.keyboard_rounded : Icons.sentiment_satisfied_alt_rounded, color: iconColor, size: 23),
            onPressed: _toggleEmoji,
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.zero,
            child: TextField(
              controller: _text,
              focusNode: _focus,
              minLines: 1,
              maxLines: 6,
              maxLength: 4096,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 16, height: 1.3),
              // select text → Bold / Italic / Strike / Code / Spoiler
              // only our own menu: Cut · Copy · Paste · Select all (+ "Format" when text is selected) —
              // no "Ask …", "Translate", "WPS Memo"… entries other apps add to the system menu
              contextMenuBuilder: (ctx, state) {
                final items = state.contextMenuButtonItems.where((i) => i.type != ContextMenuButtonType.custom).toList();
                final sel = _text.selection;
                if (sel.isValid && !sel.isCollapsed) {
                  items.insert(0, ContextMenuButtonItem(label: 'Format', onPressed: () {
                    state.hideToolbar(false);
                    setState(() => _formatOpen = true);
                  }));
                }
                return AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: items);
              },
              onTap: () {
                if (_emojiOpen) setState(() => _emojiOpen = false);
              },
              decoration: InputDecoration(
                hintText: chat.slowModeSec > 0 && !chat.isAdmin ? 'Message (slow mode: ${chat.slowModeSec}s)' : 'Message',
                hintStyle: TextStyle(color: iconColor, fontSize: 16),
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.fromLTRB(2, 12.5, 2, 12.5),
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
          SizedBox(
            width: 42,
            height: 46,
            child: IconButton(
              tooltip: 'Attach: gallery, camera, files…',
              padding: const EdgeInsets.only(right: 4),
              icon: Transform.rotate(angle: 0.78, child: Icon(Icons.attach_file_rounded, color: iconColor, size: 22)),
              onPressed: () => _attach(),
            ),
          ),
      ]),
      ),
    );
  }

  Widget _roundAction({required IconData icon, required String tooltip, required VoidCallback onTap}) => Tooltip(
        message: tooltip,
        child: Material(
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: Ink(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: Brand.aurora,
              boxShadow: [BoxShadow(color: Brand.rose.withValues(alpha: 0.28), blurRadius: 10, offset: const Offset(0, 3))],
            ),
            child: InkWell(
              onTap: onTap,
              child: Icon(icon, color: Colors.white, size: 22),
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
    final pickerH = (MediaQuery.of(context).size.height * 0.31).clamp(170.0, 330.0);
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
                  columns: MediaQuery.of(context).size.width > 600 ? 12 : 8,
                  emojiSizeMax: 32,
                  verticalSpacing: 4,
                  horizontalSpacing: 2,
                  buttonMode: ButtonMode.MATERIAL,
                  recentsLimit: 32,
                  gridPadding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
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
                  customCategoryView: (config, state, tab, page) => PremiumEmojiCategoryBar(config, state, tab, page),
                ),
                skinToneConfig: SkinToneConfig(dialogBackgroundColor: bg, indicatorColor: Brand.muted),
                bottomActionBarConfig: BottomActionBarConfig(
                  enabled: false,
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
    if (chat.needsCaptcha) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: GlassPanel(
            radius: 22,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('This group checks new members', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 4),
              const Text('Confirm you’re a person to start chatting. Unverified members are removed after 5 minutes.',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Brand.muted)),
              const SizedBox(height: 12),
              AuroraButton(
                label: 'I’m not a robot',
                icon: Icons.verified_user_rounded,
                onPressed: () async {
                  try {
                    await _store.verifyHuman(chat.id);
                  } catch (e) {
                    if (mounted) showError(context, e);
                  }
                },
              ),
            ]),
          ),
        ),
      );
    }
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
    } else if (chat.isRestricted) {
      blockedText = 'An admin muted you in this group until ${chatListTime(chat.restrictedUntil!)} ${messageTime(chat.restrictedUntil!)}.';
    } else if (chat.peer?.blocked == true) {
      blockedText = 'You blocked ${chat.peer!.name}. They can’t message or call you.';
      blockedAction = TextButton(onPressed: () => _chatMenu('block', chat), child: const Text('Unblock'));
    } else if (chat.peer?.blockedMe == true) {
      blockedText = '${chat.peer!.name} has blocked you. You can’t send messages or call them.';
    }
    if (blockedText != null) {
      return SafeArea(
        top: false,
        child: Container(
          color: ChatColors.of(context).bar,
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(chat.peer?.blockedMe == true || chat.peer?.blocked == true ? Icons.block_rounded : Icons.info_outline_rounded, color: Brand.muted, size: 22),
            const SizedBox(height: 6),
            Text(blockedText, textAlign: TextAlign.center, style: const TextStyle(color: Brand.muted)),
            if (blockedAction != null) blockedAction,
          ]),
        ),
      );
    }

    final banner = _editing ?? _replyTo;
    final quote = _quote;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (quote != null && banner == null)
              Container(
                margin: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1A1F35).withValues(alpha: 0.96) : Colors.white.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(width: 4, color: Brand.violet),
                    const SizedBox(width: 10),
                    const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Icon(Icons.reply_all_rounded, color: Brand.violet, size: 22)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('Replying privately', style: TextStyle(color: Brand.violet, fontWeight: FontWeight.w700, fontSize: 13)),
                          Text(taliToPlain(quote.preview), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                        ]),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.close_rounded, size: 20), onPressed: () => setState(() => _quote = null)),
                  ]),
                ),
              ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: banner == null
                  ? const SizedBox(width: double.infinity)
                  : Container(
                      margin: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1A1F35).withValues(alpha: 0.96) : Colors.white.withValues(alpha: 0.96),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 3))],
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
            if ((_inline != null || _inlineLoading) && !_recording && _reviewPath == null) _inlinePanel(),
            // quick replies: "/" + shortcut (not in bot chats — "/" there means a bot command)
            if (!_recording && _reviewPath == null && _editing == null && !chat.isBot && chat.canPost && QuickReplies.match(_text.text).isNotEmpty)
              _quickRepliesPanel(),
            if (_formatOpen && _text.selection.isValid && !_text.selection.isCollapsed && !_recording && _reviewPath == null) _formatBar(),
            // one emoji typed → matching stickers above the box
            if (!_recording && _reviewPath == null && _editing == null && _emojiOnly != null && chat.canPost)
              EmojiStickerSuggestions(
                key: ValueKey(_emojiOnly),
                chatId: chatId,
                emoji: _emojiOnly!,
                onSent: () => setState(() => _text.clear()),
              ),
            if (_reviewPath != null)
              _reviewBar(chat)
            else if (_recording)
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 2, 0, 2),
                child: Row(children: [
                  Expanded(
                    child: Container(
                      height: 46,
                      padding: const EdgeInsets.only(left: 2, right: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1C2033) : Colors.white,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(color: (_recPaused ? Brand.amber : const Color(0xFFE5484D)).withValues(alpha: 0.3)),
                      ),
                      child: Row(children: [
                        IconButton(
                          tooltip: 'Delete recording',
                          icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFE5484D)),
                          onPressed: () => _stopRecording(send: false),
                        ),
                        if (_recPaused)
                          const Icon(Icons.pause_circle_filled_rounded, color: Brand.amber, size: 16)
                        else
                          const RecordingDot(),
                        const SizedBox(width: 8),
                        Text(duration(_recSeconds), style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
                        const SizedBox(width: 10),
                        Expanded(child: LiveWave(levels: _levels, color: _recPaused ? Brand.muted : Brand.primary)),
                        IconButton(
                          tooltip: _recPaused ? 'Continue recording' : 'Pause',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(_recPaused ? Icons.mic_rounded : Icons.pause_rounded, color: _recPaused ? Brand.primary : Brand.muted),
                          onPressed: _togglePause,
                        ),
                        IconButton(
                          tooltip: 'Stop and listen',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.stop_circle_outlined, color: Brand.muted),
                          onPressed: _stopForReview,
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
                  if (_editing == null && chat.isBot && (chat.bot?.menuUrl != null || (chat.bot?.commands.isNotEmpty ?? false)))
                    Padding(
                      padding: const EdgeInsets.only(right: 6, bottom: 3),
                      child: BotMenuButton(
                        hasApp: chat.bot?.menuUrl != null,
                        onTap: () async {
                          if (chat.bot?.menuUrl != null) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => MiniAppScreen(botId: chat.peer!.id, url: chat.bot!.menuUrl!, title: chat.title)),
                            );
                            return;
                          }
                          final c = await pickBotCommand(context, chat.bot!);
                          if (c != null) _store.sendText(chatId, c);
                        },
                        onLongPress: (chat.bot?.commands.isNotEmpty ?? false)
                            ? () async {
                                final c = await pickBotCommand(context, chat.bot!);
                                if (c != null) _store.sendText(chatId, c);
                              }
                            : null,
                      ),
                    ),
                  if (_editing != null) const SizedBox(width: 4),
                  Expanded(child: _inputPill(chat)),
                  if (_editing == null && _botKeyboard(chat) != null) ...[
                    const SizedBox(width: 4),
                    _roundAction(
                      icon: _kbHidden ? Icons.keyboard_alt_outlined : Icons.keyboard_hide_rounded,
                      tooltip: _kbHidden ? 'Show bot keyboard' : 'Hide bot keyboard',
                      onTap: () => setState(() {
                        _kbHidden = !_kbHidden;
                        if (!_kbHidden) {
                          FocusManager.instance.primaryFocus?.unfocus();
                          _emojiOpen = false;
                        }
                      }),
                    ),
                  ],
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
            if (_emojiOpen && !_recording && _reviewPath == null) _emojiPanel(),
            if (!_emojiOpen && !_kbHidden && !_recording && _reviewPath == null && _editing == null && _botKeyboard(chat) != null)
              BotReplyKeyboard(
                markup: _botKeyboard(chat)!.replyKeyboard!,
                onPressed: (b) async {
                  final one = _botKeyboard(chat)!.replyKeyboard!['one_time_keyboard'] == true;
                  if (b['request_location'] == true) {
                    await _shareLocation();
                  } else {
                    _store.sendText(chatId, '${b['text']}');
                  }
                  if (one && mounted) setState(() => _kbHidden = true);
                },
              ),
          ],
        ),
      ),
    );
  }
}
