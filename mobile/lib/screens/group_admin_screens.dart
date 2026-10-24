import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/premium.dart';
import 'chat_screen.dart';

// ------------------------------------------------------------------ admin rights
const adminRightLabels = <String, (IconData, String)>{
  'change_info': (Icons.edit_rounded, 'Change group info'),
  'delete_messages': (Icons.delete_sweep_rounded, 'Delete messages'),
  'ban_users': (Icons.person_off_rounded, 'Remove and mute members'),
  'invite_users': (Icons.person_add_alt_1_rounded, 'Add members & invite links'),
  'pin_messages': (Icons.push_pin_rounded, 'Pin messages'),
  'post_messages': (Icons.campaign_rounded, 'Publish posts (channels)'),
};

/// Owner → make someone an admin: pick what they may do and an optional title ("Moderator").
/// Returns (rights, title) or null when cancelled.
Future<(Map<String, bool>, String)?> editAdminRights(BuildContext context, {required String name, required bool channel, Map<String, bool>? current, String? title}) {
  final rights = {for (final k in adminRightLabels.keys) k: current?[k] ?? true};
  final titleCtl = TextEditingController(text: title ?? '');
  return showModalBottomSheet<(Map<String, bool>, String)>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Admin rights · $name', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              TextField(
                controller: titleCtl,
                maxLength: 24,
                decoration: const InputDecoration(labelText: 'Custom title (optional)', hintText: 'e.g. Moderator', prefixIcon: Icon(Icons.badge_rounded)),
              ),
              for (final e in adminRightLabels.entries)
                if (channel || e.key != 'post_messages')
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(e.value.$1),
                    title: Text(e.value.$2),
                    value: rights[e.key]!,
                    onChanged: (v) => setSt(() => rights[e.key] = v),
                  ),
              const SizedBox(height: 8),
              AuroraButton(label: 'Save', icon: Icons.check_rounded, onPressed: () => Navigator.pop(ctx, (rights, titleCtl.text.trim()))),
            ]),
          ),
        ),
      ),
    ),
  );
}

/// Mute a member: 1 hour / 1 day / 1 week / 1 year, or lift it. Returns minutes (0 = lift) or null.
Future<int?> pickRestriction(BuildContext context, {required String name, required bool restricted}) {
  return showModalBottomSheet<int>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Align(alignment: Alignment.centerLeft, child: Text('Mute $name in this group', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
        ),
        for (final (m, label) in const [(60, 'For 1 hour'), (1440, 'For 1 day'), (10080, 'For 1 week'), (525600, 'For 1 year')])
          ListTile(leading: const Icon(Icons.volume_off_rounded), title: Text(label), onTap: () => Navigator.pop(ctx, m)),
        if (restricted)
          ListTile(leading: const Icon(Icons.volume_up_rounded, color: Brand.accent), title: const Text('Unmute now'), onTap: () => Navigator.pop(ctx, 0)),
      ]),
    ),
  );
}

// ------------------------------------------------------------------ recent actions
class RecentActionsScreen extends StatefulWidget {
  const RecentActionsScreen({super.key, required this.chat});
  final Chat chat;

  @override
  State<RecentActionsScreen> createState() => _RecentActionsScreenState();
}

