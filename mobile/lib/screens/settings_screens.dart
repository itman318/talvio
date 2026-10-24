import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import 'folder_support_screens.dart';
import 'home_screen.dart';
import 'more_screens.dart';
import 'premium_screens.dart';
import 'bot_screens.dart';
import 'link_device_screen.dart';
import 'prayer_screen.dart';
import 'backup_screen.dart';
import '../widgets/sticker_widgets.dart';
import '../theme/brand.dart';
import '../widgets/premium.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final me = auth.me;
    if (me == null) return const Scaffold();
    final support = '${auth.appConfig['support_username'] ?? ''}';
    final dark = Theme.of(context).brightness == Brightness.dark;
    void go(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    final plus = auth.me?.isPremium == true;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (auth.isDemo)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Brand.amber.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(16)),
              child: const Row(children: [
                Icon(Icons.play_circle_outline_rounded),
                SizedBox(width: 10),
                Expanded(child: Text('Demo account — sample chats on this phone only. Log out to use a real account.')),
              ]),
            ),
          // profile card
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => go(const EditProfileScreen()),
                child: Ink(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: Brand.auroraSoft(dark),
                    border: Border.all(color: dark ? Colors.white.withValues(alpha: 0.06) : Colors.white),
                  ),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, shape: BoxShape.circle),
                        child: ClipOval(child: Avatar(id: me.id, name: me.name, url: me.avatarAbsolute, size: 62)),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Flexible(child: Text(me.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4))),
                          if (plus) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.workspace_premium_rounded, color: Brand.premium, size: 20)),
                        ]),
                        const SizedBox(height: 2),
                        Text([me.phone ?? me.email ?? '', if (me.username != null) '@${me.username}'].where((s) => s.isNotEmpty).join('  ·  '),
                            maxLines: 2, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13.5)),
                      ]),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(20)),
                      child: const Text('Edit', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          if (auth.otherAccounts.isNotEmpty || auth.accounts.list.length < auth.maxAccounts)
            SettingsGroup(children: [
              ...auth.otherAccounts.map((a) => ListTile(
                    leading: Avatar(id: a.id, name: a.name, url: a.avatarUrl == null ? null : AppConfig.absolute(a.avatarUrl!), size: 36),
                    title: Text(a.name),
                    subtitle: Text(a.phone ?? 'Tap to switch'),
                    trailing: const Icon(Icons.swap_horiz),
                    onTap: () {
                      Navigator.of(context).popUntil((r) => r.isFirst);
                      auth.switchTo(a.id);
                    },
                  )),
              if (auth.accounts.list.length < auth.maxAccounts)
                SettingsTile(
                  icon: Icons.person_add_alt_1_rounded,
                  color: Brand.primary,
                  title: 'Add account',
                  onTap: () async {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    try {
                      await auth.addAccount();
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                ),
            ]),
          if (auth.feature('premium'))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => go(const PremiumScreen()),
                  child: Ink(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: const LinearGradient(colors: [Color(0xFF1B1F36), Color(0xFF2B2440)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                      boxShadow: [BoxShadow(color: Brand.ink.withValues(alpha: 0.18), blurRadius: 16, offset: const Offset(0, 6))],
                    ),
                    child: Row(children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(gradient: Brand.plusGradient, borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.workspace_premium_rounded, color: Colors.white),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('Talvio Plus', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                          Text(plus ? 'Active — thank you for your support' : 'Bigger uploads, more folders, no ads',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13)),
                        ]),
                      ),
                      Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.7)),
                    ]),
                  ),
                ),
              ),
            ),
          SettingsGroup(title: 'Account', children: [
            SettingsTile(icon: Icons.person_rounded, color: Brand.sky, title: 'Edit profile', onTap: () => go(const EditProfileScreen())),
            SettingsTile(icon: Icons.lock_rounded, color: Brand.green, title: 'Privacy', onTap: () => go(const PrivacyScreen())),
            SettingsTile(icon: Icons.key_rounded, color: Brand.amber, title: 'Two-step verification', subtitle: 'An extra password when logging in', onTap: () => go(const TwoStepScreen())),
            SettingsTile(icon: Icons.pin_rounded, color: Brand.violet, title: 'App lock', onTap: () => go(const AppLockSettingsScreen())),
            SettingsTile(icon: Icons.devices_rounded, color: const Color(0xFF5E6B8C), title: 'Devices', onTap: () => go(const SessionsScreen())),
            SettingsTile(icon: Icons.block_rounded, color: const Color(0xFFE5484D), title: 'Blocked users', onTap: () => go(const BlockedUsersScreen())),
          ]),
          SettingsGroup(title: 'Chats', children: [
            SettingsTile(icon: Icons.palette_rounded, color: Brand.rose, title: 'Appearance', subtitle: 'Dark mode, chat theme, text size', onTap: () => go(const AppearanceScreen())),
            SettingsTile(icon: Icons.emoji_emotions_rounded, color: Brand.primary, title: 'Stickers & emoji', onTap: () => go(const StickerPacksScreen())),
            SettingsTile(icon: Icons.folder_rounded, color: Brand.sky, title: 'Chat folders', onTap: () => go(const FoldersScreen())),
            SettingsTile(icon: Icons.archive_rounded, color: const Color(0xFF8A93B4), title: 'Archived chats', onTap: () => go(const ArchivedChatsScreen())),
            SettingsTile(icon: Icons.cloud_upload_rounded, color: Brand.violet, title: 'Chat backup', subtitle: 'Save a copy to Google Drive or your phone', onTap: () => go(const BackupScreen())),
            SettingsTile(icon: Icons.data_usage_rounded, color: Brand.green, title: 'Data & storage', onTap: () => go(const StorageScreen())),
          ]),
          SettingsGroup(title: 'Extras', children: [
            SettingsTile(icon: Icons.mosque_rounded, color: const Color(0xFF13A07E), title: 'Prayer times', subtitle: 'Qibla, Suhoor & Iftar reminders', onTap: () => go(const PrayerScreen())),
            if (auth.feature('bots'))
              SettingsTile(icon: Icons.smart_toy_rounded, color: const Color(0xFF5B49D6), title: 'My bots', onTap: () => go(const MyBotsScreen())),
          ]),
          SettingsGroup(title: 'Help', children: [
            SettingsTile(
              icon: Icons.support_agent_rounded,
              color: Brand.sky,
              title: 'Help & support',
              subtitle: support.isNotEmpty ? 'Or message @$support' : null,
              onTap: () => go(const SupportListScreen()),
            ),
            SettingsTile(icon: Icons.quiz_rounded, color: Brand.amber, title: 'FAQ', onTap: () => go(const ContentPageScreen(slug: 'faq', fallbackTitle: 'FAQ'))),
            SettingsTile(icon: Icons.description_rounded, color: const Color(0xFF8A93B4), title: 'Terms of service', onTap: () => go(const ContentPageScreen(slug: 'terms', fallbackTitle: 'Terms'))),
            SettingsTile(icon: Icons.privacy_tip_rounded, color: Brand.green, title: 'Privacy policy', onTap: () => go(const ContentPageScreen(slug: 'privacy', fallbackTitle: 'Privacy'))),
          ]),
          SettingsGroup(children: [
            SettingsTile(
              icon: Icons.logout_rounded,
              color: const Color(0xFF5E6B8C),
              title: 'Log out',
              onTap: () async {
                if (await confirm(context, 'Log out?', 'You can log back in with your phone number.', ok: 'Log out')) {
                  if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                  await auth.logout();
                }
              },
            ),
            SettingsTile(icon: Icons.delete_forever_rounded, color: const Color(0xFFE5484D), title: 'Delete my account', danger: true, onTap: () => _deleteAccount(context)),
          ]),
          const SizedBox(height: 8),
          Center(
            child: Column(children: [
              const BrandMark(size: 28),
              const SizedBox(height: 6),
              Text('${AppConfig.appName} v${AppConfig.appVersion}', style: const TextStyle(color: Brand.muted, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Your profile is removed, you leave all groups and you are logged out everywhere. This cannot be undone.\n\nType DELETE to confirm.'),
          TextField(controller: ctrl, autofocus: true),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim() == 'DELETE'),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final auth = context.read<AuthState>();
      Navigator.of(context).popUntil((r) => r.isFirst);
      await auth.deleteAccount();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

// ------------------------------------------------------------------ edit profile
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final TextEditingController _first;
  late final TextEditingController _last;
  late final TextEditingController _username;
  late final TextEditingController _bio;
  String? _usernameStatus;
  Timer? _debounce;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final me = context.read<AuthState>().me!;
    _first = TextEditingController(text: me.firstName);
    _last = TextEditingController(text: me.lastName);
    _username = TextEditingController(text: me.username ?? '');
    _bio = TextEditingController(text: me.bio);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _checkUsername(String v) {
    _debounce?.cancel();
    final name = v.trim().replaceFirst('@', '');
    if (name.isEmpty || name == context.read<AuthState>().me!.username) {
      setState(() => _usernameStatus = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final r = await context.read<AppServices>().api.get('/me/username-check', query: {'username': name});
        if (mounted) setState(() => _usernameStatus = (r as Map)['available'] == true ? 'available' : 'taken');
      } catch (e) {
        if (mounted) setState(() => _usernameStatus = '$e');
      }
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final u = await context.read<AppServices>().api.patch('/me', {
        'first_name': _first.text.trim(),
        'last_name': _last.text.trim(),
        'username': _username.text.trim().isEmpty ? null : _username.text.trim().replaceFirst('@', ''),
        'bio': _bio.text.trim(),
      });
      if (!mounted) return;
      context.read<AuthState>().setMe(AppUser.fromJson(Map<String, dynamic>.from(u as Map)));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _avatar() async {
    final auth = context.read<AuthState>();
    final api = context.read<AppServices>().api;
    final hasAvatar = auth.me!.avatarUrl != null;
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.photo), title: const Text('Choose photo'), onTap: () => Navigator.pop(ctx, 'pick')),
          if (hasAvatar) ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Remove photo'), onTap: () => Navigator.pop(ctx, 'remove')),
        ]),
      ),
    );
    try {
      if (a == 'pick') {
        final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
        if (x == null) return;
        final m = await api.upload(x.path, kind: 'avatar');
        final u = await api.put('/me/avatar', {'media_id': m['id']});
        auth.setMe(AppUser.fromJson(Map<String, dynamic>.from(u as Map)));
      } else if (a == 'remove') {
        final u = await api.delete('/me/avatar');
        auth.setMe(AppUser.fromJson(Map<String, dynamic>.from(u as Map)));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthState>().me!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [TextButton(onPressed: _busy ? null : _save, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: GestureDetector(
              onTap: _avatar,
              child: Stack(children: [
                Avatar(id: me.id, name: me.name, url: me.avatarAbsolute, size: 96),
                const Positioned(right: 0, bottom: 0, child: CircleAvatar(radius: 16, child: Icon(Icons.camera_alt, size: 18))),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          TextField(controller: _first, maxLength: 64, decoration: const InputDecoration(labelText: 'First name')),
          TextField(controller: _last, maxLength: 64, decoration: const InputDecoration(labelText: 'Last name')),
          TextField(
            controller: _username,
            maxLength: 32,
            onChanged: _checkUsername,
            decoration: InputDecoration(
              labelText: 'Username',
              prefixText: '@',
              helperText: _usernameStatus == null
                  ? 'People can find you by this name. 5–32 letters, digits or _'
                  : _usernameStatus == 'available'
                      ? 'Username is available'
                      : _usernameStatus == 'taken'
                          ? 'This username is taken'
                          : _usernameStatus,
              helperStyle: TextStyle(color: _usernameStatus == 'available' ? Colors.green : (_usernameStatus == null ? null : Colors.red)),
            ),
          ),
          TextField(controller: _bio, maxLength: 140, maxLines: 3, decoration: const InputDecoration(labelText: 'Bio')),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ privacy
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  static const _labels = {'everyone': 'Everybody', 'contacts': 'My contacts', 'nobody': 'Nobody'};
  static const _rows = {
    'last_seen': 'Last seen & online',
    'avatar': 'Profile photo',
    'phone': 'Phone number',
    'group_add': 'Who can add me to groups',
    'calls': 'Who can call me',
  };

  Future<void> _change(BuildContext context, String key, String current) async {
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(_rows[key]!),
        children: _labels.entries
            .map((e) => RadioListTile<String>(
                  value: e.key,
                  groupValue: current,
                  title: Text(e.value),
                  onChanged: (v) => Navigator.pop(ctx, v),
                ))
            .toList(),
      ),
    );
    if (v == null || v == current || !context.mounted) return;
    try {
      final u = await context.read<AppServices>().api.put('/me/privacy', {key: v});
      if (context.mounted) context.read<AuthState>().setMe(AppUser.fromJson(Map<String, dynamic>.from(u as Map)));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AuthState>().me?.privacy ?? {};
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: ListView(
        children: _rows.entries
            .map((r) => ListTile(
                  title: Text(r.value),
                  subtitle: Text(_labels[p[r.key]] ?? '—'),
                  onTap: () => _change(context, r.key, p[r.key] ?? 'everyone'),
                ))
            .toList(),
      ),
    );
  }
}

// ------------------------------------------------------------------ blocked users
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  List<AppUser>? _users;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<AppServices>().api.get('/blocks') as List;
      if (mounted) setState(() => _users = data.map((j) => AppUser.fromJson(Map<String, dynamic>.from(j as Map))).toList());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = _users;
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked users')),
      body: users == null
          ? const Center(child: CircularProgressIndicator())
          : users.isEmpty
              ? const Center(child: Text('You haven’t blocked anyone'))
              : ListView(
                  children: users
                      .map((u) => ListTile(
                            leading: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute),
                            title: Text(u.name),
                            trailing: TextButton(
                              onPressed: () async {
                                try {
                                  await context.read<AppServices>().api.delete('/blocks/${u.id}');
                                  await _load();
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                }
                              },
                              child: const Text('Unblock'),
                            ),
                          ))
                      .toList(),
                ),
    );
  }
}

// ------------------------------------------------------------------ devices
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key});

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<DeviceSession>? _sessions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<AppServices>().api.get('/me/sessions') as List;
      if (mounted) setState(() => _sessions = data.map((j) => DeviceSession.fromJson(Map<String, dynamic>.from(j as Map))).toList());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _terminate(String path, String title) async {
    if (!await confirm(context, title, 'Those devices will be logged out.', ok: 'Terminate', danger: true)) return;
    if (!mounted) return;
    try {
      final api = context.read<AppServices>().api;
      if (path.endsWith('terminate-others')) {
        await api.post(path);
      } else {
        await api.delete(path);
      }
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  IconData _icon(String p) => switch (p) {
        'android' => Icons.android,
        'ios' => Icons.phone_iphone,
        'web' => Icons.language,
        'desktop' => Icons.desktop_windows_outlined,
        _ => Icons.devices_other,
      };

  @override
  Widget build(BuildContext context) {
    final s = _sessions;
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.qr_code_scanner, color: Brand.primary),
                  title: const Text('Link a device', style: TextStyle(color: Brand.primary)),
                  subtitle: const Text('Use ${AppConfig.appName} on your computer (web or desktop app)'),
                  onTap: () async {
                    final linked = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const LinkDeviceScreen()));
                    if (linked == true) _load();
                  },
                ),
                const Divider(),
                ...s.where((x) => x.current).map((x) => ListTile(
                      leading: Icon(_icon(x.platform)),
                      title: Text(x.deviceName.isEmpty ? 'This device' : x.deviceName),
                      subtitle: const Text('This device · online'),
                    )),
                if (s.length > 1)
                  ListTile(
                    leading: const Icon(Icons.pan_tool, color: Colors.red),
                    title: const Text('Terminate all other sessions', style: TextStyle(color: Colors.red)),
                    onTap: () => _terminate('/me/sessions/terminate-others', 'Log out other devices?'),
                  ),
                const Divider(),
                ...s.where((x) => !x.current).map((x) => ListTile(
                      leading: Icon(_icon(x.platform)),
                      title: Text(x.deviceName.isEmpty ? x.platform : x.deviceName),
                      subtitle: Text([
                        if (x.appVersion.isNotEmpty) 'v${x.appVersion}',
                        if (x.ip != null) x.ip!,
                        if (x.lastActiveAt != null) chatListTime(x.lastActiveAt!),
                      ].join(' · ')),
                      trailing: IconButton(
                        icon: const Icon(Icons.logout),
                        onPressed: () => _terminate('/me/sessions/${x.id}', 'Log out this device?'),
                      ),
                    )),
              ],
            ),
    );
  }
}


