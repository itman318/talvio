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
import '../theme/brand.dart';

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
    final canRemove = chat.isOwner || (chat.myRole == 'admin' && m.role == 'member');
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.person), title: const Text('View profile'), onTap: () => Navigator.pop(ctx, 'profile')),
          if (chat.isOwner && m.role == 'member')
            ListTile(leading: const Icon(Icons.admin_panel_settings), title: const Text('Make admin'), onTap: () => Navigator.pop(ctx, 'admin')),
          if (chat.isOwner && m.role == 'admin')
            ListTile(leading: const Icon(Icons.remove_moderator), title: const Text('Remove admin rights'), onTap: () => Navigator.pop(ctx, 'member')),
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
      case 'member':
        await _run(() => _store.setRole(chat.id, m.user.id, a));
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

  Widget _headerAction(IconData icon, String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: SizedBox(
              width: 66,
              height: 62,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, color: Brand.primary, size: 22),
                const SizedBox(height: 4),
                Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final chat = store.chatById(widget.chatId);
    if (chat == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('You are no longer a member here')));
    }
    final members = store.members[chat.id] ?? [];
    final what = chat.isChannel ? 'channel' : 'group';
    return Scaffold(
      appBar: AppBar(
        title: Text(chat.isChannel ? 'Channel info' : 'Group info'),
        actions: [
          if (chat.isAdmin) IconButton(icon: const Icon(Icons.edit), onPressed: () => _editText(chat, title: true)),
        ],
      ),
      body: ListView(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(26), gradient: Brand.auroraSoft(Theme.of(context).brightness == Brightness.dark)),
            child: Column(children: [
              GestureDetector(
                onTap: chat.isAdmin ? () => _changePhoto(chat) : null,
                child: Stack(clipBehavior: Clip.none, children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, shape: BoxShape.circle),
                      child: ClipOval(child: Avatar(id: chat.id, name: chat.title, url: chat.avatarAbsolute, size: 96)),
                    ),
                  ),
                  if (chat.isAdmin)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                        child: const Icon(Icons.photo_camera_rounded, size: 16, color: Colors.white),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 12),
              Text(chat.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
              const SizedBox(height: 2),
              Text('${chat.memberCount} ${chat.isChannel ? 'subscribers' : 'members'}${chat.username != null ? ' · public' : ''}',
                  textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _headerAction(chat.isMuted ? Icons.notifications_off_rounded : Icons.notifications_rounded, chat.isMuted ? 'Unmute' : 'Mute',
                    () => _run(() => _store.updateChatSettings(chat.id, {'muted_until': chat.isMuted ? null : 'forever'}))),
                _headerAction(Icons.perm_media_rounded, 'Media', () => Navigator.push(context, MaterialPageRoute(builder: (_) => SharedMediaScreen(chat: chat)))),
                if (chat.isAdmin && chat.isGroup) _headerAction(Icons.person_add_alt_1_rounded, 'Add', () => _addMembers(chat)),
                if (chat.isAdmin) _headerAction(Icons.edit_rounded, 'Edit', () => _editText(chat, title: true)),
              ]),
            ]),
          ),
          if (chat.isSuspended)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('Suspended by moderators', textAlign: TextAlign.center, style: TextStyle(color: Colors.red)),
            ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(chat.description.isEmpty ? (chat.isAdmin ? 'Add a description' : 'No description') : chat.description),
            onTap: chat.isAdmin ? () => _editText(chat, title: false) : null,
          ),
          if (chat.username != null || chat.isOwner)
            ListTile(
              leading: const Icon(Icons.alternate_email),
              title: Text(chat.username != null ? '@${chat.username}' : 'Make this $what public'),
              subtitle: Text(chat.username != null ? 'Public link — anyone can find and join' : 'Private — joins only with an invite code'),
              trailing: chat.username != null
                  ? IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: '@${chat.username}'));
                        if (context.mounted) showInfo(context, 'Copied');
                      },
                    )
                  : null,
              onTap: chat.isOwner ? () => _editUsername(chat) : null,
            ),
          if (chat.isChannel && chat.isAdmin)
            SwitchListTile(
              secondary: const Icon(Icons.draw_outlined),
              title: const Text('Sign messages'),
              subtitle: const Text('Show the admin’s name on posts'),
              value: chat.signatures,
              onChanged: (v) => _run(() => _store.setSignatures(chat.id, v)),
            ),
          if (chat.isAdmin)
            ListTile(
              leading: const Icon(Icons.insights),
              title: const Text('Statistics'),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatStatsScreen(chat: chat))),
            ),
          if (chat.isChannel && chat.isAdmin && context.read<AuthState>().feature('channel_comments'))
            SwitchListTile(
              secondary: const Icon(Icons.forum_outlined),
              title: const Text('Comments'),
              subtitle: const Text('Subscribers can comment under posts'),
              value: chat.commentsEnabled,
              onChanged: (v) => _run(() => _store.patchChat(chat.id, {'comments_enabled': v})),
            ),
          if (chat.isGroup && chat.isAdmin && context.read<AuthState>().feature('topics'))
            SwitchListTile(
              secondary: const Icon(Icons.topic_outlined),
              title: const Text('Topics'),
              subtitle: const Text('Split the group into topics like “Help” and “Off-topic”'),
              value: chat.isForum,
              onChanged: (v) => _run(() => _store.patchChat(chat.id, {'is_forum': v})),
            ),
          if (chat.isGroup && chat.isAdmin) ...[
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Slow mode'),
              trailing: Text(_slowLabel(chat.slowModeSec)),
              onTap: () => _pickSlowMode(chat),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.how_to_reg_outlined),
              title: const Text('Approve new members'),
              subtitle: const Text('People with an invite must be approved by an admin'),
              value: chat.joinApproval,
              onChanged: (v) => _run(() => _store.patchChat(chat.id, {'join_approval': v})),
            ),
            if (chat.joinApproval || chat.pendingRequests > 0)
              ListTile(
                leading: const Icon(Icons.person_search_outlined),
                title: const Text('Join requests'),
                trailing: chat.pendingRequests > 0
                    ? CircleAvatar(radius: 12, backgroundColor: Brand.primary, child: Text('${chat.pendingRequests}', style: const TextStyle(fontSize: 12, color: Colors.white)))
                    : null,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => JoinRequestsScreen(chat: chat))),
              ),
          ],
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('Notifications'),
            value: !chat.isMuted,
            onChanged: (on) => _run(() => _store.updateChatSettings(chat.id, {'muted_until': on ? null : 'forever'})),
          ),
          if (chat.isAdmin && chat.inviteCode != null)
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Invite code'),
              subtitle: Text(chat.inviteCode!),
              trailing: PopupMenuButton<String>(
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
          if (chat.isAdmin && chat.inviteCode != null)
            ListTile(
              leading: const Icon(Icons.add_link),
              title: const Text('Invite links'),
              subtitle: const Text('Links with expiry date or a member limit'),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InviteLinksScreen(chat: chat))),
            ),
          const Divider(),
          if (chat.isAdmin && !chat.isSuspended)
            ListTile(
              leading: const Icon(Icons.person_add, color: Brand.primary),
              title: Text(chat.isChannel ? 'Add subscribers' : 'Add members', style: const TextStyle(color: Brand.primary)),
              onTap: () => _addMembers(chat),
            ),
          if (chat.isChannel && !chat.isAdmin)
            const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text('Admins', style: TextStyle(fontWeight: FontWeight.w600))),
          ...members.map((m) => ListTile(
                leading: Avatar(id: m.user.id, name: m.user.name, url: m.user.avatarAbsolute, size: 42),
                title: Text(m.user.id == store.myId ? '${m.user.name} (you)' : m.user.name),
                subtitle: Text(lastSeenText(m.user)),
                trailing: m.role == 'member'
                    ? null
                    : Text(m.role == 'owner' ? 'owner' : 'admin', style: const TextStyle(color: Brand.primary)),
                onTap: () => _memberActions(chat, m),
              )),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: Text('Report $what'),
            onTap: () => showReportDialog(context, targetType: 'chat', targetId: chat.id),
          ),
          ListTile(
            leading: const Icon(Icons.exit_to_app, color: Colors.red),
            title: Text('Leave $what', style: const TextStyle(color: Colors.red)),
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
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