class _RecentActionsScreenState extends State<RecentActionsScreen> {
  final List<Map<String, dynamic>> _events = [];
  bool _loading = true;
  bool _more = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final before = _events.isEmpty ? null : (_events.last['id'] as num).toInt();
      final r = await context.read<ChatStore>().chatEvents(widget.chat.id, before: before);
      if (!mounted) return;
      setState(() {
        _events.addAll(r);
        _more = r.length >= 100;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  static String _name(dynamic u) => u is Map ? AppUser.fromJson(Map<String, dynamic>.from(u)).name : 'Someone';

  (IconData, Color, String) _describe(Map<String, dynamic> e) {
    final who = _name(e['actor']);
    final target = _name(e['target']);
    final d = (e['details'] as Map?) ?? const {};
    switch (e['action']) {
      case 'member_joined':
        return (Icons.login_rounded, Brand.green, '$who joined');
      case 'member_added':
        return (Icons.person_add_alt_1_rounded, Brand.green, '$who added $target');
      case 'member_left':
        return (Icons.logout_rounded, Brand.muted, '$target left');
      case 'member_removed':
        return (Icons.person_remove_rounded, Colors.red, '$who removed $target');
      case 'member_restricted':
        final m = (d['minutes'] as num?)?.toInt() ?? 0;
        final span = m >= 525600 ? '1 year' : m >= 10080 ? '1 week' : m >= 1440 ? '1 day' : '1 hour';
        return (Icons.volume_off_rounded, Brand.amber, '$who muted $target for $span');
      case 'member_unrestricted':
        return (Icons.volume_up_rounded, Brand.accent, '$who unmuted $target');
      case 'admin_set':
        final t = '${d['title'] ?? ''}';
        return (Icons.admin_panel_settings_rounded, Brand.violet, '$who made $target an admin${t.isEmpty ? '' : ' ($t)'}');
      case 'admin_removed':
        return (Icons.remove_moderator_rounded, Brand.muted, '$who removed admin rights of $target');
      case 'message_deleted':
        final text = '${d['text'] ?? ''}';
        return (Icons.delete_rounded, Colors.red, '$who deleted a message from $target${text.isEmpty ? '' : ': “$text”'}');
      case 'message_pinned':
        return (Icons.push_pin_rounded, Brand.sky, '$who pinned a message');
      case 'photo_changed':
        return (Icons.photo_camera_rounded, Brand.sky, '$who changed the photo');
      case 'photo_removed':
        return (Icons.hide_image_rounded, Brand.muted, '$who removed the photo');
      case 'info_changed':
        final t = d['title'];
        return (Icons.edit_rounded, Brand.sky, t != null ? '$who renamed it to “$t”' : '$who changed the info');
      case 'settings_changed':
        final f = ((d['fields'] as List?) ?? const []).map((x) => '$x'.replaceAll('_', ' ')).join(', ');
        return (Icons.tune_rounded, Brand.violet, '$who changed settings${f.isEmpty ? '' : ': $f'}');
      case 'post_approved':
        return (Icons.check_circle_rounded, Brand.green, '$who published a post by $target');
      case 'post_declined':
        return (Icons.cancel_rounded, Colors.red, '$who declined a post by $target');
      default:
        return (Icons.history_rounded, Brand.muted, '$who: ${e['action']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM, HH:mm');
    return Scaffold(
      appBar: AppBar(title: const Text('Recent actions')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _events.isEmpty
              ? const EmptyState(tali: 'think', title: 'Nothing yet', subtitle: 'What admins and members do here (joins, removals, deleted messages, setting changes) shows up here.')
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (_more && !_loading && n.metrics.extentAfter < 200) {
                      _loading = true;
                      _load();
                    }
                    return false;
                  },
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _events.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 64),
                    itemBuilder: (_, i) {
                      final e = _events[i];
                      final (icon, color, text) = _describe(e);
                      return ListTile(
                        leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.14), child: Icon(icon, color: color, size: 20)),
                        title: Text(text, style: const TextStyle(fontSize: 14.5)),
                        subtitle: Text(fmt.format(DateTime.parse('${e['created_at']}').toLocal())),
                      );
                    },
                  ),
                ),
    );
  }
}

// ------------------------------------------------------------------ post queue (channels)
class PostQueueScreen extends StatefulWidget {
  const PostQueueScreen({super.key, required this.chat});
  final Chat chat;

  @override
  State<PostQueueScreen> createState() => _PostQueueScreenState();
}

class _PostQueueScreenState extends State<PostQueueScreen> {
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<ChatStore>().postQueue(widget.chat.id);
      if (mounted) setState(() => _data = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _act(Future<void> Function() f, String done) async {
    try {
      await f();
      if (mounted) showInfo(context, done);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final store = context.read<ChatStore>();
    final posts = ((d?['posts'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final canPublish = d?['can_publish'] == true;
    final fmt = DateFormat('d MMM, HH:mm');
    return Scaffold(
      appBar: AppBar(title: const Text('Drafts & approvals')),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : posts.isEmpty
              ? const EmptyState(tali: 'cool', title: 'All clear', subtitle: 'Posts saved as drafts, or written by admins who need approval, wait here.')
              : ListView(padding: const EdgeInsets.all(12), children: [
                  for (final p in posts)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            if (p['author'] is Map)
                              Builder(builder: (_) {
                                final u = AppUser.fromJson(Map<String, dynamic>.from(p['author'] as Map));
                                return Avatar(id: u.id, name: u.name, url: u.avatarAbsolute, size: 30);
                              }),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                p['author'] is Map ? AppUser.fromJson(Map<String, dynamic>.from(p['author'] as Map)).name : 'Admin',
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            Text(fmt.format(DateTime.parse('${p['created_at']}').toLocal()), style: const TextStyle(fontSize: 12, color: Brand.muted)),
                          ]),
                          const SizedBox(height: 10),
                          if (p['has_media'] == true)
                            const Padding(padding: EdgeInsets.only(bottom: 6), child: Row(children: [Icon(Icons.attachment_rounded, size: 16), SizedBox(width: 4), Text('With a photo / file')])),
                          Text('${p['text']}'.isEmpty ? '(no text)' : '${p['text']}', maxLines: 8, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 10),
                          Row(children: [
                            if (canPublish || p['mine'] == true)
                              TextButton.icon(
                                onPressed: () => _act(() => store.deleteQueued(widget.chat.id, (p['id'] as num).toInt()), 'Deleted'),
                                icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                                label: Text(p['mine'] == true ? 'Delete' : 'Decline', style: const TextStyle(color: Colors.red)),
                              ),
                            const Spacer(),
                            if (canPublish)
                              FilledButton.icon(
                                onPressed: () => _act(() => store.publishQueued(widget.chat.id, (p['id'] as num).toInt()), 'Published'),
                                icon: const Icon(Icons.send_rounded, size: 18),
                                label: const Text('Publish'),
                              ),
                          ]),
                        ]),
                      ),
                    ),
                ]),
    );
  }
}

