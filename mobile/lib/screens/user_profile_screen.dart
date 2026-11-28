import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/chat_links.dart';
import '../core/services.dart';
import '../widgets/avatar.dart';
import '../widgets/celebration.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/report_dialog.dart';
import 'calls_screen.dart';
import 'secret_screens.dart';
import 'chat_screen.dart';
import '../theme/brand.dart';
import '../widgets/premium.dart';
import 'catalog_screen.dart';
import 'coins_screen.dart';
import 'shared_media_screen.dart';
import 'story_screens.dart' show HighlightsRow;
import '../widgets/emoji_status.dart';
import '../widgets/profile_tags.dart';

class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key, required this.userId});
  final int userId;

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  AppUser? _user;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final j = await context.read<AppServices>().api.get('/users/${widget.userId}');
      if (mounted) setState(() => _user = AppUser.fromJson(Map<String, dynamic>.from(j as Map)));
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _toggle(String path, bool on) async {
    final api = context.read<AppServices>().api;
    try {
      if (on) {
        await api.post(path);
      } else {
        await api.delete(path);
      }
      await _load();
      if (!mounted) return;
      // refresh the private chat so the input bar reflects block state
      final store = context.read<ChatStore>();
      for (final c in store.chats.where((c) => c.peer?.id == widget.userId).toList()) {
        store.refreshChat(c.id);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _message(AppUser u) async {
    try {
      final chat = await context.read<ChatStore>().openPrivateWith(u.id);
      if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Bots: pick one of my groups/channels where I can add people.
  Future<void> _addBotToGroup(AppUser bot) async {
    final store = context.read<ChatStore>();
    final places = store.chats.where((c) => (c.isGroup || c.isChannel) && c.can('invite_users') && !c.isSuspended).toList();
    if (places.isEmpty) {
      showInfo(context, 'You need to be an admin of a group or channel first');
      return;
    }
    final pick = await showModalBottomSheet<Chat>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Add ${bot.name} to…', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            for (final c in places)
              ListTile(
                leading: Avatar(id: c.id, name: c.title, url: c.avatarAbsolute, size: 42),
                title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(c.isChannel ? 'Channel' : 'Group'),
                onTap: () => Navigator.pop(ctx, c),
              ),
          ]),
        ),
      ),
    );
    if (pick == null || !mounted) return;
    try {
      await store.addMembers(pick.id, [bot.id]);
      if (mounted) showInfo(context, '${bot.name} added to ${pick.title}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = _user;
    final store = context.watch<ChatStore>();
    final myId = store.myId;
    final auth = context.read<AuthState>();
    final chat = u == null ? null : store.chats.where((c) => c.peer?.id == u.id).firstOrNull;
    final other = u != null && !u.deleted && u.id != myId;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: u == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : Stack(children: [
              ListView(
              padding: EdgeInsets.zero,
              children: [
                _ContactHeader(
                  user: u,
                  status: u.isBot ? 'Bot' : (u.blockedMe ? 'Has blocked you' : lastSeenText(u)),
                  actions: [
                    if (other) ...[
                      ProfileAction(icon: Icons.chat_bubble_rounded, label: 'Message', highlight: true, onTap: () => _message(u)),
                      if (u.isBot) ...[
                        ProfileAction(icon: Icons.group_add_rounded, label: 'Add to group', onTap: () => _addBotToGroup(u)),
                        if (u.username != null)
                          ProfileAction(
                            icon: Icons.ios_share_rounded,
                            label: 'Share',
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: publicChatLink(u.username!)));
                              showInfo(context, 'Bot link copied');
                            },
                          ),
                      ],
                      if (!u.isBot && !u.blockedMe && auth.feature('calls')) ProfileAction(icon: Icons.call_rounded, label: 'Call', onTap: () => startCall(context, u, video: false)),
                      if (!u.isBot && !u.blockedMe && auth.feature('calls') && auth.feature('video_calls'))
                        ProfileAction(icon: Icons.videocam_rounded, label: 'Video', onTap: () => startCall(context, u, video: true)),
                      if (chat != null)
                        ProfileAction(
                          icon: chat.isMuted ? Icons.notifications_off_rounded : Icons.notifications_rounded,
                          label: chat.isMuted ? 'Unmute' : 'Mute',
                          onTap: () async {
                            try {
                              await store.updateChatSettings(chat.id, {'muted_until': chat.isMuted ? null : 'forever'});
                            } catch (e) {
                              if (mounted) showError(this.context, e);
                            }
                          },
                        ),

                    ],
                  ],
                ),
                if (u.birthday?.isToday == true && !u.deleted)
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                    padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFFFF8A65), Color(0xFF8F72FF), Color(0xFF8E54E9)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: [BoxShadow(color: const Color(0xFF8F72FF).withValues(alpha: 0.3), blurRadius: 18, offset: const Offset(0, 6))],
                    ),
                    child: Row(children: [
                      const Text('🎂', style: TextStyle(fontSize: 34)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(u.id == myId ? 'Happy birthday to you!' : 'It’s ${u.firstName.isEmpty ? u.name : u.firstName}’s birthday!',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                          const SizedBox(height: 2),
                          Text(u.id == myId ? 'Everyone who opens your profile today sees the party 🎉' : 'Send a wish and make their day 🎉',
                              style: const TextStyle(color: Colors.white, fontSize: 12.5)),
                        ]),
                      ),
                      if (other)
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFFE0417A), padding: const EdgeInsets.symmetric(horizontal: 14)),
                          onPressed: () async {
                            try {
                              final chat = await context.read<ChatStore>().openPrivateWith(u.id);
                              if (!mounted) return;
                              await this.context.read<ChatStore>().sendText(chat.id, 'Happy birthday, ${u.firstName.isEmpty ? u.name : u.firstName}! 🎂🎉');
                              if (mounted) showInfo(this.context, 'Wish sent 🎉');
                            } catch (e) {
                              if (mounted) showError(this.context, e);
                            }
                          },
                          child: const Text('Wish 🎈', style: TextStyle(fontWeight: FontWeight.w800)),
                        ),
                    ]),
                  ),
                if (!u.deleted && !u.isBot) _TagsRow(user: u),
                if (!u.deleted) HighlightsRow(key: ValueKey('hl${u.id}'), userId: u.id, mine: u.id == myId),
                // shown only when there is something to show (no empty "no info" card, no raw ID numbers)
                if (u.phone != null || u.username != null || u.bio.isNotEmpty || u.birthday != null)
                SettingsGroup(title: 'Info', children: [
                  if (u.phone != null)
                    SettingsTile(
                      icon: Icons.phone_rounded,
                      color: Brand.green,
                      title: u.phone!,
                      subtitle: 'Mobile · tap to copy',
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: u.phone!));
                        showInfo(context, 'Phone number copied');
                      },
                    ),
                  if (u.username != null)
                    SettingsTile(
                      icon: Icons.alternate_email_rounded,
                      color: Brand.sky,
                      title: '@${u.username}',
                      subtitle: 'Username · tap to copy',
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: '@${u.username}'));
                        showInfo(context, 'Username copied');
                      },
                    ),
                  if (u.bio.isNotEmpty) SettingsTile(icon: Icons.info_rounded, color: Brand.violet, title: u.bio, subtitle: u.isBot ? 'About' : 'Bio', maxSubtitleLines: 1),
                  if (u.birthday != null)
                    SettingsTile(
                      icon: Icons.cake_rounded,
                      color: Brand.rose,
                      title: u.birthday!.isToday ? '${u.birthday!.label} 🎉' : u.birthday!.label,
                      subtitle: u.birthday!.isToday && other ? 'Birthday today — send a wish!' : 'Birthday',
                      onTap: u.birthday!.isToday && other ? () => _message(u) : null,
                    ),
                ]),
                if (!u.deleted && !u.isBot) _CatalogEntry(userId: u.id, name: u.name),
                if (chat != null || (other && !u.isBot && auth.feature('secret_chats')))
                  SettingsGroup(children: [
                    if (other && !u.isBot && auth.feature('secret_chats'))
                      SettingsTile(icon: Icons.lock_outline_rounded, color: Theme.of(context).colorScheme.primary,
                        title: 'Vault chat', onTap: () => startSecretChat(context, u)),
                    if (chat != null)
                    SettingsTile(
                      icon: Icons.perm_media_rounded,
                      color: Brand.primary,
                      title: 'Shared media',
                      subtitle: 'Photos, files, links and voice',
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SharedMediaScreen(chat: chat))),
                    ),
                  ]),
                if (other)
                  SettingsGroup(children: [
                    if (!u.isBot)
                    SettingsTile(
                      icon: u.isContact ? Icons.person_remove_rounded : Icons.person_add_alt_1_rounded,
                      color: Brand.sky,
                      title: u.isContact ? 'Remove from contacts' : 'Add to contacts',
                      onTap: () => _toggle('/contacts/${u.id}', !u.isContact),
                    ),
                    if (!u.isBot && !u.blocked && !u.blockedMe && auth.feature('coins'))
                      SettingsTile(
                        icon: Icons.card_giftcard_rounded,
                        color: const Color(0xFFF5A623),
                        title: 'Send coins',
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CoinsScreen(sendTo: u))),
                      ),
                    SettingsTile(
                      icon: Icons.flag_rounded,
                      color: Brand.amber,
                      title: 'Report',
                      onTap: () => showReportDialog(context, targetType: 'user', targetId: u.id),
                    ),
                    SettingsTile(
                      icon: Icons.block_rounded,
                      color: const Color(0xFFE5484D),
                      title: u.blocked ? 'Unblock' : (u.isBot ? 'Stop & block bot' : 'Block'),
                      danger: !u.blocked,
                      onTap: () async {
                        if (!u.blocked &&
                            !await confirm(context, 'Block ${u.name}?', 'They won’t be able to message or call you.', ok: 'Block', danger: true)) {
                          return;
                        }
                        await _toggle('/blocks/${u.id}', !u.blocked);
                      },
                    ),
                  ]),
                SizedBox(height: 24 + MediaQuery.paddingOf(context).bottom),
              ],
            ),
              // birthday today: fireworks and balloons for everyone who opens the profile
              if (u.birthday?.isToday == true && !u.deleted) const Positioned.fill(child: BirthdayCelebration()),
            ]),
    );
  }
}


