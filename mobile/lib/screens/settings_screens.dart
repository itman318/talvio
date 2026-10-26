import 'read_later_screen.dart';
import 'login_activity_screen.dart';
import '../widgets/mascot.dart';
import '../core/proxy.dart';
import 'proxy_screen.dart';
import 'notifications_screen.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import 'chat_screen.dart';
import '../state/chat_store.dart';
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
import 'qr_screens.dart';
import 'user_profile_screen.dart' show UserProfileScreen;
import 'calls_screen.dart' show CallLinksScreen;
import 'story_screens.dart' show MyHighlightsScreen;
import 'new_chat_screen.dart' show PickUsersScreen;
import '../core/passkeys.dart';
import '../core/prefs.dart';
import '../widgets/sticker_widgets.dart';
import '../theme/brand.dart';
import '../widgets/premium.dart';
import '../widgets/message_extras.dart';

/// One row of Settings (also what the settings search looks through).
class _Item {
  const _Item(this.section, this.icon, this.color, this.title, {this.subtitle, this.trailing, this.onTap, this.keywords = ''});
  final String section;
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final String? trailing;
  final VoidCallback? onTap;
  final String keywords;

  bool matches(String q) => '$title ${subtitle ?? ''} $keywords $section'.toLowerCase().contains(q);
  Widget tile() => SettingsTile(icon: icon, color: color, title: title, subtitle: subtitle, trailing: trailing, onTap: onTap);
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<_Item> _items(BuildContext context, AuthState auth, AppUser me, String support) {
    void go(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    const acc = 'Account', notif = 'Notifications', priv = 'Privacy & security', chats = 'Chats', data = 'Data & connection', extra = 'Extras', help = 'Help';
    return [
      _Item(acc, Icons.person_rounded, Brand.sky, 'Edit profile', subtitle: 'Name, photo, username, bio, birthday', keywords: 'name photo avatar username bio', onTap: () => go(const EditProfileScreen())),
      _Item(acc, Icons.auto_awesome_rounded, Brand.rose, 'Story highlights', subtitle: 'Keep your best stories on your profile', keywords: 'stories', onTap: () => go(const MyHighlightsScreen())),
      _Item(acc, Icons.add_link_rounded, const Color(0xFF3C83DE), 'Call links', subtitle: 'A link anyone can use to call you', keywords: 'call', onTap: () => go(const CallLinksScreen())),
      if (auth.accounts.list.length < auth.maxAccounts)
        _Item(acc, Icons.person_add_alt_1_rounded, Brand.primary, 'Add another account', subtitle: 'Switch between accounts in one tap', keywords: 'switch login', onTap: () async {
          Navigator.of(context).popUntil((r) => r.isFirst);
          try {
            await auth.addAccount();
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        }),
      _Item(notif, Icons.notifications_rounded, const Color(0xFFE5484D), 'Notifications', subtitle: 'Chats, groups, channels, sound, vibration', keywords: 'sound vibrate alert push preview', onTap: () => go(const NotificationsScreen())),
      _Item(priv, Icons.health_and_safety_rounded, const Color(0xFF12A150), 'Security checkup', subtitle: 'Your protection score and quick fixes', keywords: 'secure score', onTap: () => go(const SecurityCheckupScreen())),
      _Item(priv, Icons.visibility_rounded, Brand.green, 'Privacy', subtitle: 'Who can see, message, call and find you', keywords: 'last seen online phone', onTap: () => go(const PrivacyScreen())),
      _Item(priv, Icons.key_rounded, Brand.amber, 'Two-step verification', subtitle: 'An extra password when logging in', keywords: 'password 2fa', onTap: () => go(const TwoStepScreen())),
      _Item(priv, Icons.fingerprint_rounded, const Color(0xFFC8366E), 'Passkeys', subtitle: 'Log in with your fingerprint or face', keywords: 'biometric', onTap: () => go(const PasskeysScreen())),
      _Item(priv, Icons.pin_rounded, Brand.violet, 'App lock', subtitle: 'PIN or fingerprint to open Talvio', keywords: 'pin lock passcode', onTap: () => go(const AppLockSettingsScreen())),
      _Item(priv, Icons.devices_rounded, Brand.sky, 'Devices', subtitle: 'Where you are logged in', keywords: 'sessions logout', onTap: () => go(const SessionsScreen())),
      _Item(priv, Icons.manage_history_rounded, const Color(0xFF3C83DE), 'Login activity', subtitle: 'Every login and blocked attempt', keywords: 'history', onTap: () => go(const LoginActivityScreen())),
      _Item(priv, Icons.block_rounded, const Color(0xFFE5484D), 'Blocked users', keywords: 'block', onTap: () => go(const BlockedUsersScreen())),
      _Item(chats, Icons.palette_rounded, Brand.rose, 'Appearance', subtitle: 'Dark mode, chat theme, text size', keywords: 'theme dark night font wallpaper colour color', onTap: () => go(const AppearanceScreen())),
      _Item(chats, Icons.emoji_emotions_rounded, Brand.primary, 'Stickers & emoji', keywords: 'sticker emoji', onTap: () => go(const StickerPacksScreen())),
      _Item(chats, Icons.folder_rounded, Brand.sky, 'Chat folders', keywords: 'folder tabs', onTap: () => go(const FoldersScreen())),
      _Item(chats, Icons.bookmarks_rounded, Brand.violet, 'Read later', subtitle: 'Messages you saved — on all your devices', keywords: 'bookmark saved', onTap: () => go(const ReadLaterScreen())),
      _Item(chats, Icons.alarm_rounded, Brand.amber, 'Reminders', subtitle: 'Messages you asked to be reminded about', keywords: 'remind', onTap: () => go(const RemindersScreen())),
      _Item(chats, Icons.archive_rounded, const Color(0xFF8A93B4), 'Archived chats', keywords: 'archive', onTap: () => go(const ArchivedChatsScreen())),
      _Item(data, Icons.data_usage_rounded, Brand.green, 'Data & storage', subtitle: 'Auto-download, data saver, storage', keywords: 'download cache space', onTap: () => go(const StorageScreen())),
      _Item(data, Icons.cloud_upload_rounded, Brand.violet, 'Chat backup', subtitle: 'Save a copy to Google Drive or your phone', keywords: 'backup restore drive', onTap: () => go(const BackupScreen())),
      _Item(data, Icons.vpn_lock_rounded, const Color(0xFF3C83DE), 'Proxy', trailing: context.watch<ProxyManager>().enabled ? 'On' : 'Off', keywords: 'socks vpn blocked', onTap: () => go(const ProxySettingsScreen())),
      _Item(extra, Icons.mosque_rounded, const Color(0xFF13A07E), 'Prayer times', subtitle: 'Qibla, Suhoor & Iftar reminders', keywords: 'namaz salah qibla ramadan', onTap: () => go(const PrayerScreen())),
      if (auth.feature('bots')) _Item(extra, Icons.smart_toy_rounded, const Color(0xFF5B49D6), 'My bots', subtitle: 'Create bots and get their keys', keywords: 'bot api botforge', onTap: () => go(const MyBotsScreen())),
      _Item(help, Icons.support_agent_rounded, Brand.sky, 'Help & support', subtitle: support.isNotEmpty ? 'Or message @$support' : null, keywords: 'contact', onTap: () => go(const SupportListScreen())),
      _Item(help, Icons.quiz_rounded, Brand.amber, 'FAQ', keywords: 'questions', onTap: () => go(const ContentPageScreen(slug: 'faq', fallbackTitle: 'FAQ'))),
      _Item(help, Icons.description_rounded, const Color(0xFF8A93B4), 'Terms of service', onTap: () => go(const ContentPageScreen(slug: 'terms', fallbackTitle: 'Terms'))),
      _Item(help, Icons.privacy_tip_rounded, Brand.green, 'Privacy policy', onTap: () => go(const ContentPageScreen(slug: 'privacy', fallbackTitle: 'Privacy'))),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final me = auth.me;
    if (me == null) return const Scaffold();
    final support = '${auth.appConfig['support_username'] ?? ''}';
    final dark = Theme.of(context).brightness == Brightness.dark;
    void go(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    final plus = auth.me?.isPremium == true;
    final items = _items(context, auth, me, support);
    final q = _q.trim().toLowerCase();

    final searchField = Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: TextField(
        controller: _search,
        onChanged: (v) => setState(() => _q = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search settings',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _q.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(() {
                    _search.clear();
                    _q = '';
                  }),
                ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );

    if (q.isNotEmpty) {
      final hits = items.where((i) => i.matches(q)).toList();
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(children: [
          searchField,
          if (hits.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Column(children: [
                Icon(Icons.search_off_rounded, size: 44, color: Brand.muted),
                SizedBox(height: 10),
                Text('Nothing found', textAlign: TextAlign.center, style: TextStyle(color: Brand.muted, fontWeight: FontWeight.w600)),
              ]),
            )
          else
            SettingsGroup(title: '${hits.length} result${hits.length == 1 ? '' : 's'}', children: [
              for (final h in hits)
                SettingsTile(icon: h.icon, color: h.color, title: h.title, subtitle: h.subtitle ?? h.section, trailing: h.trailing, onTap: h.onTap),
            ]),
        ]),
      );
    }

    final sections = <String>[];
    for (final i in items) {
      if (!sections.contains(i.section)) sections.add(i.section);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          // profile card: the person's own colours, like the cover on their profile
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(26),
                onTap: () => go(UserProfileScreen(userId: me.id)),
                child: Ink(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    gradient: LinearGradient(
                      colors: [gradientForId(me.id)[0], gradientForId(me.id)[1], Color.lerp(gradientForId(me.id)[1], Brand.ink, 0.5)!],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [BoxShadow(color: gradientForId(me.id)[1].withValues(alpha: dark ? 0.25 : 0.3), blurRadius: 20, offset: const Offset(0, 8))],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: Stack(children: [
                      Positioned(right: -30, top: -40, child: Container(width: 140, height: 140, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.12)))),
                      Positioned(left: 90, bottom: -50, child: Container(width: 110, height: 110, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.08)))),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(children: [
                          Container(
                            padding: const EdgeInsets.all(2.5),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(67 * 0.34),
                              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 12, offset: const Offset(0, 4))],
                            ),
                            child: Avatar(id: me.id, name: me.name, url: me.avatarAbsolute, size: 62),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Flexible(
                                  child: Text(me.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: Colors.white)),
                                ),
                                if (plus) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.workspace_premium_rounded, color: Color(0xFFFFE3A3), size: 20)),
                              ]),
                              const SizedBox(height: 2),
                              for (final line in [me.phone ?? me.email ?? '', if (me.username != null) '@${me.username}'].where((s) => s.isNotEmpty))
                                Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withValues(alpha: 0.82), fontSize: 13.5)),
                              const SizedBox(height: 6),
                              Text('View profile ›', style: TextStyle(color: Colors.white.withValues(alpha: 0.95), fontWeight: FontWeight.w700, fontSize: 12.5)),
                            ]),
                          ),
                          Column(mainAxisSize: MainAxisSize.min, children: [
                            _glassIcon(Icons.qr_code_2_rounded, 'My QR code', () => go(const MyQrScreen())),
                            const SizedBox(height: 8),
                            _glassIcon(Icons.edit_rounded, 'Edit profile', () => go(const EditProfileScreen())),
                          ]),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
          searchField,
          // quick shortcuts
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Row(children: [
              Expanded(
                child: QuickTile(
                  icon: Icons.bookmark_rounded,
                  label: 'My Notes',
                  color: Brand.sky,
                  onTap: () async {
                    try {
                      final chat = await context.read<ChatStore>().openPrivateWith(me.id);
                      if (context.mounted) go(ChatScreen(chatId: chat.id, initial: chat));
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: QuickTile(icon: Icons.notifications_rounded, label: 'Alerts', color: const Color(0xFFE5484D), onTap: () => go(const NotificationsScreen()))),
              const SizedBox(width: 10),
              Expanded(child: QuickTile(icon: Icons.palette_rounded, label: 'Theme', color: Brand.rose, onTap: () => go(const AppearanceScreen()))),
              const SizedBox(width: 10),
              Expanded(child: QuickTile(icon: Icons.devices_rounded, label: 'Devices', color: Brand.green, onTap: () => go(const SessionsScreen()))),
            ]),
          ),
          if (auth.otherAccounts.isNotEmpty)
            SettingsGroup(title: 'Switch account', children: [
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
                          Text(plus ? 'Active — thank you for your support' : (context.read<AuthState>().plusAvailable ? 'Bigger uploads, more folders, no ads' : 'Coming soon · bigger uploads, themes, no ads'),
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13)),
                        ]),
                      ),
                      Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.7)),
                    ]),
                  ),
                ),
              ),
            ),
          for (final sec in sections) SettingsGroup(title: sec, children: [for (final i in items.where((i) => i.section == sec)) i.tile()]),
          SettingsGroup(children: [
            SettingsTile(
              icon: Icons.logout_rounded,
              color: const Color(0xFF5E6B8C),
              title: 'Log out',
              onTap: () async {
                if (await confirm(context, 'Log out?', 'You can log back in any time with your email.', ok: 'Log out')) {
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

/// Small frosted round button on the coloured profile card.
Widget _glassIcon(IconData icon, String tooltip, VoidCallback onTap) => Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.2),
        shape: const CircleBorder(),
        child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: Padding(padding: const EdgeInsets.all(9), child: Icon(icon, color: Colors.white, size: 21))),
      ),
    );

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
  Birthday? _birthday;
  bool _birthdayChanged = false;

  @override
  void initState() {
    super.initState();
    final me = context.read<AuthState>().me!;
    _first = TextEditingController(text: me.firstName);
    _last = TextEditingController(text: me.lastName);
    _username = TextEditingController(text: me.username ?? '');
    _bio = TextEditingController(text: me.bio);
    _birthday = me.birthday;
  }

  Future<void> _pickBirthday() async {
    final b = _birthday;
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: b != null ? DateTime(b.year ?? 2000, b.month, b.day) : DateTime(now.year - 20, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: now,
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      helpText: 'Your birthday',
    );
    if (d == null) return;
    setState(() {
      _birthday = Birthday(d.day, d.month, d.year);
      _birthdayChanged = true;
    });
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
        if (_birthdayChanged) 'birthday': _birthday?.api,
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    Widget label(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
          child: Text(t.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 22),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(26), gradient: Brand.auroraSoft(dark)),
            child: Column(children: [
              GestureDetector(
                onTap: _avatar,
                child: Stack(clipBehavior: Clip.none, children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                      child: ClipOval(child: Avatar(id: me.id, name: me.name, url: me.avatarAbsolute, size: 100)),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle, border: Border.all(color: bg, width: 3)),
                      child: const Icon(Icons.photo_camera_rounded, size: 18, color: Colors.white),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 10),
              TextButton(onPressed: _avatar, child: const Text('Change photo')),
            ]),
          ),
          label('Your name'),
          TextField(controller: _first, maxLength: 64, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'First name', prefixIcon: Icon(Icons.person_rounded))),
          const SizedBox(height: 6),
          TextField(controller: _last, maxLength: 64, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Last name (optional)', prefixIcon: Icon(Icons.badge_rounded))),
          label('Username'),
          TextField(
            controller: _username,
            maxLength: 32,
            onChanged: _checkUsername,
            decoration: InputDecoration(
              labelText: 'Username',
              prefixIcon: const Icon(Icons.alternate_email_rounded),
              suffixIcon: _usernameStatus == 'available'
                  ? const Icon(Icons.check_circle_rounded, color: Brand.accent)
                  : (_usernameStatus == null ? null : const Icon(Icons.error_rounded, color: Colors.red)),
              helperText: _usernameStatus == null
                  ? 'People can find you by this name. 5–32 letters, digits or _'
                  : _usernameStatus == 'available'
                      ? 'Username is available'
                      : _usernameStatus == 'taken'
                          ? 'This username is taken'
                          : _usernameStatus,
              helperMaxLines: 2,
              helperStyle: TextStyle(color: _usernameStatus == 'available' ? Brand.accent : (_usernameStatus == null ? null : Colors.red)),
            ),
          ),
          label('About'),
          TextField(
            controller: _bio,
            maxLength: 140,
            maxLines: 3,
            minLines: 2,
            decoration: const InputDecoration(labelText: 'Bio', hintText: 'A few words about you', alignLabelWithHint: true),
          ),
          label('Birthday'),
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _pickBirthday,
            child: InputDecorator(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.cake_rounded),
                suffixIcon: _birthday == null
                    ? null
                    : IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() {
                          _birthday = null;
                          _birthdayChanged = true;
                        }),
                      ),
                helperText: 'Contacts see the day and month (change who in Privacy). The year stays private.',
                helperMaxLines: 2,
              ),
              child: Text(_birthday?.label ?? 'Add your birthday', style: TextStyle(color: _birthday == null ? Brand.muted : null)),
            ),
          ),
          const SizedBox(height: 18),
          AuroraButton(label: 'Save', icon: Icons.check_rounded, busy: _busy, onPressed: _save),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ privacy
