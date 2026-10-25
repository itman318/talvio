import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/mascot.dart';
import 'channel_screens.dart' show PublicChatPreviewScreen;
import 'chat_screen.dart';
import 'user_profile_screen.dart';

/// One search for everything: my chats, people, bots, public groups, channels and messages.
/// With an empty box it shows recent searches and popular channels, groups and bots.
class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key, this.initialFilter = 'all', this.initialQuery = '', this.chatId});
  final String initialFilter;
  final String initialQuery;

  /// Search only the messages of this chat.
  final int? chatId;

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  static const _filters = [
    ('all', 'All', Icons.travel_explore_rounded),
    ('chats', 'Chats', Icons.chat_bubble_rounded),
    ('people', 'People', Icons.person_rounded),
    ('groups', 'Groups', Icons.groups_rounded),
    ('channels', 'Channels', Icons.campaign_rounded),
    ('bots', 'Bots', Icons.smart_toy_rounded),
    ('messages', 'Messages', Icons.forum_rounded),
  ];

  late final _q = TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  late String _filter = widget.chatId != null ? 'messages' : widget.initialFilter;
  Map<String, dynamic>? _data;
  List<Map<String, dynamic>> _messages = [];
  List<String> _recent = [];
  bool _loading = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    _run();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (mounted) setState(() => _recent = p.getStringList('search.recent') ?? []);
    } catch (_) {}
  }

  Future<void> _remember(String q) async {
    q = q.trim();
    if (q.length < 2) return;
    _recent = [q, ..._recent.where((x) => x.toLowerCase() != q.toLowerCase())].take(8).toList();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('search.recent', _recent);
    } catch (_) {}
  }

  Future<void> _clearRecent() async {
    setState(() => _recent = []);
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('search.recent');
    } catch (_) {}
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), _run);
    setState(() {});
  }

  Future<void> _run() async {
    final q = _q.text.trim();
    final seq = ++_seq;
    final api = context.read<AppServices>().api;
    setState(() => _loading = true);
    try {
      final wantMessages = q.length >= 2 && (_filter == 'all' || _filter == 'messages');
      final futures = <Future<dynamic>>[
        _filter == 'messages' && q.length >= 2 ? Future.value(null) : api.get('/search', query: {'q': q, if (_filter != 'all' && _filter != 'messages') 'type': _filter}),
        wantMessages
            ? api.get('/search/messages', query: {'q': q, 'limit': _filter == 'messages' ? '40' : '6', if (widget.chatId != null) 'chat_id': '${widget.chatId}'})
            : Future.value(null),
      ];
      final r = await Future.wait(futures);
      if (!mounted || seq != _seq) return;
      setState(() {
        if (r[0] != null) _data = Map<String, dynamic>.from(r[0] as Map);
        _messages = r[1] == null ? [] : ((r[1] as Map)['results'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() => _loading = false);
      if (q.length >= 2) showError(context, e);
    }
  }

  void _setFilter(String f) {
    if (f == _filter) return;
    setState(() => _filter = f);
    _run();
  }

  // ------------------------------------------------------------------ opening results
  Future<void> _openChat(Chat c) async {
    _remember(_q.text);
    if (widget.chatId == c.id) {
      Navigator.pop(context);
      return;
    }
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: c.id, initial: c)));
  }

  Future<void> _openPublic(Map<String, dynamic> info) async {
    _remember(_q.text);
    final store = context.read<ChatStore>();
    if (info['is_member'] == true) {
      try {
        final chat = await store.getChat((info['chat_id'] as num).toInt());
        if (mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
      } catch (e) {
        if (mounted) showError(context, e);
      }
      return;
    }
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PublicChatPreviewScreen(info: info)));
  }

  Future<void> _openUser(AppUser u) async {
    _remember(_q.text);
    if (u.isBot) {
      try {
        final chat = await context.read<ChatStore>().openPrivateWith(u.id);
        if (mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
      } catch (e) {
        if (mounted) showError(context, e);
      }
      return;
    }
    await Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfileScreen(userId: u.id)));
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final q = _q.text.trim();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Container(
          height: 42,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(color: dark ? const Color(0xFF181C31) : const Color(0xFFEBEDF4), borderRadius: BorderRadius.circular(14)),
          child: TextField(
            controller: _q,
            autofocus: widget.initialQuery.isEmpty,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: (v) {
              _remember(v);
              _run();
            },
            style: const TextStyle(fontSize: 15.5),
            decoration: InputDecoration(
              hintText: widget.chatId != null ? 'Search in this chat' : 'Search people, groups, channels, bots…',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 11),
              prefixIcon: const Icon(Icons.search_rounded, size: 21),
              suffixIcon: q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () {
                        _q.clear();
                        _onChanged('');
                      },
                    ),
            ),
          ),
        ),
        bottom: widget.chatId != null ? null : PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: SizedBox(
            height: 50,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              children: [
                for (final f in _filters)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: _FilterChip(icon: f.$3, label: f.$2, selected: _filter == f.$1, onTap: () => _setFilter(f.$1)),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: Column(children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: _loading ? const LinearProgressIndicator(minHeight: 2) : const SizedBox(height: 2),
        ),
        Expanded(
          child: q.length < 2
              ? (widget.chatId != null
                  ? const TaviEmptyState(pose: TaviPose.search, title: 'Search this chat', text: 'Type a word to find messages.')
                  : _discover())
              : _results(q),
        ),
      ]),
    );
  }

  Widget _discover() {
    final d = _data;
    final channels = _list(d?['channels']);
    final groups = _list(d?['groups']);
    final bots = _users(d?['bots']);
    return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
      if (_recent.isNotEmpty) ...[
        _Header('Recent searches', action: 'Clear', onAction: _clearRecent),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final r in _recent)
              ActionChip(
                avatar: const Icon(Icons.history_rounded, size: 16),
                label: Text(r),
                onPressed: () {
                  _q.text = r;
                  _q.selection = TextSelection.collapsed(offset: r.length);
                  _run();
                  setState(() {});
                },
              ),
          ]),
        ),
      ],
      if (channels.isNotEmpty && (_filter == 'all' || _filter == 'channels')) ...[
        const _Header('Popular channels'),
        SizedBox(
          height: 178,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [for (final c in channels) _ChannelCard(info: c, onTap: () => _openPublic(c))],
          ),
        ),
      ],
      if (groups.isNotEmpty && (_filter == 'all' || _filter == 'groups')) ...[
        const _Header('Popular groups'),
        for (final g in groups.take(_filter == 'groups' ? 30 : 5)) _PublicTile(info: g, query: '', onTap: () => _openPublic(g)),
      ],
      if (bots.isNotEmpty && (_filter == 'all' || _filter == 'bots')) ...[
        const _Header('Bots'),
        for (final b in bots.take(_filter == 'bots' ? 30 : 5)) _UserTile(user: b.$1, about: b.$2, users: b.$3, query: '', onTap: () => _openUser(b.$1)),
      ],
      if (d != null && channels.isEmpty && groups.isEmpty && bots.isEmpty && _recent.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 40),
          child: TaviEmptyState(pose: TaviPose.search, title: 'Search Talvio', text: 'Find friends by @username, and discover public groups, channels and bots.'),
        ),
    ]);
  }

  Widget _results(String q) {
    final d = _data ?? const {};
    final chats = _list(d['chats']).map(Chat.fromJson).toList();
    final people = _users(d['people']);
    final bots = _users(d['bots']);
    final groups = _list(d['groups']);
    final channels = _list(d['channels']);
    final all = _filter == 'all';
    final empty = chats.isEmpty && people.isEmpty && bots.isEmpty && groups.isEmpty && channels.isEmpty && _messages.isEmpty;
    if (empty && !_loading) {
      return ListView(children: [
        const SizedBox(height: 30),
        TaviEmptyState(
          pose: TaviPose.search,
          title: 'No results for “$q”',
          text: _filter == 'all' ? 'Try a different spelling or a @username.' : 'Try “All” to search everywhere.',
          action: _filter == 'all' ? null : OutlinedButton(onPressed: () => _setFilter('all'), child: const Text('Search everywhere')),
        ),
      ]);
    }
    Widget section(String title, String filter, int count, List<Widget> rows) {
      if (rows.isEmpty) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Header(title, action: all && count >= 6 ? 'See all' : null, onAction: () => _setFilter(filter)),
        ...rows,
      ]);
    }

    return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
      section('Chats', 'chats', chats.length, [for (final c in chats) _MyChatTile(chat: c, query: q, onTap: () => _openChat(c))]),
      section('People', 'people', people.length, [for (final p in people) _UserTile(user: p.$1, query: q, onTap: () => _openUser(p.$1))]),
      section('Channels', 'channels', channels.length, [for (final c in channels) _PublicTile(info: c, query: q, onTap: () => _openPublic(c))]),
      section('Groups', 'groups', groups.length, [for (final g in groups) _PublicTile(info: g, query: q, onTap: () => _openPublic(g))]),
      section('Bots', 'bots', bots.length, [for (final b in bots) _UserTile(user: b.$1, about: b.$2, users: b.$3, query: q, onTap: () => _openUser(b.$1))]),
      section('Messages', 'messages', _messages.length, [
        for (final r in _messages) _MessageTile(result: r, query: q, onTap: () => _openChat(Chat.fromJson(Map<String, dynamic>.from(r['chat'] as Map)))),
      ]),
    ]);
  }

  List<Map<String, dynamic>> _list(Object? raw) => raw is List ? raw.map((e) => Map<String, dynamic>.from(e as Map)).toList() : const [];

  List<(AppUser, String, int)> _users(Object? raw) => _list(raw)
      .map((j) => (AppUser.fromJson(j), '${j['about'] ?? ''}', (j['users'] as num?)?.toInt() ?? 0))
      .toList();
}

