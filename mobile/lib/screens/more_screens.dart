import 'dart:convert';
import 'chat_theme_screen.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import '../core/chat_links.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:local_auth/local_auth.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/api_client.dart';
import '../core/prefs.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/mascot.dart';
import '../widgets/avatar.dart';
import 'chat_screen.dart';
import '../theme/brand.dart';

// ================================================================== invite links
class InviteLinksScreen extends StatefulWidget {
  const InviteLinksScreen({super.key, required this.chat});
  final Chat chat;

  @override
  State<InviteLinksScreen> createState() => _InviteLinksScreenState();
}

class _InviteLinksScreenState extends State<InviteLinksScreen> {
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<ChatStore>().listInvites(widget.chat.id);
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _create() async {
    final name = TextEditingController();
    int? hours;
    int? limit;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('New invite link'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, maxLength: 32, decoration: const InputDecoration(labelText: 'Name (optional)', hintText: 'e.g. Facebook post')),
            DropdownButtonFormField<int?>(
              value: hours,
              decoration: const InputDecoration(labelText: 'Expires'),
              items: const [
                DropdownMenuItem(value: null, child: Text('Never')),
                DropdownMenuItem(value: 1, child: Text('In 1 hour')),
                DropdownMenuItem(value: 24, child: Text('In 1 day')),
                DropdownMenuItem(value: 168, child: Text('In 7 days')),
                DropdownMenuItem(value: 720, child: Text('In 30 days')),
              ],
              onChanged: (v) => setState(() => hours = v),
            ),
            DropdownButtonFormField<int?>(
              value: limit,
              decoration: const InputDecoration(labelText: 'Number of uses'),
              items: const [
                DropdownMenuItem(value: null, child: Text('No limit')),
                DropdownMenuItem(value: 1, child: Text('1 person')),
                DropdownMenuItem(value: 10, child: Text('10 people')),
                DropdownMenuItem(value: 50, child: Text('50 people')),
                DropdownMenuItem(value: 100, child: Text('100 people')),
              ],
              onChanged: (v) => setState(() => limit = v),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<ChatStore>().createInvite(widget.chat.id, name: name.text.trim(), expireHours: hours, usageLimit: limit);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final links = (d?['links'] as List?)?.map((x) => Map<String, dynamic>.from(x as Map)).toList() ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('Invite links')),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              ListTile(
                leading: const Icon(Icons.link),
                title: Text(inviteChatLink('${d['primary']}')),
                subtitle: const Text('Main invite link — never expires'),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: inviteChatLink('${d['primary']}')));
                    if (context.mounted) showInfo(context, 'Copied');
                  },
                ),
              ),
              const Divider(),
              ...links.map((l) {
                final expired = l['expired'] == true;
                final parts = <String>[
                  '${l['usage_count']}${l['usage_limit'] != null ? '/${l['usage_limit']}' : ''} joined',
                  if (l['revoked'] == true) 'revoked' else if (expired) 'expired',
                  if (l['expires_at'] != null && !expired) 'expires ${chatListTime(DateTime.parse(l['expires_at'] as String).toLocal())}',
                ];
                return ListTile(
                  leading: Icon(Icons.link, color: expired ? Brand.faint : Brand.primary),
                  title: Text('${l['name']}'.isEmpty ? '${l['code']}' : '${l['name']}', style: TextStyle(color: expired ? Brand.faint : null)),
                  subtitle: Text(parts.join(' · ')),
                  trailing: expired
                      ? null
                      : PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'copy') {
                              await Clipboard.setData(ClipboardData(text: inviteChatLink('${l['code']}')));
                              if (context.mounted) showInfo(context, 'Copied');
                            } else {
                              try {
                                await context.read<ChatStore>().revokeInvite(widget.chat.id, '${l['code']}');
                                await _load();
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              }
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'copy', child: Text('Copy link')),
                            PopupMenuItem(value: 'revoke', child: Text('Revoke')),
                          ],
                        ),
                );
              }),
            ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add_link), label: const Text('New link')),
    );
  }
}