class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  static const labels = {'everyone': 'Everybody', 'contacts': 'My contacts', 'nobody': 'Nobody'};
  static const rows = {
    'last_seen': 'Last seen & online',
    'avatar': 'Profile photo',
    'phone': 'Phone number',
    'birthday': 'Birthday',
    'bio': 'Bio',
    'messages': 'Who can message me',
    'forwards': 'Forwarded messages',
    'group_add': 'Who can add me to groups',
    'calls': 'Who can call me',
    'phone_search': 'Who can find me by my number',
  };

  /// Settings with only Everybody / My contacts.
  static const twoChoice = {'messages', 'phone_search'};
  static const noExceptions = {'phone_search'};
  static const help = {
    'last_seen': 'If you hide your last seen, you won’t see other people’s either.',
    'avatar': 'Choose who sees your profile photo.',
    'phone': 'Choose who sees your phone number on your profile.',
    'birthday': 'Choose who sees your birthday and gets a reminder.',
    'bio': 'Choose who can read the bio on your profile.',
    'messages': 'People who aren’t your contacts can’t start a chat with you. They can still reply if you write first.',
    'forwards': 'When someone forwards your messages, the name links to your profile only for the people you allow.',
    'group_add': 'Choose who can add you to groups and channels.',
    'calls': 'Choose who can call you.',
    'phone_search': 'Choose who can find you when they search your number or sync their contacts.',
  };
  static const icons = {
    'last_seen': (Icons.visibility_rounded, Brand.green),
    'avatar': (Icons.account_circle_rounded, Brand.sky),
    'phone': (Icons.phone_rounded, Brand.violet),
    'birthday': (Icons.cake_rounded, Brand.rose),
    'group_add': (Icons.group_add_rounded, Brand.amber),
    'calls': (Icons.call_rounded, Brand.primary),
    'bio': (Icons.notes_rounded, Color(0xFF3C83DE)),
    'messages': (Icons.chat_bubble_rounded, Color(0xFF0FA3A3)),
    'forwards': (Icons.forward_rounded, Color(0xFFE07A2E)),
    'phone_search': (Icons.person_search_rounded, Color(0xFF5E6B8C)),
  };

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  Map<String, dynamic> _exceptions = {};

  @override
  void initState() {
    super.initState();
    _loadExceptions();
  }

  Future<void> _loadExceptions() async {
    try {
      final r = await context.read<AppServices>().api.get('/me/privacy/exceptions');
      if (mounted) setState(() => _exceptions = Map<String, dynamic>.from(r as Map));
    } catch (_) {}
  }

  String _summary(String key, String value) {
    final e = _exceptions[key];
    final allow = e is Map ? (e['allow'] as List? ?? const []).length : 0;
    final deny = e is Map ? (e['deny'] as List? ?? const []).length : 0;
    final parts = [PrivacyScreen.labels[value] ?? '—', if (deny > 0) '−$deny', if (allow > 0) '+$allow'];
    return parts.join(' ');
  }

  Future<void> _setBool(String key, bool v) async {
    try {
      final u = await context.read<AppServices>().api.put('/me/privacy', {key: v});
      if (mounted) context.read<AuthState>().setMe(AppUser.fromJson(Map<String, dynamic>.from(u as Map)));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  String _daysLabel(Object d) {
    final n = d is num ? d.toInt() : int.tryParse('$d') ?? 0;
    if (n >= 730) return '2 years';
    if (n >= 365) return '1 year';
    if (n >= 30) return '${n ~/ 30} month${n >= 60 ? 's' : ''}';
    return '${n ~/ 7} week${n >= 14 ? 's' : ''}';
  }

  String _durationLabel(Object s, {String zero = 'Off'}) {
    final n = s is num ? s.toInt() : 0;
    if (n == 0) return zero;
    if (n >= 2592000) return '1 month';
    if (n >= 604800) return '1 week';
    return '1 day';
  }

  Future<void> _pickNumber(String title, String help, String key, Map<int, String> options, Object current) async {
    final cur = current is num ? current.toInt() : 0;
    final v = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(help, style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ),
          for (final e in options.entries)
            ListTile(
              title: Text(e.value),
              trailing: e.key == cur ? const Icon(Icons.check_circle_rounded, color: Brand.primary) : null,
              onTap: () => Navigator.pop(ctx, e.key),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (v == null || v == cur || !mounted) return;
    try {
      final u = await context.read<AppServices>().api.put('/me/privacy', {key: v});
      if (mounted) context.read<AuthState>().setMe(AppUser.fromJson(Map<String, dynamic>.from(u as Map)));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthState>().me;
    final p = me?.privacy ?? {};
    final sec = me?.security ?? const <String, dynamic>{};
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & security')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SettingsGroup(title: 'Who can see and reach me', children: [
            for (final r in PrivacyScreen.rows.entries)
              SettingsTile(
                icon: PrivacyScreen.icons[r.key]!.$1,
                color: PrivacyScreen.icons[r.key]!.$2,
                title: r.value,
                trailing: _summary(r.key, p[r.key] ?? (r.key == 'birthday' ? 'contacts' : 'everyone')),
                onTap: () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => PrivacySettingScreen(setting: r.key)));
                  _loadExceptions();
                },
              ),
          ]),
          SettingsGroup(title: 'Security', children: [
            SettingsTile(
              icon: Icons.health_and_safety_rounded,
              color: Brand.green,
              title: 'Security checkup',
              subtitle: 'See how well your account is protected',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SecurityCheckupScreen())),
            ),
            SettingsTile(
              icon: Icons.timer_rounded,
              color: Brand.violet,
              title: 'Auto-delete messages',
              subtitle: 'Timer for new chats you start',
              trailing: _durationLabel(sec['default_disappear_sec'] ?? 0, zero: 'Off'),
              onTap: () => _pickNumber('Auto-delete messages', 'New chats and groups you create get this timer. Messages disappear for everyone after the time.', 'default_disappear_sec', const {
                0: 'Off',
                86400: '1 day',
                604800: '1 week',
                2592000: '1 month',
              }, sec['default_disappear_sec'] ?? 0),
            ),
            SettingsTile(
              icon: Icons.phonelink_erase_rounded,
              color: Brand.amber,
              title: 'Log out inactive devices',
              subtitle: 'Devices you don’t use are logged out by themselves',
              trailing: _daysLabel(sec['session_ttl_days'] ?? 180),
              onTap: () => _pickNumber('Log out inactive devices', 'A device you haven’t used for this long is logged out automatically.', 'session_ttl_days', const {
                7: '1 week',
                30: '1 month',
                90: '3 months',
                180: '6 months',
                365: '1 year',
              }, sec['session_ttl_days'] ?? 180),
            ),
            SettingsTile(
              icon: Icons.auto_delete_rounded,
              color: const Color(0xFFE5484D),
              title: 'Delete my account if away for',
              subtitle: 'Your account and messages are removed if you don’t come online',
              trailing: _daysLabel(sec['account_ttl_days'] ?? 365),
              onTap: () => _pickNumber('Delete my account if away for', 'If you don’t come online at least once in this time, your account is deleted with all messages and contacts.', 'account_ttl_days', const {
                30: '1 month',
                90: '3 months',
                180: '6 months',
                365: '1 year',
                730: '2 years',
              }, sec['account_ttl_days'] ?? 365),
            ),
            SettingsSwitchTile(
              icon: Icons.visibility_off_rounded,
              color: const Color(0xFF5E6B8C),
              title: 'Hide me from username search',
              subtitle: 'Only people who type your exact username (or your contacts) can find you',
              value: sec['hide_from_search'] == true,
              onChanged: (v) => _setBool('hide_from_search', v),
            ),
          ]),
          SettingsGroup(title: 'Messages', children: [
            SettingsSwitchTile(
              icon: Icons.done_all_rounded,
              color: Brand.sky,
              title: 'Read receipts',
              subtitle: 'Turn off and people won’t see when you read their messages — and you won’t see theirs. Groups always show them.',
              value: p['read_receipts'] != 'off',
              onChanged: (v) => _setBool('read_receipts', v),
            ),
            SettingsSwitchTile(
              icon: Icons.mark_email_unread_rounded,
              color: Brand.rose,
              title: 'Message requests',
              subtitle: 'Messages from people who are not in your contacts wait in Requests, without notifications',
              value: p['message_requests'] != 'off',
              onChanged: (v) => _setBool('message_requests', v),
            ),
          ]),
        ],
      ),
    );
  }
}