// ------------------------------------------------------------------ pieces
class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            gradient: selected ? Brand.aurora : null,
            color: selected ? null : (dark ? const Color(0xFF1A1E33) : const Color(0xFFEBEDF4)),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: selected ? Colors.white : Brand.muted),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: selected ? Colors.white : null)),
          ]),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title, {this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 10, 6),
        child: Row(children: [
          Text(title.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: Brand.muted)),
          const Spacer(),
          if (action != null) TextButton(onPressed: onAction, style: TextButton.styleFrom(visualDensity: VisualDensity.compact), child: Text(action!)),
        ]),
      );
}

/// Title with the matched part in bold.
class _Hl extends StatelessWidget {
  const _Hl(this.text, this.query, {this.style});
  final String text;
  final String query;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final q = query.replaceFirst('@', '').toLowerCase();
    final i = q.isEmpty ? -1 : text.toLowerCase().indexOf(q);
    if (i < 0) return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: base);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: text.substring(0, i)),
        TextSpan(text: text.substring(i, i + q.length), style: const TextStyle(color: Brand.primary, fontWeight: FontWeight.w800)),
        TextSpan(text: text.substring(i + q.length)),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: base,
    );
  }
}

const _titleStyle = TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5);

Widget _verified(bool v) => v ? const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified_rounded, size: 16, color: Brand.primary)) : const SizedBox.shrink();

