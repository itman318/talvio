import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/report_dialog.dart';
import 'channel_screens.dart';
import 'new_chat_screen.dart';
import 'user_profile_screen.dart';

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
          const Text('Leave empty to make it private.', style: TextStyle(fontSize: 12, color: Colors.black54)),
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
    return Scaffold(
      appBar: AppBar(
        title: Text(chat.isChannel ? 'Channel info' : 'Group info'),
        actions: [
          if (chat.isAdmin) IconButton(icon: const Icon(Icons.edit), onPressed: () => _editText(chat, title: true)),
        ],
      ),
      body: ListView(
        children: [
          const SizedBox(height: 16),
          Center(
            child: GestureDetector(
              onTap: chat.isAdmin ? () => _changePhoto(chat) : null,
              child: Avatar(id: chat.id, name: chat.title, url: chat.avatarAbsolute, size: 96),
            ),
          ),
          const SizedBox(height: 12),
          Text(chat.title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          Text('${chat.memberCount} ${chat.isChannel ? 'subscribers' : 'members'}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
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
          const Divider(),
          if (chat.isAdmin && !chat.isSuspended)
            ListTile(
              leading: const Icon(Icons.person_add, color: Color(0xFF2AABEE)),
              title: Text(chat.isChannel ? 'Add subscribers' : 'Add members', style: const TextStyle(color: Color(0xFF2AABEE))),
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
                    : Text(m.role == 'owner' ? 'owner' : 'admin', style: const TextStyle(color: Color(0xFF2AABEE))),
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