/// Settings → Two-step verification: set, change or remove the account password.
class TwoStepScreen extends StatefulWidget {
  const TwoStepScreen({super.key});

  @override
  State<TwoStepScreen> createState() => _TwoStepScreenState();
}

class _TwoStepScreenState extends State<TwoStepScreen> {
  Map<String, dynamic>? _st;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/me/password') as Map);
      if (mounted) setState(() => _st = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _edit({required bool change}) async {
    final api = context.read<AppServices>().api;
    final cur = TextEditingController();
    final pw = TextEditingController();
    final pw2 = TextEditingController();
    final hint = TextEditingController(text: change ? '${_st?['hint'] ?? ''}' : '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(change ? 'Change password' : 'Set a password'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (change) TextField(controller: cur, obscureText: true, decoration: const InputDecoration(labelText: 'Current password')),
            TextField(controller: pw, obscureText: true, autofocus: !change, decoration: const InputDecoration(labelText: 'New password', helperText: 'At least 6 characters')),
            TextField(controller: pw2, obscureText: true, decoration: const InputDecoration(labelText: 'Repeat new password')),
            TextField(controller: hint, maxLength: 64, decoration: const InputDecoration(labelText: 'Hint (optional)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (pw.text != pw2.text) {
      showInfo(context, 'The passwords do not match');
      return;
    }
    try {
      final r = Map<String, dynamic>.from(await api.put('/me/password', {
        if (change) 'current_password': cur.text,
        'new_password': pw.text,
        'hint': hint.text.trim(),
      }) as Map);
      if (!mounted) return;
      setState(() => _st = r);
      showInfo(context, change ? 'Password changed' : 'Two-step verification is on');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _remove() async {
    final api = context.read<AppServices>().api;
    final cur = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Turn off two-step verification?'),
        content: TextField(controller: cur, obscureText: true, autofocus: true, decoration: const InputDecoration(labelText: 'Current password')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: Colors.red), child: const Text('Turn off')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = Map<String, dynamic>.from(await api.post('/me/password/remove', {'current_password': cur.text}) as Map);
      if (mounted) setState(() => _st = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _cancelReset() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.post('/me/password/cancel-reset') as Map);
      if (mounted) setState(() => _st = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = _st;
    final on = st?['enabled'] == true;
    final pending = st?['reset_pending_until'] as String?;
    return Scaffold(
      appBar: AppBar(title: const Text('Two-step verification')),
      body: st == null
          ? Center(child: _error != null ? Text(friendlyError(_error!)) : const CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: (on ? Brand.accent : Brand.amber).withValues(alpha: 0.14),
                ),
                child: Row(children: [
                  Icon(on ? Icons.verified_user_rounded : Icons.shield_outlined, size: 40, color: on ? Brand.accent : Brand.amber),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(on ? 'Two-step verification is on' : 'Two-step verification is off',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text(on
                          ? 'Logging in on a new device needs your password as well as the code.'
                          : 'Add a password that is needed, together with the login code, on new devices.'),
                    ]),
                  ),
                ]),
              ),
              if (pending != null) ...[
                const SizedBox(height: 12),
                Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                    title: const Text('Someone asked to reset your password'),
                    subtitle: Text('It will be removed on ${DateTime.parse(pending).toLocal().toString().substring(0, 16)}.'),
                    trailing: TextButton(onPressed: _cancelReset, child: const Text('Cancel reset')),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (!on)
                FilledButton.icon(
                  onPressed: () => _edit(change: false),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  icon: const Icon(Icons.key_rounded),
                  label: const Text('Set password'),
                )
              else ...[
                if ('${st['hint'] ?? ''}'.isNotEmpty)
                  ListTile(leading: const Icon(Icons.lightbulb_outline), title: const Text('Hint'), subtitle: Text('${st['hint']}')),
                ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Change password'), onTap: () => _edit(change: true)),
                ListTile(
                  leading: const Icon(Icons.no_encryption_gmailerrorred_outlined, color: Colors.red),
                  title: const Text('Turn off', style: TextStyle(color: Colors.red)),
                  onTap: _remove,
                ),
              ],
            ]),
    );
  }
}