// ================================================================== join requests
class JoinRequestsScreen extends StatefulWidget {
  const JoinRequestsScreen({super.key, required this.chat});
  final Chat chat;

  @override
  State<JoinRequestsScreen> createState() => _JoinRequestsScreenState();
}

class _JoinRequestsScreenState extends State<JoinRequestsScreen> {
  List<Map<String, dynamic>>? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<ChatStore>().joinRequests(widget.chat.id);
      if (mounted) setState(() => _list = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _resolve(int userId, bool approve) async {
    try {
      await context.read<ChatStore>().resolveJoinRequest(widget.chat.id, userId, approve);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: const Text('Join requests')),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
              ? const Center(child: Text('No pending requests'))
              : ListView(
                  children: list.map((r) {
                    final u = AppUser.fromJson(Map<String, dynamic>.from(r['user'] as Map));
                    return ListTile(
                      leading: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute, size: 42),
                      title: Text(u.name),
                      subtitle: Text(u.username != null ? '@${u.username}' : 'requested ${chatListTime(DateTime.parse(r['requested_at'] as String).toLocal())}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(icon: const Icon(Icons.close, color: Colors.red), tooltip: 'Decline', onPressed: () => _resolve(u.id, false)),
                        IconButton(icon: const Icon(Icons.check, color: Brand.accent), tooltip: 'Approve', onPressed: () => _resolve(u.id, true)),
                      ]),
                    );
                  }).toList(),
                ),
    );
  }
}

// ================================================================== find friends from phone contacts
class ContactsSyncScreen extends StatefulWidget {
  const ContactsSyncScreen({super.key});

  @override
  State<ContactsSyncScreen> createState() => _ContactsSyncScreenState();
}

class _ContactsSyncScreenState extends State<ContactsSyncScreen> {
  List<AppUser>? _found;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  /// Local numbers ("07400 123456") get the country code of my own number (or the app default).
  String get _myCode {
    final mine = context.read<AuthState>().me?.phone ?? '';
    for (final c in const ['+971', '+966', '+880', '+92', '+44', '+91', '+90', '+49', '+33', '+61', '+1']) {
      if (mine.startsWith(c)) return c;
    }
    return AppConfig.defaultCountryCode;
  }

  /// "0300 1234567" → "+923001234567".
  String? _normalize(String raw) {
    var p = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    if (p.startsWith('00')) p = '+${p.substring(2)}';
    if (p.startsWith('+')) return p.length >= 9 ? p : null;
    if (p.startsWith('0')) p = p.substring(1);
    if (p.length < 7) return null;
    return '$_myCode$p';
  }

  Future<void> _sync() async {
    setState(() {
      _error = null;
      _found = null;
    });
    try {
      if (!await FlutterContacts.requestPermission(readonly: true)) {
        setState(() => _error = 'Allow access to contacts to find friends who use the app.');
        return;
      }
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      final phones = <String>{};
      for (final c in contacts) {
        for (final ph in c.phones) {
          final n = _normalize(ph.number);
          if (n != null) phones.add(n);
        }
      }
      if (!mounted) return;
      final users = await context.read<ChatStore>().syncContacts(phones.toList());
      if (mounted) setState(() => _found = users);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : 'Could not read contacts');
    }
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    return Scaffold(
      appBar: AppBar(title: const Text('Friends from contacts')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _sync, child: const Text('Try again')),
                ]),
              ),
            )
          : found == null
              ? const Center(child: CircularProgressIndicator())
              : found.isEmpty
                  ? const Center(child: Text('None of your contacts use the app yet.'))
                  : ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('${found.length} of your contacts are here. They were added to your contacts list.',
                              style: const TextStyle(color: Brand.muted)),
                        ),
                        ...found.map((u) => ListTile(
                              leading: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute),
                              title: Text(u.name),
                              subtitle: Text(u.username != null ? '@${u.username}' : lastSeenText(u)),
                              onTap: () async {
                                try {
                                  final chat = await context.read<ChatStore>().openPrivateWith(u.id);
                                  if (context.mounted) {
                                    Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
                                  }
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                }
                              },
                            )),
                      ],
                    ),
    );
  }
}