/// One privacy setting: Everybody / My contacts / Nobody, plus "Never share with" and "Always share with".
class PrivacySettingScreen extends StatefulWidget {
  const PrivacySettingScreen({super.key, required this.setting});
  final String setting;

  @override
  State<PrivacySettingScreen> createState() => _PrivacySettingScreenState();
}

class _PrivacySettingScreenState extends State<PrivacySettingScreen> {
  List<AppUser> _allow = [];
  List<AppUser> _deny = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/me/privacy/exceptions') as Map);
      final e = Map<String, dynamic>.from((r[widget.setting] ?? const {}) as Map);
      List<AppUser> users(Object? l) => [for (final j in (l as List? ?? const [])) AppUser.fromJson(Map<String, dynamic>.from(j as Map))];
      if (mounted) {
        setState(() {
          _allow = users(e['allow']);
          _deny = users(e['deny']);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  Future<void> _setValue(String v) async {
    try {
      final u = await context.read<AppServices>().api.put('/me/privacy', {widget.setting: v});
      if (mounted) context.read<AuthState>().setMe(AppUser.fromJson(Map<String, dynamic>.from(u as Map)));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _pick(bool allow) async {
    final picked = await Navigator.push<List<AppUser>>(
      context,
      MaterialPageRoute(builder: (_) => PickUsersScreen(title: allow ? 'Always share with' : 'Never share with', initial: allow ? _allow : _deny)),
    );
    if (picked == null || !mounted) return;
    final allowList = allow ? picked : _allow.where((u) => !picked.any((p) => p.id == u.id)).toList();
    final denyList = allow ? _deny.where((u) => !picked.any((p) => p.id == u.id)).toList() : picked;
    try {
      await context.read<AppServices>().api.put('/me/privacy/exceptions/${widget.setting}', {
        'allow': allowList.map((u) => u.id).toList(),
        'deny': denyList.map((u) => u.id).toList(),
      });
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  String _names(List<AppUser> l) => l.isEmpty ? 'Add people' : (l.length <= 2 ? l.map((u) => u.firstName.isEmpty ? u.name : u.firstName).join(', ') : '${l.length} people');

  @override
  Widget build(BuildContext context) {
    final key = widget.setting;
    final p = context.watch<AuthState>().me?.privacy ?? {};
    final current = p[key] ?? (key == 'birthday' ? 'contacts' : 'everyone');
    final icon = PrivacyScreen.icons[key]!;
    return Scaffold(
      appBar: AppBar(title: Text(PrivacyScreen.rows[key]!)),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        SettingsGroup(title: 'Who can see it', children: [
          for (final e in PrivacyScreen.labels.entries)
            if (!(PrivacyScreen.twoChoice.contains(key) && e.key == 'nobody'))
              RadioListTile<String>(value: e.key, groupValue: current, title: Text(e.value), onChanged: (v) => _setValue(v!)),
        ]),
        if (!PrivacyScreen.noExceptions.contains(key))
        SettingsGroup(title: 'Exceptions', children: [
          if (current != 'nobody')
            SettingsTile(
              icon: Icons.person_remove_rounded,
              color: Brand.rose,
              title: 'Never share with',
              subtitle: _loading ? '…' : _names(_deny),
              onTap: _loading ? null : () => _pick(false),
            ),
          if (current != 'everyone')
            SettingsTile(
              icon: Icons.person_add_alt_1_rounded,
              color: Brand.green,
              title: 'Always share with',
              subtitle: _loading ? '…' : _names(_allow),
              onTap: _loading ? null : () => _pick(true),
            ),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Icon(icon.$1, size: 16, color: Brand.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${PrivacyScreen.help[key] ?? ''} ${PrivacyScreen.noExceptions.contains(key) ? '' : 'Exceptions win over the choice above.'} People you block never see anything.',
                  style: const TextStyle(color: Brand.muted, fontSize: 12.5)),
            ),
          ]),
        ),
      ]),
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
              ? const EmptyState(pose: TaviPose.cool, title: 'Nobody blocked', subtitle: 'People you block can’t message or call you. They show up here.')
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
            const TaviMascot(pose: TaviPose.hideEyes, size: 110),
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
                  TaviMascot(pose: on ? TaviPose.cool : TaviPose.hideEyes, size: 76),
                  const SizedBox(width: 10),
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


/// Settings → Passkeys: log in with the phone's fingerprint / face instead of a code.
class PasskeysScreen extends StatefulWidget {
  const PasskeysScreen({super.key});

  @override
  State<PasskeysScreen> createState() => _PasskeysScreenState();
}

class _PasskeysScreenState extends State<PasskeysScreen> {
  List<Map<String, dynamic>>? _server;
  Set<int> _local = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppServices>().api.get('/me/passkeys') as List;
      final local = (await Passkeys.forThisServer()).map((p) => p.credentialId).toSet();
      if (mounted) {
        setState(() {
          _server = r.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          _local = local;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _server = const []);
        showError(context, e);
      }
    }
  }

  Future<void> _create() async {
    final auth = context.read<AuthState>();
    setState(() => _busy = true);
    try {
      await Passkeys.create(context.read<AppServices>().api, userId: auth.me!.id, accountName: auth.me!.name);
      await _load();
      if (mounted) showInfo(context, 'Passkey created — next time just use your fingerprint');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Map<String, dynamic> p) async {
    if (!await confirm(context, 'Remove passkey?', 'That device will need a login code again.', ok: 'Remove', danger: true)) return;
    if (!mounted) return;
    try {
      final id = (p['id'] as num).toInt();
      await context.read<AppServices>().api.delete('/me/passkeys/$id');
      await Passkeys.forget(id);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _server;
    final hasHere = list?.any((p) => _local.contains((p['id'] as num).toInt())) ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Passkeys')),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), gradient: Brand.auroraSoft(Theme.of(context).brightness == Brightness.dark)),
                  child: const Row(children: [
                    Icon(Icons.fingerprint_rounded, size: 44, color: Brand.rose),
                    SizedBox(width: 14),
                    Expanded(
                      child: Text('Log in with your fingerprint, face or screen lock — no code needed. The key stays on this phone and never leaves it.',
                          style: TextStyle(height: 1.4)),
                    ),
                  ]),
                ),
              ),
              if (!hasHere)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: AuroraButton(label: 'Create a passkey on this phone', icon: Icons.add_rounded, busy: _busy, onPressed: _create),
                ),
              if (list.isNotEmpty)
                SettingsGroup(title: 'Your passkeys', children: [
                  for (final p in list)
                    ListTile(
                      leading: const Icon(Icons.phone_android_rounded),
                      title: Text('${p['name']}${_local.contains((p['id'] as num).toInt()) ? ' (this phone)' : ''}'),
                      subtitle: Text(p['last_used_at'] == null
                          ? 'Never used'
                          : 'Last used ${chatListTime(DateTime.parse('${p['last_used_at']}').toLocal())}'),
                      trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _remove(p)),
                    ),
                ]),
            ]),
    );
  }
}


