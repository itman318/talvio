import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/report_dialog.dart';
import 'chat_screen.dart';

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
      if (mounted) setState(() => _error = '$e');
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

  @override
  Widget build(BuildContext context) {
    final u = _user;
    final myId = context.read<ChatStore>().myId;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: u == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : ListView(
              children: [
                const SizedBox(height: 20),
                Center(child: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute, size: 104)),
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Flexible(child: Text(u.name, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center)),
                  if (u.isVerified) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.verified, color: Color(0xFF2AABEE))),
                ]),
                Text(lastSeenText(u), textAlign: TextAlign.center, style: TextStyle(color: u.online ? const Color(0xFF2AABEE) : Colors.black54)),
                const SizedBox(height: 16),
                if (!u.deleted && u.id != myId)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: FilledButton.icon(
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Message'),
                      onPressed: () async {
                        try {
                          final chat = await context.read<ChatStore>().openPrivateWith(u.id);
                          if (context.mounted) {
                            Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
                          }
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                    ),
                  ),
                const Divider(height: 32),
                if (u.phone != null)
                  ListTile(
                    leading: const Icon(Icons.phone),
                    title: Text(u.phone!),
                    subtitle: const Text('Mobile'),
                    onLongPress: () => Clipboard.setData(ClipboardData(text: u.phone!)),
                  ),
                if (u.username != null)
                  ListTile(
                    leading: const Icon(Icons.alternate_email),
                    title: Text('@${u.username}'),
                    subtitle: const Text('Username'),
                    onLongPress: () => Clipboard.setData(ClipboardData(text: '@${u.username}')),
                  ),
                if (u.bio.isNotEmpty) ListTile(leading: const Icon(Icons.info_outline), title: Text(u.bio), subtitle: const Text('Bio')),
                if (!u.deleted && u.id != myId) ...[
                  const Divider(),
                  ListTile(
                    leading: Icon(u.isContact ? Icons.person_remove : Icons.person_add),
                    title: Text(u.isContact ? 'Remove from contacts' : 'Add to contacts'),
                    onTap: () => _toggle('/contacts/${u.id}', !u.isContact),
                  ),
                  ListTile(
                    leading: Icon(Icons.block, color: u.blocked ? null : Colors.red),
                    title: Text(u.blocked ? 'Unblock user' : 'Block user', style: TextStyle(color: u.blocked ? null : Colors.red)),
                    onTap: () async {
                      if (!u.blocked &&
                          !await confirm(context, 'Block ${u.name}?', 'They won’t be able to message you.', ok: 'Block', danger: true)) {
                        return;
                      }
                      await _toggle('/blocks/${u.id}', !u.blocked);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.flag_outlined),
                    title: const Text('Report user'),
                    onTap: () => showReportDialog(context, targetType: 'user', targetId: u.id),
                  ),
                ],
              ],
            ),
    );
  }
}