// ================================================================== appearance
class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPrefs>();
    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(children: [
        ListTile(
          leading: const Icon(Icons.wallpaper_rounded),
          title: const Text('Chat theme & wallpaper'),
          subtitle: const Text('Colours, patterns or your own photo'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatThemeScreen())),
        ),
        const Divider(),
        const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('Theme', style: TextStyle(fontWeight: FontWeight.w600))),
        for (final m in ThemeMode.values)
          RadioListTile<ThemeMode>(
            value: m,
            groupValue: prefs.themeMode,
            title: Text(switch (m) { ThemeMode.system => 'Same as phone', ThemeMode.light => 'Light', ThemeMode.dark => 'Dark' }),
            onChanged: (v) => prefs.setThemeMode(v!),
          ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('Text size: ${(prefs.textScale * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        Slider(
          value: prefs.textScale,
          min: 0.85,
          max: 1.4,
          divisions: 11,
          label: '${(prefs.textScale * 100).round()}%',
          onChanged: prefs.setTextScale,
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('The quick brown fox jumps over the lazy dog.'),
        ),
      ]),
    );
  }
}

// ================================================================== app lock
class AppLockSettingsScreen extends StatelessWidget {
  const AppLockSettingsScreen({super.key});

  Future<String?> _askPin(BuildContext context, String title) async {
    final first = await _pinDialog(context, title);
    if (first == null || !context.mounted) return null;
    final second = await _pinDialog(context, 'Repeat the PIN');
    if (second != first) {
      if (context.mounted) showInfo(context, 'PINs did not match');
      return null;
    }
    return first;
  }

  Future<String?> _pinDialog(BuildContext context, String title) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(hintText: '4–6 digits'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.length >= 4 ? c.text : null), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPrefs>();
    return Scaffold(
      appBar: AppBar(title: const Text('App lock')),
      body: ListView(children: [
        SwitchListTile(
          title: const Text('Lock the app with a PIN'),
          subtitle: const Text('Asks for your PIN when you open the app'),
          value: prefs.lockEnabled,
          onChanged: (on) async {
            if (on) {
              final pin = await _askPin(context, 'Choose a PIN');
              if (pin != null) await prefs.enableLock(pin);
            } else {
              await prefs.disableLock();
            }
          },
        ),
        if (prefs.lockEnabled) ...[
          SwitchListTile(
            title: const Text('Unlock with fingerprint / face'),
            value: prefs.biometric,
            onChanged: (on) async {
              if (on) {
                final auth = LocalAuthentication();
                final can = await auth.canCheckBiometrics || await auth.isDeviceSupported();
                if (!can) {
                  if (context.mounted) showInfo(context, 'This phone has no fingerprint or face unlock set up');
                  return;
                }
              }
              prefs.setBiometric(on);
            },
          ),
          ListTile(
            title: const Text('Auto-lock'),
            subtitle: Text(prefs.lockAfterMinutes == 0 ? 'Immediately' : 'After ${prefs.lockAfterMinutes} min away'),
            onTap: () async {
              final v = await showDialog<int>(
                context: context,
                builder: (ctx) => SimpleDialog(
                  title: const Text('Auto-lock'),
                  children: [0, 1, 5, 60]
                      .map((m) => SimpleDialogOption(
                            onPressed: () => Navigator.pop(ctx, m),
                            child: Text(m == 0 ? 'Immediately' : (m == 60 ? 'After 1 hour' : 'After $m min')),
                          ))
                      .toList(),
                ),
              );
              if (v != null) prefs.setLockAfter(v);
            },
          ),
          ListTile(
            title: const Text('Change PIN'),
            onTap: () async {
              final pin = await _askPin(context, 'New PIN');
              if (pin != null) await prefs.enableLock(pin);
            },
          ),
        ],
      ]),
    );
  }
}