/// A quick score of how well the account is protected, with one tap to fix each item.
class SecurityCheckupScreen extends StatefulWidget {
  const SecurityCheckupScreen({super.key});

  @override
  State<SecurityCheckupScreen> createState() => _SecurityCheckupScreenState();
}

class _SecurityCheckupScreenState extends State<SecurityCheckupScreen> {
  int? _devices;
  int? _passkeys;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppServices>().api;
    try {
      final s = await api.get('/me/sessions') as List;
      if (mounted) setState(() => _devices = s.length);
    } catch (_) {}
    try {
      final p = await api.get('/me/passkeys') as List;
      if (mounted) setState(() => _passkeys = p.length);
    } catch (_) {}
  }

  Future<void> _go(Widget w) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    if (!mounted) return;
    try {
      await context.read<AuthState>().refreshMe();
    } catch (_) {}
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthState>().me;
    final prefs = context.watch<AppPrefs>();
    final p = me?.privacy ?? {};
    final items = <(bool, IconData, String, String, Widget)>[
      (me?.hasPassword == true, Icons.key_rounded, 'Two-step verification', 'An extra password protects you if someone gets your login code', const TwoStepScreen()),
      ((me?.email ?? '').isNotEmpty, Icons.alternate_email_rounded, 'Login email', 'Lets you get back into your account', const EditProfileScreen()),
      ((_passkeys ?? 0) > 0, Icons.fingerprint_rounded, 'Passkey', 'Log in with your fingerprint — nothing to steal', const PasskeysScreen()),
      (prefs.lockEnabled, Icons.pin_rounded, 'App lock', 'A PIN or fingerprint when Talvio opens', const AppLockSettingsScreen()),
      ((_devices ?? 1) <= 3, Icons.devices_rounded, 'Devices', _devices == null ? 'Checking…' : '$_devices device${_devices == 1 ? '' : 's'} logged in — remove ones you don’t know', const SessionsScreen()),
      (p['phone'] != 'everyone', Icons.phone_locked_rounded, 'Phone number hidden', 'Strangers can’t see your number', const PrivacySettingScreen(setting: 'phone')),
      (p['last_seen'] != 'everyone' || p['messages'] == 'contacts', Icons.shield_moon_rounded, 'Stranger protection', 'Hide last seen or allow messages only from contacts', const PrivacySettingScreen(setting: 'messages')),
    ];
    final done = items.where((i) => i.$1).length;
    final score = (done / items.length * 100).round();
    final color = score >= 80 ? Brand.green : (score >= 50 ? Brand.amber : const Color(0xFFE5484D));
    final label = score >= 80 ? 'Strong' : (score >= 50 ? 'Good — a few steps left' : 'Needs attention');
    return Scaffold(
      appBar: AppBar(title: const Text('Security checkup')),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(24)),
          child: Row(children: [
            SizedBox(
              width: 84,
              height: 84,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: score / 100,
                    strokeWidth: 8,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation(Colors.white),
                  ),
                ),
                Text('$score', style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
              ]),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('$done of ${items.length} protections are on', style: const TextStyle(color: Colors.white, fontSize: 13.5)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                  child: Text(score >= 80 ? 'Well protected' : 'Tap an item to fix it', style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
                ),
              ]),
            ),
          ]),
        ),
        SettingsGroup(children: [
          for (final i in items)
            SettingsTile(
              icon: i.$2,
              color: i.$1 ? Brand.green : Brand.amber,
              title: i.$3,
              subtitle: i.$4,
              trailing: i.$1 ? 'On' : 'Fix',
              onTap: () => _go(i.$5),
            ),
        ]),
      ]),
    );
  }
}