/// "Catalog · 12 products" on a business profile (shown only when there are products).
class _CatalogEntry extends StatefulWidget {
  const _CatalogEntry({required this.userId, required this.name});
  final int userId;
  final String name;

  @override
  State<_CatalogEntry> createState() => _CatalogEntryState();
}

class _CatalogEntryState extends State<_CatalogEntry> {
  static final Map<int, int> _count = {};
  late int? _n = _count[widget.userId];

  @override
  void initState() {
    super.initState();
    context.read<AppServices>().api.get('/users/${widget.userId}/catalog').then((r) {
      final n = ((r as Map)['items'] as List).length;
      _count[widget.userId] = n;
      if (mounted) setState(() => _n = n);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final n = _n ?? 0;
    if (n == 0) return const SizedBox.shrink();
    return SettingsGroup(children: [
      SettingsTile(
        icon: Icons.storefront_rounded,
        color: const Color(0xFF6D4AFF),
        title: 'Catalog',
        subtitle: '$n product${n == 1 ? '' : 's'} · order in the chat or pay with coins',
        maxSubtitleLines: 1,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CatalogScreen(userId: widget.userId, name: widget.name))),
      ),
    ]);
  }
}


/// Tags under the name: the ones on the profile card at once, plus the computed ones
/// (many reports, trusted seller) as soon as the server answers.
class _TagsRow extends StatefulWidget {
  const _TagsRow({required this.user});
  final AppUser user;