class _MyChatTile extends StatelessWidget {
  const _MyChatTile({required this.chat, required this.query, required this.onTap});
  final Chat chat;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kind = chat.isChannel ? 'Channel' : (chat.isGroup ? 'Group' : (chat.isBot ? 'Bot' : null));
    final sub = [
      if (kind != null) kind,
      if (chat.isChannel || chat.isGroup) '${compactNumber(chat.memberCount)} ${chat.isChannel ? 'subscribers' : 'members'}',
      if (!chat.isChannel && !chat.isGroup && chat.peer?.username != null) '@${chat.peer!.username}',
    ].join(' · ');
    return ListTile(
      onTap: onTap,
      leading: Avatar(id: chat.id, name: chat.title, url: chat.avatarAbsolute, size: 46),
      title: Row(children: [Flexible(child: _Hl(chat.title, query, style: _titleStyle)), _verified(chat.isVerified)]),
      subtitle: Text(sub.isEmpty ? (chat.lastMessage?.preview ?? '') : sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: chat.unreadCount > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(10)),
              child: Text('${chat.unreadCount}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
            )
          : null,
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.user, required this.query, required this.onTap, this.about, this.users = 0});
  final AppUser user;
  final String query;
  final VoidCallback onTap;
  final String? about;
  final int users;

  @override
  Widget build(BuildContext context) {
    final sub = user.isBot
        ? [if (user.username != null) '@${user.username}', if ((about ?? '').isNotEmpty) about!, if (users > 1) '${compactNumber(users)} users'].join(' · ')
        : [if (user.username != null) '@${user.username}', lastSeenText(user)].where((x) => x.isNotEmpty).join(' · ');
    return ListTile(
      onTap: onTap,
      leading: Stack(clipBehavior: Clip.none, children: [
        Avatar(id: user.id, name: user.name, url: user.avatarAbsolute, size: 46),
        if (user.isBot)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, shape: BoxShape.circle),
              child: const CircleAvatar(radius: 8, backgroundColor: Brand.violet, child: Icon(Icons.smart_toy_rounded, size: 11, color: Colors.white)),
            ),
          ),
      ]),
      title: Row(children: [Flexible(child: _Hl(user.name, query, style: _titleStyle)), _verified(user.isVerified), if (user.isPremium) const Padding(padding: EdgeInsets.only(left: 3), child: Icon(Icons.star_rounded, size: 16, color: Brand.premium))]),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: user.isBot ? const _Pill('Start') : null,
    );
  }
}