/// Full-screen lock shown over the app until the PIN / biometric check passes.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.onUnlocked});
  final VoidCallback onUnlocked;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  bool _wrong = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _biometric());
  }

  Future<void> _biometric() async {
    if (!context.read<AppPrefs>().biometric) return;
    try {
      final ok = await LocalAuthentication().authenticate(localizedReason: 'Unlock ${AppConfig.appName}');
      if (ok) widget.onUnlocked();
    } catch (_) {}
  }

  void _tap(String d) {
    if (_pin.length >= 6) return;
    setState(() {
      _pin += d;
      _wrong = false;
    });
    if (_pin.length >= 4 && context.read<AppPrefs>().checkPin(_pin)) {
      widget.onUnlocked();
    } else if (_pin.length == 6) {
      HapticFeedback.heavyImpact();
      setState(() {
        _pin = '';
        _wrong = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final biometric = context.watch<AppPrefs>().biometric;
    Widget key(String d) => Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: 72,
            height: 72,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(shape: const CircleBorder()),
              onPressed: () => _tap(d),
              child: Text(d, style: const TextStyle(fontSize: 26)),
            ),
          ),
        );
    return Scaffold(
      body: SafeArea(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const AppMascot(pose: TaviPose.hideEyes, size: 120),
          const SizedBox(height: 12),
          Text(_wrong ? 'Wrong PIN, try again' : 'Enter your PIN', style: TextStyle(fontSize: 18, color: _wrong ? Colors.red : null)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              6,
              (i) => Container(
                margin: const EdgeInsets.all(6),
                width: 14,
                height: 14,
                decoration: BoxDecoration(shape: BoxShape.circle, color: i < _pin.length ? Brand.primary : Colors.black12),
              ),
            ),
          ),
          const SizedBox(height: 24),
          for (final row in [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ])
            Row(mainAxisAlignment: MainAxisAlignment.center, children: row.map(key).toList()),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            SizedBox(
              width: 88,
              height: 88,
              child: biometric ? IconButton(icon: const Icon(Icons.fingerprint, size: 36), onPressed: _biometric) : null,
            ),
            key('0'),
            SizedBox(
              width: 88,
              height: 88,
              child: IconButton(
                icon: const Icon(Icons.backspace_outlined),
                onPressed: _pin.isEmpty ? null : () => setState(() => _pin = _pin.substring(0, _pin.length - 1)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ================================================================== data & storage
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  int? _size;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final s = await context.read<AppServices>().media.sizeBytes();
    if (mounted) setState(() => _size = s);
  }

  Future<void> _clear() async {
    if (!await confirm(context, 'Clear media cache?', 'Photos, videos and files will download again when you open them.', ok: 'Clear')) return;
    if (!mounted) return;
    await context.read<AppServices>().media.clear();
    await _measure();
    if (mounted) showInfo(context, 'Cache cleared');
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final data = await context.read<AppServices>().api.get('/me/export');
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/my-chatapp-data.json');
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      await OpenFilex.open(file.path);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data & storage')),
      body: ListView(children: [
        SwitchListTile(
          secondary: const Icon(Icons.data_saver_on_rounded),
          title: const Text('Data saver'),
          subtitle: const Text('For slow or costly internet: photos and videos load only when you tap, smaller photo uploads, no link-preview pictures, lower video-call quality.'),
          value: context.watch<AppPrefs>().dataSaver,
          onChanged: (v) => context.read<AppPrefs>().setDataSaver(v),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.sd_storage_outlined),
          title: const Text('Media cache'),
          subtitle: Text(_size == null ? 'Calculating…' : fileSize(_size!)),
          trailing: TextButton(onPressed: (_size ?? 0) == 0 ? null : _clear, child: const Text('Clear')),
        ),
        const Divider(),
        for (final (net, title, icon) in const [
          ('wifi', 'When on Wi-Fi', Icons.wifi_rounded),
          ('mobile', 'When using mobile data', Icons.signal_cellular_alt_rounded),
        ]) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary)),
            ]),
          ),
          for (final (kind, label) in const [('photos', 'Photos'), ('videos', 'Videos'), ('files', 'Files')])
            CheckboxListTile(
              dense: true,
              value: (net == 'wifi' ? context.watch<AppPrefs>().autoWifi : context.watch<AppPrefs>().autoMobile).contains(kind),
              title: Text(label),
              onChanged: (v) => context.read<AppPrefs>().setAutoDownload(net, kind, v ?? false),
            ),
        ],
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Voice messages always download. Videos over 100 MB and files over 50 MB wait for a tap.', style: TextStyle(fontSize: 12)),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('Download my data'),
          subtitle: const Text('Your profile, chats list and messages you sent, as a JSON file'),
          trailing: _exporting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
          onTap: _exporting ? null : _export,
        ),
      ]),
    );
  }
}

