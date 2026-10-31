import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/proxy.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/premium.dart';

/// Settings → Proxy: keep a list of proxies, pick one, see how fast each is, share them as links.
class ProxySettingsScreen extends StatefulWidget {
  const ProxySettingsScreen({super.key});

  @override
  State<ProxySettingsScreen> createState() => _ProxySettingsScreenState();
}

class _ProxySettingsScreenState extends State<ProxySettingsScreen> {
  @override
  void initState() {
    super.initState();
    ProxyManager.instance.checkAll();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final p = ProxyServer.fromLink(data?.text ?? '');
    if (!mounted) return;
    if (p == null) {
      showInfo(context, 'No proxy link on the clipboard');
      return;
    }
    await confirmAddProxy(context, p);
  }

  @override
  Widget build(BuildContext context) {
    final pm = context.watch<ProxyManager>();
    return Scaffold(
      appBar: AppBar(title: const Text('Proxy'), actions: [
        IconButton(tooltip: 'Check all', icon: const Icon(Icons.speed_rounded), onPressed: pm.servers.isEmpty ? null : pm.checkAll),
      ]),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        SettingsGroup(children: [
          SettingsSwitchTile(
            icon: Icons.vpn_lock_rounded,
            color: Brand.primary,
            title: 'Use proxy',
            subtitle: pm.servers.isEmpty
                ? 'Tap to add a proxy'
                : pm.enabled
                    ? 'Connected through ${pm.active?.label ?? 'a proxy'}'
                    : 'Talvio connects directly',
            value: pm.enabled,
            onChanged: (v) async {
              if (pm.servers.isEmpty) {
                if (v) await editProxy(context); // nothing to use yet: add one (it turns on when saved)
                return;
              }
              await pm.setEnabled(v);
            },
          ),
        ]),
        SettingsGroup(title: 'Proxies', children: [
          for (final s in pm.servers) _tile(context, pm, s),
          SettingsTile(
            icon: Icons.add_rounded,
            color: Brand.green,
            title: 'Add proxy',
            onTap: () => editProxy(context),
          ),
          SettingsTile(
            icon: Icons.content_paste_rounded,
            color: Brand.sky,
            title: 'Paste proxy link',
            subtitle: 'talvio://proxy?… or socks5://…',
            onTap: _paste,
          ),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Text(
            'A proxy helps when Talvio is slow or blocked on your network. All your messages, calls signalling, photos '
            'and files go through it. Only use proxies you trust — the owner can see when and how much you connect '
            '(not what you write in secret chats). If some photos don’t load right after switching, reopen the app.',
            style: TextStyle(color: Brand.muted, fontSize: 12.5),
          ),
        ),
      ]),
    );
  }

  Widget _tile(BuildContext context, ProxyManager pm, ProxyServer s) {
    final selected = pm.enabled && pm.activeId == s.id;
    final ms = pm.pings[s.id];
    final checking = pm.checking.contains(s.id);
    final status = checking
        ? 'Checking…'
        : !pm.pings.containsKey(s.id)
            ? s.typeLabel
            : ms == null
                ? 'Unavailable'
                : '${s.typeLabel} · Available, ping $ms ms';
    final color = checking || !pm.pings.containsKey(s.id) ? Brand.muted : (ms == null ? const Color(0xFFE5484D) : Brand.green);
    return ListTile(
      leading: Radio<bool>(value: true, groupValue: selected, onChanged: (_) => pm.use(s)), // ignore: deprecated_member_use
      title: Text(s.label, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(status, style: TextStyle(color: color, fontSize: 13)),
      onTap: () => pm.use(s),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          switch (v) {
            case 'share':
              await Clipboard.setData(ClipboardData(text: s.link));
              if (context.mounted) showInfo(context, 'Proxy link copied');
            case 'edit':
              await editProxy(context, existing: s);
            case 'check':
              await pm.check(s);
            case 'delete':
              await pm.remove(s);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'share', child: Text('Copy link')),
          PopupMenuItem(value: 'check', child: Text('Check')),
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

/// Add or edit a proxy.
Future<void> editProxy(BuildContext context, {ProxyServer? existing}) async {
  final host = TextEditingController(text: existing?.host ?? '');
  final port = TextEditingController(text: existing == null ? '' : '${existing.port}');
  final user = TextEditingController(text: existing?.username ?? '');
  final pass = TextEditingController(text: existing?.password ?? '');
  final name = TextEditingController(text: existing?.name ?? '');
  var type = existing?.type ?? 'socks5';
  final result = await showModalBottomSheet<ProxyServer>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text(existing == null ? 'Add proxy' : 'Edit proxy', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'socks5', label: Text('SOCKS5'), icon: Icon(Icons.lan_rounded)),
                ButtonSegment(value: 'http', label: Text('HTTP'), icon: Icon(Icons.http_rounded)),
              ],
              selected: {type},
              onSelectionChanged: (v) => setSheet(() => type = v.first),
            ),
            const SizedBox(height: 14),
            TextField(controller: host, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Server', hintText: 'proxy.example.com or 1.2.3.4')),
            const SizedBox(height: 10),
            TextField(controller: port, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Port', hintText: '1080')),
            const SizedBox(height: 10),
            TextField(controller: user, decoration: const InputDecoration(labelText: 'Username (optional)')),
            const SizedBox(height: 10),
            TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password (optional)')),
            const SizedBox(height: 10),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (optional)', hintText: 'Office proxy')),
            const SizedBox(height: 18),
            AuroraButton(
              label: 'Save and connect',
              icon: Icons.check_rounded,
              onPressed: () {
                final p = int.tryParse(port.text.trim());
                if (host.text.trim().isEmpty || p == null || p <= 0 || p > 65535) {
                  showInfo(ctx, 'Enter the server and a port (1–65535)');
                  return;
                }
                Navigator.pop(
                  ctx,
                  ProxyServer(type: type, host: host.text.trim(), port: p, username: user.text.trim(), password: pass.text, name: name.text.trim()),
                );
              },
            ),
          ]),
        ),
      ),
    ),
  );
  if (result == null) return;
  final pm = ProxyManager.instance;
  if (existing != null) await pm.remove(existing);
  await pm.add(result);
}

/// Someone opened a proxy link: show the details and ask before connecting.
Future<void> confirmAddProxy(BuildContext context, ProxyServer p) async {
  final pm = ProxyManager.instance;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Icon(Icons.vpn_lock_rounded, size: 44, color: Brand.primary),
          const SizedBox(height: 8),
          const Text('Proxy server', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          _row('Server', p.host),
          _row('Port', '${p.port}'),
          _row('Type', p.typeLabel),
          if (p.username.isNotEmpty) _row('Username', p.username),
          if (p.password.isNotEmpty) _row('Password', '••••••'),
          const SizedBox(height: 10),
          const Text('Only connect to proxies you trust.', textAlign: TextAlign.center, style: TextStyle(color: Brand.muted, fontSize: 12.5)),
          const SizedBox(height: 14),
          AuroraButton(label: 'Connect proxy', icon: Icons.link_rounded, onPressed: () => Navigator.pop(ctx, true)),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ]),
      ),
    ),
  );
  if (ok == true) {
    await pm.add(p);
    if (context.mounted) showInfo(context, 'Proxy connected');
  }
}

Widget _row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 90, child: Text(k, style: const TextStyle(color: Brand.muted))),
        Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
      ]),
    );