class _PublicTile extends StatelessWidget {
  const _PublicTile({required this.info, required this.query, required this.onTap});
  final Map<String, dynamic> info;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isChannel = info['type'] == 'channel';
    final url = info['avatar_url'] as String?;
    final n = (info['member_count'] as num?)?.toInt() ?? 0;
    return ListTile(
      onTap: onTap,
      leading: Avatar(id: (info['chat_id'] as num).toInt(), name: '${info['title']}', url: url == null ? null : AppConfig.absolute(url), size: 46),
      title: Row(children: [Flexible(child: _Hl('${info['title']}', query, style: _titleStyle)), _verified(info['is_verified'] == true)]),
      subtitle: Text(
        [if (info['username'] != null) '@${info['username']}', '${compactNumber(n)} ${isChannel ? 'subscribers' : 'members'}'].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: info['is_member'] == true ? const Icon(Icons.check_circle_rounded, color: Brand.green, size: 20) : _Pill(isChannel ? 'Join' : 'Join'),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.result, required this.query, required this.onTap});
  final Map<String, dynamic> result;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final chat = Map<String, dynamic>.from(result['chat'] as Map);
    final m = Message.fromJson(Map<String, dynamic>.from(result['message'] as Map));
    final url = chat['avatar_url'] as String?;
    return ListTile(
      onTap: onTap,
      leading: Avatar(id: (chat['id'] as num).toInt(), name: '${chat['title']}', url: url == null ? null : AppConfig.absolute(url), size: 46),
      title: Row(children: [
        Expanded(child: Text('${chat['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle)),
        Text(chatListTime(m.createdAt), style: const TextStyle(fontSize: 12, color: Brand.muted)),
      ]),
      subtitle: _Hl(m.preview, query),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(14)),
        child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5)),
      );
}

class _ChannelCard extends StatelessWidget {
  const _ChannelCard({required this.info, required this.onTap});
  final Map<String, dynamic> info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final url = info['avatar_url'] as String?;
    final n = (info['member_count'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Ink(
          width: 132,
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF181C31) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: Column(children: [
            Avatar(id: (info['chat_id'] as num).toInt(), name: '${info['title']}', url: url == null ? null : AppConfig.absolute(url), size: 58),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Flexible(child: Text('${info['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5))),
              _verified(info['is_verified'] == true),
            ]),
            Text('${compactNumber(n)} subscribers', style: const TextStyle(fontSize: 11.5, color: Brand.muted)),
            const Spacer(),
            info['is_member'] == true
                ? const Text('Joined', style: TextStyle(color: Brand.green, fontWeight: FontWeight.w700, fontSize: 12.5))
                : const _Pill('Join'),
          ]),
        ),
      ),
    );
  }
}

/// Opens a public group / channel from its summary: the chat if I'm in, otherwise its preview.
Future<void> openPublicSummary(BuildContext context, Map<String, dynamic> info) async {
  final store = context.read<ChatStore>();
  if (info['is_member'] == true) {
    try {
      final chat = await store.getChat((info['chat_id'] as num).toInt());
      if (context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
    return;
  }
  await Navigator.push(context, MaterialPageRoute(builder: (_) => PublicChatPreviewScreen(info: info)));
}

/// "Similar channels" strip for a channel's info page (shared subscribers first, then the same topic).
class SimilarChannels extends StatefulWidget {
  const SimilarChannels({super.key, required this.chatId});
  final int chatId;

  @override
  State<SimilarChannels> createState() => _SimilarChannelsState();
}

class _SimilarChannelsState extends State<SimilarChannels> {
  List<Map<String, dynamic>>? _list;

  @override
  void initState() {
    super.initState();
    context.read<ChatStore>().similarChannels(widget.chatId).then((l) {
      if (mounted) setState(() => _list = l);
    }).catchError((_) {
      if (mounted) setState(() => _list = const []);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    if (l == null || l.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _Header('Similar channels'),
      SizedBox(
        height: 178,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [for (final c in l) _ChannelCard(info: c, onTap: () => openPublicSummary(context, c))],
        ),
      ),
    ]);
  }
}