// ================================================================== terms / privacy / faq
class ContentPageScreen extends StatelessWidget {
  const ContentPageScreen({super.key, required this.slug, required this.fallbackTitle});
  final String slug;
  final String fallbackTitle;

  static const _icons = {
    'privacy': Icons.privacy_tip_rounded,
    'terms': Icons.gavel_rounded,
    'faq': Icons.quiz_rounded,
    'about': Icons.info_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(fallbackTitle)),
      body: FutureBuilder<dynamic>(
        future: context.read<AppServices>().api.get('/pages/$slug'),
        builder: (ctx, snap) {
          if (snap.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}', textAlign: TextAlign.center)));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final p = Map<String, dynamic>.from(snap.data as Map);
          return _ContentBody(title: '${p['title'] ?? fallbackTitle}', body: '${p['body'] ?? ''}', icon: _icons[slug] ?? Icons.article_rounded, faq: slug == 'faq');
        },
      ),
    );
  }
}

/// Renders the simple page format: "# Heading", "## Sub", "• bullet", "Q:"/"A:" pairs, paragraphs.
class _ContentBody extends StatefulWidget {
  const _ContentBody({required this.title, required this.body, required this.icon, required this.faq});
  final String title;
  final String body;
  final IconData icon;
  final bool faq;

  @override
  State<_ContentBody> createState() => _ContentBodyState();
}

