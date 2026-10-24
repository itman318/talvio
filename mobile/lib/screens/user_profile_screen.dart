import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/report_dialog.dart';
import 'calls_screen.dart';
import 'secret_screens.dart';
import 'chat_screen.dart';
import '../theme/brand.dart';
import '../widgets/premium.dart';
import 'shared_media_screen.dart';

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

  @override
  Widget build(BuildContext context) {
    final u = _user;
    final store = context.watch<ChatStore>();
    final myId = store.myId;
    final auth = context.read<AuthState>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final chat = u == null ? null : store.chats.where((c) => c.peer?.id == u.id).firstOrNull;
    final other = u != null && !u.deleted && u.id != myId;
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent),
      extendBodyBehindAppBar: true,
      body: u == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.zero,
              children: [
                // header
                Container(
                  padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 56, 16, 22),
                  decoration: BoxDecoration(gradient: Brand.auroraSoft(dark)),
                  child: Column(children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(gradient: u.online ? null : Brand.aurora, color: u.online ? Brand.accent : null, shape: BoxShape.circle),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, shape: BoxShape.circle),
                        child: ClipOval(child: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute, size: 104)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Flexible(
                        child: Text(u.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                      ),
                      if (u.isVerified) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.verified_rounded, color: Brand.sky, size: 22)),
                      if (u.isPremium) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.workspace_premium_rounded, color: Brand.premium, size: 22)),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                      u.isBot ? 'bot' : lastSeenText(u),
                      style: TextStyle(color: u.online ? Brand.accent : Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                    ),
                    if (other) ...[
                      const SizedBox(height: 18),
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        _action(Icons.chat_bubble_rounded, 'Message', () => _message(u)),
                        if (auth.feature('calls')) _action(Icons.call_rounded, 'Call', () => startCall(context, u, video: false)),
                        if (auth.feature('calls') && auth.feature('video_calls')) _action(Icons.videocam_rounded, 'Video', () => startCall(context, u, video: true)),
                        if (chat != null)
                          _action(chat.isMuted ? Icons.notifications_off_rounded : Icons.notifications_rounded, chat.isMuted ? 'Unmute' : 'Mute', () async {
                            try {
                              await store.updateChatSettings(chat.id, {'muted_until': chat.isMuted ? null : 'forever'});
                            } catch (e) {
                              if (mounted) showError(this.context, e);
                            }
                          }),
                        if (auth.feature('secret_chats')) _action(Icons.lock_rounded, 'Vault', () => startSecretChat(context, u)),
                      ]),
                    ],
                  ]),
                ),
                SettingsGroup(title: 'Info', children: [
                  if (u.phone != null)
                    SettingsTile(
                      icon: Icons.phone_rounded,
                      color: Brand.green,
                      title: u.phone!,
                      subtitle: 'Mobile · hold to copy',
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
                  if (u.bio.isNotEmpty) SettingsTile(icon: Icons.info_rounded, color: Brand.violet, title: u.bio, subtitle: 'Bio'),
                  if (u.phone == null && u.username == null && u.bio.isEmpty)
                    const SettingsTile(icon: Icons.person_rounded, color: Color(0xFF8A93B4), title: 'No public info'),
                ]),
                if (chat != null)
                  SettingsGroup(children: [
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
                    SettingsTile(
                      icon: u.isContact ? Icons.person_remove_rounded : Icons.person_add_alt_1_rounded,
                      color: Brand.sky,
                      title: u.isContact ? 'Remove from contacts' : 'Add to contacts',
                      onTap: () => _toggle('/contacts/${u.id}', !u.isContact),
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
                      title: u.blocked ? 'Unblock' : 'Block',
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
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          elevation: 0,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: SizedBox(
              width: 64,
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
}
