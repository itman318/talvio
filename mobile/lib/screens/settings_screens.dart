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
import '../widgets/sticker_widgets.dart';
import '../theme/brand.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final me = auth.me;
    if (me == null) return const Scaffold();
    final support = '${auth.appConfig['support_username'] ?? ''}';
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          if (auth.isDemo)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Brand.amber.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(14)),
              child: const Row(children: [
                Icon(Icons.play_circle_outline_rounded),
                SizedBox(width: 10),
                Expanded(child: Text('Demo account — sample chats on this phone only. Log out to use a real account.')),
              ]),
            ),
          ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: Avatar(id: me.id, name: me.name, url: me.avatarAbsolute, size: 64),
            title: Text(me.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            subtitle: Text([me.phone ?? me.email ?? '', if (me.username != null) '@${me.username}'].where((s) => s.isNotEmpty).join('\n')),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EditProfileScreen())),
          ),
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
            ListTile(
              leading: const CircleAvatar(radius: 18, child: Icon(Icons.add, size: 20)),
              title: const Text('Add account'),
              onTap: () async {
                Navigator.of(context).popUntil((r) => r.isFirst);
                try {
                  await auth.addAccount();
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Edit profile'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EditProfileScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Privacy'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Blocked users'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BlockedUsersScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.devices),
            title: const Text('Devices'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SessionsScreen())),
          ),
          if (auth.feature('premium'))
            ListTile(
              leading: const Icon(Icons.star_rounded, color: premiumColor),
              title: const Text('Talvio Plus'),
              subtitle: Text(auth.me?.isPremium == true ? 'Active' : 'Bigger uploads, more folders, no ads'),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PremiumScreen())),
            ),
          if (auth.feature('bots'))
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: const Text('My bots'),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyBotsScreen())),
            ),
          ListTile(
            leading: const Icon(Icons.mosque_outlined),
            title: const Text('Prayer times'),
            subtitle: const Text('Qibla, Suhoor & Iftar reminders'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrayerScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.emoji_emotions_outlined),
            title: const Text('Stickers'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StickerPacksScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.pin_outlined),
            title: const Text('App lock'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppLockSettingsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Appearance'),
            subtitle: const Text('Dark mode, text size'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppearanceScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.data_usage),
            title: const Text('Data & storage'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StorageScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Archived chats'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ArchivedChatsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Chat folders'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FoldersScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('Help & support'),
            subtitle: support.isNotEmpty ? Text('Or message @$support') : null,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportListScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.quiz_outlined),
            title: const Text('FAQ'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ContentPageScreen(slug: 'faq', fallbackTitle: 'FAQ'))),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Terms of service'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ContentPageScreen(slug: 'terms', fallbackTitle: 'Terms'))),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy policy'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ContentPageScreen(slug: 'privacy', fallbackTitle: 'Privacy'))),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Log out'),
            onTap: () async {
              if (await confirm(context, 'Log out?', 'You can log back in with your phone number.', ok: 'Log out')) {
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                await auth.logout();
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('Delete my account', style: TextStyle(color: Colors.red)),
            onTap: () => _deleteAccount(context),
          ),
          const SizedBox(height: 16),
          const Center(child: Text('${AppConfig.appName} v${AppConfig.appVersion}', style: TextStyle(color: Brand.muted))),
          const SizedBox(height: 24),
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