  @override
  State<_TagsRow> createState() => _TagsRowState();
}

class _TagsRowState extends State<_TagsRow> {
  late List<String> _tags = widget.user.tags;

  @override
  void initState() {
    super.initState();
    context.read<AppServices>().api.get('/users/${widget.user.id}/trust').then((r) {
      final t = (r as Map)['tags'];
      if (t is List && mounted) setState(() => _tags = {..._tags, for (final x in t) '$x'}.toList());
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    if (TagLook.sorted(_tags).isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: ProfileTags(_tags, center: true));
  }
}

class _ContactHeader extends StatelessWidget {
  const _ContactHeader({required this.user, required this.status, required this.actions});

  final AppUser user;
  final String status;
  final List<ProfileAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Color.alphaBlend(scheme.primary.withValues(alpha: .12), scheme.surface), scheme.surface],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: user.isPremium ? Brand.premium : scheme.outlineVariant, width: 2),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Padding(padding: const EdgeInsets.all(3),
                  child: Avatar(id: user.id, name: user.name, url: user.avatarAbsolute, size: 64)),
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 5, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(user.name, style: theme.textTheme.titleLarge),
                  if (user.isVerified) const Icon(Icons.verified_rounded, size: 20, color: Brand.sky),
                  if (user.statusEmoji != null) EmojiStatusBadge(user, size: 20, padLeft: 0)
                  else if (user.isPremium) const Icon(Icons.workspace_premium_rounded, size: 20, color: Brand.premium),
                ]),
                const SizedBox(height: 4),
                Text(status, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ])),
            ]),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 18),
              FilledButton.icon(onPressed: actions.first.onTap, icon: Icon(actions.first.icon, size: 19),
                label: Text(actions.first.label)),
              if (actions.length > 1) ...[
                const SizedBox(height: 8),
                Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 6, children: [
                  for (final action in actions.skip(1))
                    OutlinedButton.icon(onPressed: action.onTap, icon: Icon(action.icon, size: 17),
                      label: Text(action.label), style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.primary, minimumSize: const Size(48, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 12))),
                ]),
              ],
            ],
          ]),
        ),
      ),
    );
  }
}