// ------------------------------------------------------------------ reactions setting
Future<void> editAllowedReactions(BuildContext context, Chat chat) async {
  final store = context.read<ChatStore>();
  final all = ChatStore.reactionEmojis;
  var mode = chat.allowedReactions == null ? 'all' : (chat.allowedReactions!.isEmpty ? 'none' : 'some');
  final picked = {...(chat.allowedReactions ?? all)};
  final ok = await showModalBottomSheet<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Reactions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'all', label: Text('All')), ButtonSegment(value: 'some', label: Text('Some')), ButtonSegment(value: 'none', label: Text('None'))],
              selected: {mode},
              onSelectionChanged: (s) => setSt(() => mode = s.first),
            ),
            if (mode == 'some') ...[
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final e in all)
                  FilterChip(
                    label: Text(e, style: const TextStyle(fontSize: 20)),
                    selected: picked.contains(e),
                    onSelected: (v) => setSt(() => v ? picked.add(e) : picked.remove(e)),
                  ),
              ]),
            ],
            const SizedBox(height: 16),
            AuroraButton(label: 'Save', onPressed: () => Navigator.pop(ctx, true)),
          ]),
        ),
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await store.updateChat(chat.id, {'allowed_reactions': mode == 'all' ? null : (mode == 'none' ? <String>[] : picked.toList())});
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Long text settings (welcome message, rules).
Future<void> editChatText(BuildContext context, Chat chat, {required String field, required String title, required String hint, required int max, required String current}) async {
  final ctl = TextEditingController(text: current);
  final v = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctl, maxLength: max, maxLines: 6, minLines: 3, autofocus: true, decoration: InputDecoration(hintText: hint)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
      ],
    ),
  );
  if (v == null || !context.mounted) return;
  try {
    await context.read<ChatStore>().updateChat(chat.id, {field: v});
    if (context.mounted) showInfo(context, v.isEmpty ? 'Removed' : 'Saved');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Channel → discussion group: one of my groups where I'm an admin (or none).
Future<void> pickDiscussionGroup(BuildContext context, Chat channel) async {
  final store = context.read<ChatStore>();
  final groups = store.chats.where((c) => c.isGroup && c.isAdmin).toList();
  final picked = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('Discussion group', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Every new post is also shared in this group so subscribers can talk about it.', style: TextStyle(color: Brand.muted)),
          ),
          if (channel.linkedChat != null)
            ListTile(leading: const Icon(Icons.link_off_rounded, color: Colors.red), title: const Text('Unlink the group'), onTap: () => Navigator.pop(ctx, 0)),
          if (groups.isEmpty)
            const Padding(padding: EdgeInsets.all(20), child: Text('Create a group first (you need to be its admin).')),
          for (final g in groups)
            ListTile(
              leading: Avatar(id: g.id, name: g.title, url: g.avatarAbsolute, size: 40),
              title: Text(g.title),
              subtitle: Text('${g.memberCount} members'),
              trailing: channel.linkedChat?.id == g.id ? const Icon(Icons.check_circle_rounded, color: Brand.accent) : null,
              onTap: () => Navigator.pop(ctx, g.id),
            ),
        ]),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  try {
    await store.updateChat(channel.id, {'linked_chat_id': picked == 0 ? null : picked});
    if (context.mounted) showInfo(context, picked == 0 ? 'Discussion group unlinked' : 'Discussion group linked');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

const channelCategories = <String, (IconData, String)>{
  'news': (Icons.newspaper_rounded, 'News'),
  'tech': (Icons.memory_rounded, 'Tech'),
  'sports': (Icons.sports_soccer_rounded, 'Sports'),
  'entertainment': (Icons.movie_rounded, 'Entertainment'),
  'education': (Icons.school_rounded, 'Education'),
  'business': (Icons.business_center_rounded, 'Business'),
  'religion': (Icons.mosque_rounded, 'Religion'),
  'lifestyle': (Icons.spa_rounded, 'Lifestyle'),
  'gaming': (Icons.sports_esports_rounded, 'Gaming'),
  'other': (Icons.category_rounded, 'Other'),
};

Future<void> pickChannelCategory(BuildContext context, Chat chat) async {
  final v = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(alignment: Alignment.centerLeft, child: Text('Category in the channel directory', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          ),
          for (final e in channelCategories.entries)
            ListTile(
              leading: Icon(e.value.$1),
              title: Text(e.value.$2),
              trailing: chat.category == e.key ? const Icon(Icons.check_rounded, color: Brand.accent) : null,
              onTap: () => Navigator.pop(ctx, e.key),
            ),
        ]),
      ),
    ),
  );
  if (v == null || !context.mounted) return;
  try {
    await context.read<ChatStore>().updateChat(chat.id, {'category': v});
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

// ------------------------------------------------------------------ channel directory
class ChannelDirectoryScreen extends StatefulWidget {
  const ChannelDirectoryScreen({super.key});

  @override
  State<ChannelDirectoryScreen> createState() => _ChannelDirectoryScreenState();
}

class _ChannelDirectoryScreenState extends State<ChannelDirectoryScreen> {
  String _cat = 'trending';
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _list;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final my = ++_req;
    setState(() => _list = null);
    try {
      final r = await context.read<ChatStore>().channelDirectory(category: _cat, q: _q.text.trim());
      if (!mounted || my != _req) return;
      setState(() => _list = ((r['channels'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } catch (e) {
      if (mounted && my == _req) {
        setState(() => _list = []);
        showError(context, e);
      }
    }
  }

  Future<void> _open(Map<String, dynamic> c) async {
    final store = context.read<ChatStore>();
    final id = ((c['id'] ?? c['chat_id']) as num).toInt();
    try {
      if (c['is_member'] != true) {
        final joined = await store.joinPublic(id);
        if (joined == null) {
          if (mounted) showInfo(context, 'Join request sent to the admins');
          return;
        }
      }
      final chat = await store.getChat(id);
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: id, initial: chat)));
      setState(() => c['is_member'] = true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final cats = <String, (IconData, String)>{'trending': (Icons.local_fire_department_rounded, 'Trending'), ...channelCategories};
    return Scaffold(
      appBar: AppBar(title: const Text('Explore channels')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              hintText: 'Search channels',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward_rounded), onPressed: _load),
            ),
          ),
        ),
        SizedBox(
          height: 46,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final e in cats.entries)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  avatar: Icon(e.value.$1, size: 18, color: _cat == e.key ? Colors.white : Brand.muted),
                  label: Text(e.value.$2),
                  selected: _cat == e.key,
                  onSelected: (_) {
                    setState(() => _cat = e.key);
                    _load();
                  },
                ),
              ),
          ]),
        ),
        Expanded(
          child: list == null
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
                  ? const EmptyState(tali: 'think', title: 'No channels here yet', subtitle: 'Public channels pick a category in Channel info → Category.')
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final c = list[i];
                        final id = ((c['id'] ?? c['chat_id']) as num).toInt();
                        final member = c['is_member'] == true;
                        final avatar = c['avatar_url'] as String?;
                        return ListTile(
                          onTap: () => _open(c),
                          leading: Avatar(id: id, name: '${c['title']}', url: avatar == null ? null : AppConfig.absolute(avatar), size: 50),
                          title: Row(children: [
                            Flexible(child: Text('${c['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                            if (c['is_verified'] == true) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified_rounded, size: 16, color: Brand.sky)),
                          ]),
                          subtitle: Text(
                            '${compactNumber((c['member_count'] as num?)?.toInt() ?? 0)} subscribers'
                            '${((c['new_this_week'] as num?)?.toInt() ?? 0) > 0 ? ' · +${c['new_this_week']} this week' : ''}'
                            '${'${c['description'] ?? ''}'.isEmpty ? '' : '\n${c['description']}'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          isThreeLine: '${c['description'] ?? ''}'.isNotEmpty,
                          trailing: member
                              ? const Icon(Icons.check_circle_rounded, color: Brand.accent)
                              : FilledButton(
                                  style: FilledButton.styleFrom(minimumSize: const Size(64, 36), padding: const EdgeInsets.symmetric(horizontal: 14)),
                                  onPressed: () => _open(c),
                                  child: const Text('Join'),
                                ),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}
