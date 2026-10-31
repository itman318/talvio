import 'global_search_screen.dart' show SimilarChannels;
import 'package:flutter/material.dart';
import '../core/chat_links.dart';
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
        title: Text(title ? (chat.isChannel ? 'Channel name' : 'Group name') : 'Description'),
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
    // the owner manages every admin; an admin with "Add new admins" only the ones they added
    final canPromote = chat.isOwner || (chat.can('add_admins') && (m.role == 'member' || (m.role == 'admin' && m.promotedBy == _store.myId)));
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.person), title: const Text('View profile'), onTap: () => Navigator.pop(ctx, 'profile')),
          if (chat.isGroup && m.role == 'member' && chat.can('ban_users'))
            ListTile(leading: const Icon(Icons.sell_rounded), title: Text(m.tag == null ? 'Add a member tag' : 'Edit tag “${m.tag}”'), onTap: () => Navigator.pop(ctx, 'tag')),
          if (canPromote && m.role == 'member')
            ListTile(leading: const Icon(Icons.admin_panel_settings), title: const Text('Make admin or moderator'), onTap: () => Navigator.pop(ctx, 'admin')),
          if (canPromote && m.role == 'admin')
            ListTile(leading: const Icon(Icons.tune_rounded), title: const Text('Edit admin rights'), onTap: () => Navigator.pop(ctx, 'admin')),
          if (canPromote && m.role == 'admin')
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
        final r = await editAdminRights(context,
            name: m.user.name,
            channel: chat.isChannel,
            current: m.role == 'admin' ? m.rights : null,
            title: m.title,
            allowed: chat.isOwner ? null : {for (final k in adminRightLabels.keys) k: chat.can(k)});
        if (r == null) return;
        await _run(() => _store.setRole(chat.id, m.user.id, 'admin', rights: r.$1, title: r.$2), '${m.user.name} is an admin');
        break;
      case 'member':
        await _run(() => _store.setRole(chat.id, m.user.id, 'member'));
        break;
      case 'tag':
        final c = TextEditingController(text: m.tag ?? '');
        final tag = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Tag for ${m.user.name}'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: c, autofocus: true, maxLength: 16, decoration: const InputDecoration(hintText: 'Mentor, VIP, Trader…')),
              const Text('Shown next to their name in the group.', style: TextStyle(fontSize: 12.5, color: Brand.muted)),
            ]),
            actions: [
              if (m.tag != null) TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Remove')),
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
            ],
          ),
        );
        if (tag == null) return;
        await _run(() => _store.setMemberTag(chat.id, m.user.id, tag.isEmpty ? null : tag), tag.isEmpty ? 'Tag removed' : 'Tag saved');
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

  // ------------------------------------------------------------------ admin: compact card + Manage screen
  Widget _adminCard(Chat chat) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final what = chat.isChannel ? 'channel' : 'group';
    final waiting = chat.isChannel ? chat.queueCount : chat.pendingRequests;
    Widget tile(IconData icon, Color c, String label, VoidCallback onTap, {int badge = 0}) => Expanded(
          child: Material(
            color: c.withValues(alpha: dark ? 0.16 : 0.09),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: SizedBox(
                height: 70,
                child: Stack(children: [
                  Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(icon, color: c, size: 23),
                      const SizedBox(height: 5),
                      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c)),
                    ]),
                  ),
                  if (badge > 0) Positioned(top: 6, right: 8, child: CountBadge(badge)),
                ]),
              ),
            ),
          ),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF181C30) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Brand.primary.withValues(alpha: 0.18)),
      ),
      child: Column(children: [
        Row(children: [
          const Icon(Icons.shield_moon_rounded, color: Brand.primary, size: 18),
          const SizedBox(width: 8),
          Text(chat.isOwner ? 'You own this $what' : 'You are an admin', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          tile(Icons.insights_rounded, Brand.green, 'Stats', () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatStatsScreen(chat: chat)))),

          const SizedBox(width: 8),
          tile(Icons.history_rounded, Brand.sky, 'Activity', () => Navigator.push(context, MaterialPageRoute(builder: (_) => RecentActionsScreen(chat: chat)))),
          const SizedBox(width: 8),
          tile(Icons.tune_rounded, Brand.violet, 'Manage', () => _openManage(chat), badge: waiting),
        ]),
      ]),
    );
  }

  void _openManage(Chat chat) {
    final what = chat.isChannel ? 'channel' : 'group';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Consumer<ChatStore>(builder: (ctx, store, _) {
          final c = store.chatById(chat.id);
          if (c == null || !c.isAdmin) return Scaffold(appBar: AppBar(), body: const Center(child: Text('You are no longer an admin here')));
          return Scaffold(
            appBar: AppBar(title: Text('Manage $what')),
            body: ListView(padding: const EdgeInsets.only(bottom: 28), children: _manageGroups(c)),
          );
        }),
      ),
    );
  }

  Future<void> _addAdmin(Chat chat) async {
    final members = (_store.members[chat.id] ?? []).where((m) => m.role == 'member' && m.user.id != _store.myId && !m.user.deleted).toList();
    if (members.isEmpty) {
      showInfo(context, chat.isChannel ? 'Add subscribers first, then make one an admin' : 'Add members first, then make one an admin');
      return;
    }
    final pick = await showModalBottomSheet<GroupMember>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Choose a new admin', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            for (final m in members)
              ListTile(
                leading: Avatar(id: m.user.id, name: m.user.name, url: m.user.avatarAbsolute, size: 42),
                title: Text(m.user.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(lastSeenText(m.user), maxLines: 1),
                onTap: () => Navigator.pop(ctx, m),
              ),
          ]),
        ),
      ),
    );
    if (pick == null || !mounted) return;
    final r = await editAdminRights(context,
        name: pick.user.name, channel: chat.isChannel, allowed: chat.isOwner ? null : {for (final k in adminRightLabels.keys) k: chat.can(k)});
    if (r == null) return;
    await _run(() => _store.setRole(chat.id, pick.user.id, 'admin', rights: r.$1, title: r.$2), '${pick.user.name} is now ${r.$2.isEmpty ? 'an admin' : r.$2}');
  }

  List<Widget> _manageGroups(Chat chat) {
    final auth = context.read<AuthState>();
    final info = chat.can('change_info');
    final admins = (_store.members[chat.id] ?? []).where((m) => m.role != 'member').toList();
    final canAdd = chat.isOwner || chat.can('add_admins');
    String rightsLine(GroupMember m) {
      if (m.role == 'owner') return 'Owner · can do everything';
      final r = m.rights;
      if (r == null) return 'All rights';
      final on = adminRightLabels.keys.where((k) => r[k] != false && (chat.isChannel || k != 'post_messages')).length;
      final total = adminRightLabels.keys.where((k) => chat.isChannel || k != 'post_messages').length;
      return on >= total ? 'All rights' : '$on of $total rights';
    }

    final dark = Theme.of(context).brightness == Brightness.dark;
    final invite = chat.inviteCode != null && chat.can('invite_users') ? inviteChatLink(chat.inviteCode!) : null;
    final shareLink = chat.username != null ? publicChatLink(chat.username!) : invite;
    return [
      // who it is: photo, name and description, each one tap to change
      Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 6),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(24)),
        child: Column(children: [
          GestureDetector(
            onTap: info ? () => _changePhoto(chat) : null,
            child: Stack(clipBehavior: Clip.none, children: [
              Avatar(id: chat.id, name: chat.title, url: chat.avatarAbsolute, size: 88),
              if (info)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.surface, width: 3)),
                    child: const Icon(Icons.photo_camera_rounded, size: 15, color: Colors.white),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: info ? () => _editText(chat, title: true) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: Text(chat.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                if (info) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.edit_rounded, size: 16, color: Brand.muted)),
              ]),
            ),
          ),
          const SizedBox(height: 6),
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: info ? () => _editText(chat, title: false) : null,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: dark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF4F5FA), borderRadius: BorderRadius.circular(14)),
              child: Text(
                chat.description.isEmpty ? (info ? 'Add a description — tell people what this ${chat.isChannel ? 'channel' : 'group'} is about' : 'No description') : chat.description,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: chat.description.isEmpty ? Brand.muted : null, height: 1.4),
              ),
            ),
          ),
        ]),
      ),
      if (shareLink != null)
        Container(
          margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(22)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(chat.username != null ? 'PUBLIC LINK' : 'INVITE LINK', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Brand.muted)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(color: Brand.primary.withValues(alpha: dark ? 0.16 : 0.07), borderRadius: BorderRadius.circular(12)),
              child: Text(shareLink.replaceFirst(RegExp(r'^https?://'), ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.primary)),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: shareLink));
                    if (mounted) showInfo(context, 'Link copied');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy'),
                ),
              ),
              if (chat.username == null && invite != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _run(() => _store.regenerateInvite(chat.id), 'New link made — the old one stopped working'),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('New'),
                  ),
                ),
              ],
              if (chat.can('invite_users')) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InviteLinksScreen(chat: chat))),
                    icon: const Icon(Icons.add_link_rounded, size: 18),
                    label: const Text('More'),
                  ),
                ),
              ],
            ]),
          ]),
        ),
      SettingsGroup(title: 'Admins & moderators', children: [
        for (final m in admins)
          ListTile(
            leading: Avatar(id: m.user.id, name: m.user.name, url: m.user.avatarAbsolute, size: 40),
            title: Text(m.user.id == _store.myId ? '${m.user.name} (you)' : m.user.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(rightsLine(m), maxLines: 1),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(color: (m.role == 'owner' ? Brand.premium : Brand.primary).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text(m.title?.isNotEmpty == true ? m.title! : (m.role == 'owner' ? 'Owner' : 'Admin'),
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: m.role == 'owner' ? Brand.premium : Brand.primary)),
            ),
            onTap: () => _memberActions(chat, m),
          ),
        if (canAdd)
          SettingsTile(
            icon: Icons.person_add_alt_1_rounded,
            color: Brand.green,
            title: 'Add admin or moderator',
            subtitle: 'Choose exactly what they may do',
            onTap: () => _addAdmin(chat),
          ),
      ]),
      if (info)
        SettingsGroup(title: chat.isChannel ? 'Channel' : 'Group', children: [
          if (chat.isOwner)
            SettingsTile(
              icon: Icons.alternate_email_rounded,
              color: Brand.sky,
              title: chat.username != null ? 'Public link' : 'Type',
              trailing: chat.username != null ? '@${chat.username}' : 'Private',
              onTap: () => _editUsername(chat),
            ),
          SettingsTile(
            icon: Icons.gavel_rounded,
            color: Brand.violet,
            title: 'Rules',
            subtitle: chat.rules.isEmpty ? 'Rules new members see first' : chat.rules,
            maxSubtitleLines: 1,
            onTap: () => editChatText(context, chat, field: 'rules', title: 'Rules', hint: '1. Be kind\n2. No spam', max: 2000, current: chat.rules),
          ),
          if (chat.isGroup)
            SettingsTile(
              icon: Icons.waving_hand_rounded,
              color: Brand.amber,
              title: 'Welcome message',
              subtitle: chat.welcomeText.isEmpty ? 'Greet new members automatically' : chat.welcomeText,
              maxSubtitleLines: 1,
              onTap: () => editChatText(context, chat, field: 'welcome_text', title: 'Welcome message', hint: 'Glad to have you! Please read the rules.', max: 500, current: chat.welcomeText),
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
        ]),
      if (chat.isChannel && info)
        SettingsGroup(title: 'Posts', children: [
          SettingsSwitchTile(
            icon: Icons.draw_rounded,
            color: Brand.amber,
            title: 'Sign messages',
            subtitle: 'Show the admin’s name on posts',
            value: chat.signatures,
            onChanged: (v) => _run(() => _store.setSignatures(chat.id, v)),
          ),
          if (auth.feature('channel_comments'))
            SettingsSwitchTile(
              icon: Icons.mode_comment_rounded,
              color: Brand.sky,
              title: 'Comments',
              subtitle: 'Subscribers can comment under posts',
              value: chat.commentsEnabled,
              onChanged: (v) => _run(() => _store.patchChat(chat.id, {'comments_enabled': v})),
            ),
          SettingsTile(
            icon: Icons.forum_rounded,
            color: Brand.green,
            title: 'Discussion group',
            trailing: chat.linkedChat?.title ?? 'Off',
            onTap: () => pickDiscussionGroup(context, chat),
          ),
          SettingsTile(
            icon: Icons.pending_actions_rounded,
            color: Brand.amber,
            title: 'Drafts & approvals',
            trailingWidget: chat.queueCount > 0 ? CountBadge(chat.queueCount) : null,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PostQueueScreen(chat: chat))),
          ),
        ]),
      if (chat.isGroup)
        SettingsGroup(title: 'Members', children: [
          if (info)
            SettingsTile(
              icon: Icons.tune_rounded,
              color: Brand.violet,
              title: 'Member permissions',
              subtitle: () {
                final off = chat.memberPerms.entries.where((e) => !e.value).length;
                return off == 0 ? 'Members can send everything' : '$off kind${off == 1 ? '' : 's'} of messages turned off';
              }(),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MemberPermissionsScreen(chatId: chat.id))),
            ),
          if (info) SettingsTile(icon: Icons.timer_rounded, color: const Color(0xFF5E6B8C), title: 'Slow mode', trailing: _slowLabel(chat.slowModeSec), onTap: () => _pickSlowMode(chat)),
          if (info && auth.feature('topics'))
            SettingsSwitchTile(
              icon: Icons.topic_rounded,
              color: Brand.violet,
              title: 'Topics',
              subtitle: 'Split the group into topics like “Help” and “Off-topic”',
              value: chat.isForum,
              onChanged: (v) => _run(() => _store.patchChat(chat.id, {'is_forum': v})),
            ),
          if (info)
            SettingsSwitchTile(
              icon: Icons.how_to_reg_rounded,
              color: Brand.green,
              title: 'Approve new members',
              subtitle: 'People with an invite must be approved by an admin',
              value: chat.joinApproval,
              onChanged: (v) => _run(() => _store.patchChat(chat.id, {'join_approval': v})),
            ),
          if (chat.can('invite_users'))
            SettingsTile(
              icon: Icons.person_search_rounded,
              color: Brand.primary,
              title: 'Join requests',
              trailingWidget: chat.pendingRequests > 0 ? CountBadge(chat.pendingRequests) : null,
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => JoinRequestsScreen(chat: chat))),
            ),
        ]),
      if (info)
        SettingsGroup(title: 'Safety', children: [
          if (chat.isGroup)
            SettingsTile(
              icon: Icons.security_rounded,
              color: const Color(0xFF12A150),
              title: 'Group protection',
              subtitle: () {
                final on = [
                  if (chat.joinCaptcha) 'Human check',
                  if (chat.antiFlood) 'Anti-flood',
                  if (chat.antiLinks) 'No links',
                  if (chat.bannedWords.isNotEmpty) '${chat.bannedWords.length} blocked words',
                ];
                return on.isEmpty ? 'Human check, spam filter, blocked words' : on.join(' · ');
              }(),
              maxSubtitleLines: 1,
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GroupProtectionScreen(chatId: chat.id))),
            ),
          SettingsSwitchTile(
            icon: Icons.no_encryption_gmailerrorred_rounded,
            color: Brand.rose,
            title: 'Protect content',
            subtitle: chat.isChannel ? 'Subscribers can’t forward or copy posts' : 'Members can’t forward or copy messages',
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
        ]),
    ];
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white, // over the cover banner
        systemOverlayStyle: SystemUiOverlayStyle.light,
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
                  final link = chatLinkOf(chat);
                  if (link == null) {
                    showInfo(context, 'Only admins can share the invite link');
                    return;
                  }
                  await Clipboard.setData(ClipboardData(text: link));
                  if (context.mounted) showInfo(context, 'Link copied — paste it anywhere to invite people');
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
                title: chat.username != null ? publicChatLink(chat.username!) : 'Make this $what public',
                subtitle: chat.username != null ? 'Public link · @${chat.username} — anyone can find and join' : 'Private — joins only with an invite link',
                maxSubtitleLines: 2,
                trailingWidget: chat.username != null
                    ? IconButton(
                        tooltip: 'Copy link',
                        icon: const Icon(Icons.copy_rounded, size: 20),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: publicChatLink(chat.username!)));
                          if (context.mounted) showInfo(context, 'Link copied');
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
          ]),
          if (chat.isAdmin) _adminCard(chat),
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
                        if (m.role == 'member' && m.tag != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(color: colorForId(m.user.id).withValues(alpha: dark ? 0.22 : 0.12), borderRadius: BorderRadius.circular(20)),
                            child: Text(m.tag!, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: colorForId(m.user.id))),
                          ),
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
          if (chat.isChannel && chat.isPublic) SimilarChannels(chatId: chat.id),
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
