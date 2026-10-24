import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'shared_media_screen.dart';

import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/report_dialog.dart';
import 'channel_screens.dart';
import 'more_screens.dart';
import 'new_chat_screen.dart';
import 'user_profile_screen.dart';
import 'group_admin_screens.dart';
import 'chat_screen.dart';
import '../theme/brand.dart';
import '../widgets/premium.dart';

class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({super.key, required this.chatId});
  final int chatId;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  late final ChatStore _store;

  @override
  void initState() {
    super.initState();
    _store = context.read<ChatStore>();
    _store.loadMembers(widget.chatId).catchError((e) {
      if (mounted) showError(context, e);
      return <GroupMember>[];
    });
  }

  Future<void> _run(Future<void> Function() fn, [String? ok]) async {
    try {
      await fn();
      if (ok != null && mounted) showInfo(context, ok);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _editText(Chat chat, {required bool title}) async {
    final ctrl = TextEditingController(text: title ? chat.title : chat.description);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title ? 'Group name' : 'Description'),
        content: TextField(controller: ctrl, autofocus: true, maxLength: title ? 128 : 255, maxLines: title ? 1 : 4),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (v == null) return;
    await _run(() => _store.updateGroup(chat.id, title: title ? v : null, description: title ? null : v));
  }

  Future<void> _editUsername(Chat chat) async {
    final ctrl = TextEditingController(text: chat.username ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Public link'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctrl, autofocus: true, maxLength: 32, decoration: const InputDecoration(prefixText: '@', hintText: 'username')),
          const Text('Leave empty to make it private.', style: TextStyle(fontSize: 12, color: Brand.muted)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim().replaceFirst('@', '')), child: const Text('Save')),
        ],
      ),
    );
    if (v == null) return;
    await _run(() => _store.setChatUsername(chat.id, v.isEmpty ? null : v), v.isEmpty ? 'Now private' : 'Public link saved');
  }

  Future<void> _changePhoto(Chat chat) async {
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.photo), title: const Text('Choose photo'), onTap: () => Navigator.pop(ctx, 'pick')),
          if (chat.avatarUrl != null)
            ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Remove photo'), onTap: () => Navigator.pop(ctx, 'remove')),
        ]),
      ),
    );
    if (a == 'pick') {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
      if (x != null) await _run(() => _store.setGroupAvatar(chat.id, x.path));
    } else if (a == 'remove') {
      await _run(() => _store.setGroupAvatar(chat.id, null));
    }
  }

  Future<void> _addMembers(Chat chat) async {
    final picked = <int, AppUser>{};
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) => Scaffold(
            appBar: AppBar(title: Text(picked.isEmpty ? 'Add members' : '${picked.length} selected')),
            body: UserSearch(
              selectedIds: picked.keys.toSet(),
              onTap: (u) => setState(() {
                if (picked.containsKey(u.id)) {
                  picked.remove(u.id);
                } else {
                  picked[u.id] = u;
                }
              }),
            ),
            floatingActionButton: FloatingActionButton(onPressed: () => Navigator.pop(ctx, true), child: const Icon(Icons.check)),
          ),
        ),
      ),
    );
    if (ok != true || picked.isEmpty) return;
    try {
      final skipped = await _store.addMembers(chat.id, picked.keys.toList());
      if (!mounted) return;
      showInfo(context, skipped.isEmpty ? 'Members added' : '${skipped.length} could not be added (privacy settings)');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  static const _slowModes = [0, 10, 30, 60, 300, 900, 3600];

  static String _slowLabel(int sec) {
    if (sec == 0) return 'Off';
    if (sec < 60) return '${sec}s';
    if (sec < 3600) return '${sec ~/ 60}m';
    return '${sec ~/ 3600}h';
  }

  Future<void> _pickSlowMode(Chat chat) async {
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Slow mode'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Members can send one message per this interval. Admins are not limited.'),
          ),
          ..._slowModes.map((s) => RadioListTile<int>(
                value: s,
                groupValue: chat.slowModeSec,
                title: Text(_slowLabel(s)),
                onChanged: (x) => Navigator.pop(ctx, x),
              )),
        ],
      ),
    );
    if (v == null || v == chat.slowModeSec) return;
    await _run(() => _store.patchChat(chat.id, {'slow_mode_sec': v}));
  }

  Future<void> _memberActions(Chat chat, GroupMember m) async {
    if (m.user.id == _store.myId) return;
    final canRemove = chat.isOwner || (chat.myRole == 'admin' && m.role == 'member' && chat.can('ban_users'));
    final canMute = chat.isGroup && m.role == 'member' && chat.can('ban_users');
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.person), title: const Text('View profile'), onTap: () => Navigator.pop(ctx, 'profile')),
          if (chat.isOwner && m.role == 'member')
            ListTile(leading: const Icon(Icons.admin_panel_settings), title: const Text('Make admin'), onTap: () => Navigator.pop(ctx, 'admin')),
          if (chat.isOwner && m.role == 'admin')
            ListTile(leading: const Icon(Icons.tune_rounded), title: const Text('Edit admin rights'), onTap: () => Navigator.pop(ctx, 'admin')),
          if (chat.isOwner && m.role == 'admin')
            ListTile(leading: const Icon(Icons.remove_moderator), title: const Text('Remove admin rights'), onTap: () => Navigator.pop(ctx, 'member')),
          if (canMute)
            ListTile(
              leading: Icon(m.isRestricted ? Icons.volume_up_rounded : Icons.volume_off_rounded),
              title: Text(m.isRestricted ? 'Muted — change or unmute' : 'Mute in this group'),
              onTap: () => Navigator.pop(ctx, 'restrict'),
            ),
          if (chat.isOwner)
            ListTile(leading: const Icon(Icons.key_outlined), title: const Text('Transfer ownership'), onTap: () => Navigator.pop(ctx, 'owner')),
          if (canRemove && m.role != 'owner')
            ListTile(
              leading: const Icon(Icons.person_remove, color: Colors.red),
              title: const Text('Remove from group', style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
        ]),
      ),
    );
    if (!mounted || a == null) return;
    switch (a) {
      case 'profile':
        Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfileScreen(userId: m.user.id)));
        break;
      case 'admin':
        final r = await editAdminRights(context, name: m.user.name, channel: chat.isChannel, current: m.rights, title: m.title);
        if (r == null) return;
        await _run(() => _store.setRole(chat.id, m.user.id, 'admin', rights: r.$1, title: r.$2), '${m.user.name} is an admin');
        break;
      case 'member':
        await _run(() => _store.setRole(chat.id, m.user.id, 'member'));
        break;
      case 'restrict':
        final minutes = await pickRestriction(context, name: m.user.name, restricted: m.isRestricted);
        if (minutes == null) return;
        await _run(() => _store.restrictMember(chat.id, m.user.id, minutes), minutes == 0 ? '${m.user.name} can write again' : '${m.user.name} is muted');
        break;
      case 'owner':
        if (await confirm(context, 'Make ${m.user.name} the owner?',
            'They get full control of “${chat.title}”. You will stay as an admin and cannot undo this yourself.',
            ok: 'Transfer', danger: true)) {
          await _run(() => _store.transferOwnership(chat.id, m.user.id), '${m.user.name} is now the owner');
        }
        break;
      case 'remove':
        if (await confirm(context, 'Remove ${m.user.name}?', 'They will be removed from “${chat.title}”.', ok: 'Remove', danger: true)) {
          await _run(() => _store.removeMember(chat.id, m.user.id));
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final chat = store.chatById(widget.chatId);
    if (chat == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('You are no longer a member here')));
    }
    final members = store.members[chat.id] ?? [];
    final what = chat.isChannel ? 'channel' : 'group';
    final auth = context.read<AuthState>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          if (chat.can('change_info')) IconButton(icon: const Icon(Icons.edit_rounded), tooltip: 'Edit name', onPressed: () => _editText(chat, title: true)),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          ProfileHero(
            id: chat.id,
            name: chat.title,
            avatarUrl: chat.avatarAbsolute,
            topPadding: MediaQuery.of(context).padding.top + 44,
            onAvatarTap: chat.can('change_info')
                ? () => _changePhoto(chat)
                : (chat.avatarAbsolute == null ? null : () => showPhotoViewer(context, chat.avatarAbsolute!, tag: 'avatar-${chat.id}')),
            avatarBadge: chat.can('change_info')
                ? Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 3)),
                    child: const Icon(Icons.photo_camera_rounded, size: 16, color: Colors.white),
                  )
                : null,
            badges: [if (chat.isVerified) const Icon(Icons.verified_rounded, color: Brand.sky, size: 22)],
            status: '${chat.memberCount} ${chat.isChannel ? 'subscribers' : 'members'}${chat.username != null ? ' · public' : ''}',
            actions: [
              ProfileAction(
                icon: chat.isMuted ? Icons.notifications_off_rounded : Icons.notifications_rounded,
                label: chat.isMuted ? 'Unmute' : 'Mute',
                onTap: () => _run(() => _store.updateChatSettings(chat.id, {'muted_until': chat.isMuted ? null : 'forever'})),
              ),
              ProfileAction(icon: Icons.perm_media_rounded, label: 'Media', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SharedMediaScreen(chat: chat)))),
              if (chat.can('invite_users') && !chat.isSuspended)
                ProfileAction(icon: Icons.person_add_alt_1_rounded, label: 'Add', highlight: true, onTap: () => _addMembers(chat)),
              ProfileAction(
                icon: Icons.ios_share_rounded,
                label: 'Share',
                onTap: () async {
                  final code = chat.username != null ? '@${chat.username}' : chat.inviteCode;
                  if (code == null) {
                    showInfo(context, 'Only admins can share the invite code');
                    return;
                  }
                  await Clipboard.setData(ClipboardData(text: code));
                  if (context.mounted) showInfo(context, chat.username != null ? 'Link copied' : 'Invite code copied');
                },
              ),
            ],
          ),
          if (chat.isSuspended)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
              child: const Text('Suspended by moderators', textAlign: TextAlign.center, style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
            ),
          SettingsGroup(title: 'Info', children: [
            SettingsTile(
              icon: Icons.info_rounded,
              color: Brand.violet,
              title: chat.description.isEmpty ? (chat.can('change_info') ? 'Add a description' : 'No description') : chat.description,
              subtitle: 'Description',
              maxSubtitleLines: 1,
              onTap: chat.can('change_info') ? () => _editText(chat, title: false) : null,
            ),
            if (chat.username != null || chat.isOwner)
              SettingsTile(
                icon: Icons.alternate_email_rounded,
                color: Brand.sky,
                title: chat.username != null ? '@${chat.username}' : 'Make this $what public',
                subtitle: chat.username != null ? 'Public link — anyone can find and join' : 'Private — joins only with an invite code',
                trailingWidget: chat.username != null
                    ? IconButton(
                        icon: const Icon(Icons.copy_rounded, size: 20),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: '@${chat.username}'));
                          if (context.mounted) showInfo(context, 'Copied');
                        },
                      )
                    : null,
                onTap: chat.isOwner ? () => _editUsername(chat) : null,
              ),
            if (chat.rules.isNotEmpty || (chat.isAdmin && chat.can('change_info')))
              SettingsTile(
                icon: Icons.gavel_rounded,
                color: Brand.violet,
                title: 'Rules',
                subtitle: chat.rules.isEmpty ? 'Add rules new members see first' : chat.rules,
                maxSubtitleLines: 2,
                onTap: chat.can('change_info')
                    ? () => editChatText(context, chat, field: 'rules', title: 'Rules', hint: '1. Be kind\n2. No spam', max: 2000, current: chat.rules)
                    : () => showDialog<void>(
                          context: context,
                          builder: (ctx) => AlertDialog(title: const Text('Rules'), content: SingleChildScrollView(child: Text(chat.rules))),
                        ),
              ),
            if (chat.linkedChat != null)
              SettingsTile(
                icon: Icons.forum_rounded,
                color: Brand.green,
                title: 'Discussion group',
                subtitle: chat.linkedChat!.title,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.linkedChat!.id, initial: store.chatById(chat.linkedChat!.id)))),
              ),
            if (chat.linkedChannelId != null)
              SettingsTile(
                icon: Icons.campaign_rounded,
                color: Brand.sky,
                title: 'Linked channel',
                subtitle: 'Posts from the channel appear here',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.linkedChannelId!, initial: store.chatById(chat.linkedChannelId!)))),
              ),
            SettingsSwitchTile(
              icon: Icons.notifications_rounded,
              color: Brand.rose,
              title: 'Notifications',
              value: !chat.isMuted,
              onChanged: (on) => _run(() => _store.updateChatSettings(chat.id, {'muted_until': on ? null : 'forever'})),
            ),
          ]),
          if (chat.isAdmin)
            SettingsGroup(title: 'Admin', children: [
              SettingsTile(icon: Icons.insights_rounded, color: Brand.green, title: 'Statistics', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatStatsScreen(chat: chat)))),
              SettingsTile(
                icon: Icons.history_rounded,
                color: const Color(0xFF5E6B8C),
                title: 'Recent actions',
                subtitle: 'What admins and members did',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RecentActionsScreen(chat: chat))),
              ),
              if (chat.isChannel)
                SettingsTile(
                  icon: Icons.pending_actions_rounded,
                  color: Brand.amber,
                  title: 'Drafts & approvals',
                  trailingWidget: chat.queueCount > 0 ? CountBadge(chat.queueCount) : null,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PostQueueScreen(chat: chat))),
                ),
              if (chat.can('change_info')) ...[
                if (chat.isGroup)
                  SettingsTile(
                    icon: Icons.waving_hand_rounded,
                    color: Brand.amber,
                    title: 'Welcome message',
                    subtitle: chat.welcomeText.isEmpty ? 'Greet new members automatically' : chat.welcomeText,
                    maxSubtitleLines: 1,
                    onTap: () => editChatText(context, chat, field: 'welcome_text', title: 'Welcome message', hint: 'Glad to have you! Please read the rules.', max: 500, current: chat.welcomeText),
                  ),
                if (chat.isGroup)
                  SettingsSwitchTile(
                    icon: Icons.shield_rounded,
                    color: Brand.green,
                    title: 'Limit new members',
                    subtitle: 'No links, photos or files in their first 24 hours',
                    value: chat.newMemberLimits,
                    onChanged: (v) => _run(() => _store.updateChat(chat.id, {'new_member_limits': v})),
                  ),
                SettingsSwitchTile(
                  icon: Icons.no_encryption_gmailerrorred_rounded,
                  color: Brand.rose,
                  title: 'Protect content',
                  subtitle: 'Members can’t forward or copy messages',
                  value: chat.protectedContent,
                  onChanged: (v) => _run(() => _store.updateChat(chat.id, {'protected_content': v})),
                ),
                SettingsTile(
                  icon: Icons.add_reaction_rounded,
                  color: Brand.primary,
                  title: 'Reactions',
                  trailing: chat.allowedReactions == null ? 'All' : (chat.allowedReactions!.isEmpty ? 'Off' : chat.allowedReactions!.join(' ')),
                  onTap: () => editAllowedReactions(context, chat),
                ),
                if (chat.isChannel)
                  SettingsTile(
                    icon: Icons.forum_rounded,
                    color: Brand.green,
                    title: 'Discussion group',
                    trailing: chat.linkedChat?.title ?? 'Off',
                    onTap: () => pickDiscussionGroup(context, chat),
                  ),
                if (chat.isChannel && chat.username != null)
                  SettingsTile(
                    icon: Icons.category_rounded,
                    color: Brand.sky,
                    title: 'Category',
                    subtitle: 'Where it shows in Explore channels',
                    trailing: chat.category == null ? 'None' : (channelCategories[chat.category]?.$2 ?? chat.category!),
                    onTap: () => pickChannelCategory(context, chat),
                  ),
              ],
              if (chat.isChannel && chat.can('change_info'))
                SettingsSwitchTile(
                  icon: Icons.draw_rounded,
                  color: Brand.amber,
                  title: 'Sign messages',
                  subtitle: 'Show the admin’s name on posts',
                  value: chat.signatures,
                  onChanged: (v) => _run(() => _store.setSignatures(chat.id, v)),
                ),
              if (chat.isChannel && auth.feature('channel_comments') && chat.can('change_info'))
                SettingsSwitchTile(
                  icon: Icons.forum_rounded,
                  color: Brand.sky,
                  title: 'Comments',
                  subtitle: 'Subscribers can comment under posts',
                  value: chat.commentsEnabled,
                  onChanged: (v) => _run(() => _store.patchChat(chat.id, {'comments_enabled': v})),
                ),
              if (chat.isGroup && auth.feature('topics') && chat.can('change_info'))
                SettingsSwitchTile(
                  icon: Icons.topic_rounded,
                  color: Brand.violet,
                  title: 'Topics',
                  subtitle: 'Split the group into topics like “Help” and “Off-topic”',
                  value: chat.isForum,
                  onChanged: (v) => _run(() => _store.patchChat(chat.id, {'is_forum': v})),
                ),
              if (chat.isGroup) ...[
                if (chat.can('change_info'))
                  SettingsTile(icon: Icons.timer_rounded, color: const Color(0xFF5E6B8C), title: 'Slow mode', trailing: _slowLabel(chat.slowModeSec), onTap: () => _pickSlowMode(chat)),
                if (chat.can('change_info'))
                  SettingsSwitchTile(
                  icon: Icons.how_to_reg_rounded,
                  color: Brand.green,
                  title: 'Approve new members',
                  subtitle: 'People with an invite must be approved by an admin',
                  value: chat.joinApproval,
                  onChanged: (v) => _run(() => _store.patchChat(chat.id, {'join_approval': v})),
                ),
                if ((chat.joinApproval || chat.pendingRequests > 0) && chat.can('invite_users'))
                  SettingsTile(
                    icon: Icons.person_search_rounded,
                    color: Brand.primary,
                    title: 'Join requests',
                    trailingWidget: chat.pendingRequests > 0 ? CountBadge(chat.pendingRequests) : null,
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => JoinRequestsScreen(chat: chat))),
                  ),
              ],
              if (chat.inviteCode != null && chat.can('invite_users')) ...[
                SettingsTile(
                  icon: Icons.link_rounded,
                  color: Brand.sky,
                  title: 'Invite code',
                  subtitle: chat.inviteCode!,
                  trailingWidget: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (v) async {
                      if (v == 'copy') {
                        await Clipboard.setData(ClipboardData(text: chat.inviteCode!));
                        if (context.mounted) showInfo(context, 'Invite code copied');
                      } else {
                        await _run(() => _store.regenerateInvite(chat.id), 'New invite code created — the old one no longer works');
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'copy', child: Text('Copy')),
                      PopupMenuItem(value: 'reset', child: Text('Reset code')),
                    ],
                  ),
                ),
                SettingsTile(
                  icon: Icons.add_link_rounded,
                  color: Brand.rose,
                  title: 'Invite links',
                  subtitle: 'Links with expiry date or a member limit',
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InviteLinksScreen(chat: chat))),
                ),
              ],
            ]),
          SettingsGroup(
            title: chat.isChannel && !chat.isAdmin ? 'Admins' : '${members.length} ${chat.isChannel ? 'shown' : 'members'}',
            children: [
              if (chat.can('invite_users') && !chat.isSuspended)
                SettingsTile(
                  icon: Icons.person_add_rounded,
                  color: Brand.primary,
                  title: chat.isChannel ? 'Add subscribers' : 'Add members',
                  onTap: () => _addMembers(chat),
                ),
              ...members.map((m) => InkWell(
                    onTap: () => _memberActions(chat, m),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      child: Row(children: [
                        Stack(clipBehavior: Clip.none, children: [
                          Avatar(id: m.user.id, name: m.user.name, url: m.user.avatarAbsolute, size: 42),
                          if (m.user.online)
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: Container(
                                width: 13,
                                height: 13,
                                decoration: BoxDecoration(color: Brand.accent, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2)),
                              ),
                            ),
                        ]),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(m.user.id == store.myId ? '${m.user.name} (you)' : m.user.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                            Text(lastSeenText(m.user),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12.5, color: m.user.online ? Brand.accent : Theme.of(context).colorScheme.onSurfaceVariant)),
                          ]),
                        ),
                        if (m.isRestricted)
                          const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.volume_off_rounded, size: 18, color: Brand.amber)),
                        if (m.role != 'member')
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(
                              color: (m.role == 'owner' ? Brand.premium : Brand.primary).withValues(alpha: dark ? 0.22 : 0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(m.title?.isNotEmpty == true ? m.title! : (m.role == 'owner' ? 'Owner' : 'Admin'),
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: m.role == 'owner' ? Brand.premium : Brand.primary)),
                          ),
                      ]),
                    ),
                  )),
            ],
          ),
          SettingsGroup(children: [
            SettingsTile(icon: Icons.flag_rounded, color: Brand.amber, title: 'Report $what', onTap: () => showReportDialog(context, targetType: 'chat', targetId: chat.id)),
            SettingsTile(
              icon: Icons.exit_to_app_rounded,
              color: const Color(0xFFE5484D),
              title: 'Leave $what',
              danger: true,
              onTap: () async {
                if (!await confirm(context, 'Leave $what?', 'You will stop receiving messages from “${chat.title}”.', ok: 'Leave', danger: true)) return;
                try {
                  await _store.leaveOrDelete(chat.id);
                  if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
            ),
          ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
