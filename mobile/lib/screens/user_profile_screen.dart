import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
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
import 'shared_media_screen.dart';
import 'story_screens.dart' show HighlightsRow;

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
    final chat = u == null ? null : store.chats.where((c) => c.peer?.id == u.id).firstOrNull;
    final other = u != null && !u.deleted && u.id != myId;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white, // over the cover banner
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      extendBodyBehindAppBar: true,
      body: u == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.zero,
              children: [
                ProfileHero(
                  id: u.id,
                  name: u.name,
                  avatarUrl: u.avatarAbsolute,
                  online: u.online,
                  topPadding: MediaQuery.of(context).padding.top + 44,
                  status: u.isBot ? 'bot' : lastSeenText(u),
                  statusColor: u.online ? Brand.accent : null,
                  badges: [
                    if (u.isVerified) const Icon(Icons.verified_rounded, color: Brand.sky, size: 22),
                    if (u.isPremium) const Icon(Icons.workspace_premium_rounded, color: Brand.premium, size: 22),
                  ],
                  actions: [
                    if (other) ...[
                      ProfileAction(icon: Icons.chat_bubble_rounded, label: 'Message', highlight: true, onTap: () => _message(u)),
                      if (auth.feature('calls')) ProfileAction(icon: Icons.call_rounded, label: 'Call', onTap: () => startCall(context, u, video: false)),
                      if (auth.feature('calls') && auth.feature('video_calls'))
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
                      if (auth.feature('secret_chats')) ProfileAction(icon: Icons.lock_rounded, label: 'Vault', onTap: () => startSecretChat(context, u)),
                    ],
                  ],
                ),
                if (!u.deleted) HighlightsRow(key: ValueKey('hl${u.id}'), userId: u.id, mine: u.id == myId),
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
                  if (u.bio.isNotEmpty) SettingsTile(icon: Icons.info_rounded, color: Brand.violet, title: u.bio, subtitle: 'Bio'),
                  if (u.birthday != null)
                    SettingsTile(
                      icon: Icons.cake_rounded,
                      color: Brand.rose,
                      title: u.birthday!.isToday ? '${u.birthday!.label} 🎉' : u.birthday!.label,
                      subtitle: u.birthday!.isToday && other ? 'Birthday today — send a wish!' : 'Birthday',
                      onTap: u.birthday!.isToday && other ? () => _message(u) : null,
                    ),
                  if (u.phone == null && u.username == null && u.bio.isEmpty && u.birthday == null)
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
}