class _ContentBodyState extends State<_ContentBody> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lines = widget.body.replaceAll('\r', '').split('\n');
    final out = <Widget>[];
    String? updated;
    final para = StringBuffer();
    void flush() {
      final t = para.toString().trim();
      para.clear();
      if (t.isEmpty || _q.isNotEmpty) return;
      out.add(Padding(padding: const EdgeInsets.only(bottom: 12), child: SelectableText(t, style: TextStyle(height: 1.55, fontSize: 14.5, color: scheme.onSurface))));
    }

    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].trimRight();
      final t = l.trim();
      if (t.isEmpty) {
        flush();
        continue;
      }
      if (t.startsWith('Last updated:')) {
        updated = t;
        continue;
      }
      if (t.startsWith('## ')) {
        flush();
        if (_q.isEmpty) out.add(Padding(padding: const EdgeInsets.fromLTRB(0, 6, 0, 6), child: Text(t.substring(3), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))));
        continue;
      }
      if (t.startsWith('# ')) {
        flush();
        if (_q.isEmpty) {
          out.add(Padding(
            padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
            child: Row(children: [
              Container(width: 4, height: 20, decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 10),
              Expanded(child: Text(t.substring(2), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.2))),
            ]),
          ));
        }
        continue;
      }
      if (t.startsWith('• ')) {
        flush();
        if (_q.isEmpty) {
          out.add(Padding(
            padding: const EdgeInsets.only(bottom: 7, left: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 8), child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: Brand.primary, shape: BoxShape.circle))),
              const SizedBox(width: 10),
              Expanded(child: SelectableText(t.substring(2), style: TextStyle(height: 1.5, fontSize: 14.5, color: scheme.onSurface))),
            ]),
          ));
        }
        continue;
      }
      if (t.startsWith('Q: ')) {
        flush();
        final q = t.substring(3);
        final a = StringBuffer();
        while (i + 1 < lines.length && !lines[i + 1].trim().startsWith('Q: ') && !lines[i + 1].trim().startsWith('# ')) {
          i++;
          final x = lines[i].trim();
          if (x.isEmpty) continue;
          a.writeln(x.startsWith('A: ') ? x.substring(3) : x);
        }
        final answer = a.toString().trim();
        if (_q.isNotEmpty && !'$q $answer'.toLowerCase().contains(_q)) continue;
        out.add(Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: dark ? Colors.white10 : const Color(0xFFE8EBF2)),
          ),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: _q.isNotEmpty,
              shape: const RoundedRectangleBorder(),
              tilePadding: const EdgeInsets.symmetric(horizontal: 14),
              childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              leading: const Icon(Icons.help_outline_rounded, color: Brand.primary),
              title: Text(q, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [SelectableText(answer, style: TextStyle(height: 1.5, color: scheme.onSurfaceVariant))],
            ),
          ),
        ));
        continue;
      }
      para.writeln(t);
    }
    flush();

    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(gradient: Brand.auroraSoft(dark), borderRadius: BorderRadius.circular(22)),
        child: Row(children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(15)),
            child: Icon(widget.icon, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              if (updated != null) ...[
                const SizedBox(height: 3),
                Text(updated, style: const TextStyle(fontSize: 12.5, color: Brand.muted)),
              ],
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      if (widget.faq)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            decoration: const InputDecoration(hintText: 'Search questions', prefixIcon: Icon(Icons.search_rounded), isDense: true),
          ),
        ),
      if (out.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(_q.isEmpty ? 'Nothing here yet.' : 'No matching questions.', textAlign: TextAlign.center)),
      ...out,
    ]);
  }
}

// ================================================================== ban appeal
/// Shown when login fails because the account is banned. Lets the user file an appeal.
Future<void> showBannedDialog(BuildContext context, ApiException e) async {
  final token = e.extra['appeal_token'] as String?;
  final appeal = e.extra['appeal'] is Map ? Map<String, dynamic>.from(e.extra['appeal'] as Map) : null;
  final until = e.extra['until'] as String?;
  final reason = e.extra['reason'] as String?;
  final pending = appeal?['status'] == 'pending';
  final text = TextEditingController();
  final api = context.read<AppServices>().api;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Account banned'),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (reason != null) Text('Reason: $reason'),
          Text(until == null ? 'This ban is permanent.' : 'Until ${DateTime.parse(until).toLocal().toString().substring(0, 16)}'),
          if (appeal != null) ...[
            const SizedBox(height: 12),
            Text('Your last appeal: ${appeal['status']}', style: const TextStyle(fontWeight: FontWeight.w600)),
            if (appeal['reply'] != null) Text('Moderators: ${appeal['reply']}'),
          ],
          if (token != null && !pending) ...[
            const SizedBox(height: 12),
            const Text('Think this is a mistake? Tell the moderators:'),
            TextField(controller: text, maxLines: 4, maxLength: 2000, decoration: const InputDecoration(hintText: 'Explain what happened')),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        if (token != null && !pending)
          FilledButton(
            onPressed: () async {
              try {
                await api.post('/appeals', {'appeal_token': token, 'message': text.text.trim()});
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) showInfo(context, 'Appeal sent. Try logging in again later.');
              } catch (err) {
                if (ctx.mounted) showError(ctx, err);
              }
            },
            child: const Text('Send appeal'),
          ),
      ],
    ),
  );
}
