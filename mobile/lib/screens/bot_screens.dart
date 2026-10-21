import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../utils/format.dart';

/// Settings → My bots: create bots and get their Bot API token (like BotFather).
class MyBotsScreen extends StatefulWidget {
  const MyBotsScreen({super.key});

  @override
  State<MyBotsScreen> createState() => _MyBotsScreenState();
}

class _MyBotsScreenState extends State<MyBotsScreen> {
  List<MyBot>? _bots;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppServices>().api.get('/bots') as List;
      if (mounted) setState(() => _bots = r.map((j) => MyBot.fromJson(Map<String, dynamic>.from(j as Map))).toList());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _create() async {
    final name = TextEditingController();
    final username = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New bot'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, maxLength: 64, decoration: const InputDecoration(labelText: 'Name', hintText: 'Weather Helper')),
          TextField(controller: username, maxLength: 32, decoration: const InputDecoration(labelText: 'Username', prefixText: '@', hintText: 'weather_helper_bot')),
          const Text('The username must end with “bot”.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.post('/bots', {
        'name': name.text.trim(),
        'username': username.text.trim().replaceFirst('@', ''),
      }) as Map);
      if (!mounted) return;
      await showTokenDialog(context, '${r['token']}');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bots = _bots;
    return Scaffold(
      appBar: AppBar(title: const Text('My bots')),
      body: bots == null
          ? const Center(child: CircularProgressIndicator())
          : bots.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Bots are programs that chat with people. Create one, then use its token with the Bot API on your server.', textAlign: TextAlign.center),
                  ),
                )
              : ListView(
                  children: bots
                      .map((b) => ListTile(
                            leading: const CircleAvatar(child: Icon(Icons.smart_toy_outlined)),
                            title: Text(b.name),
                            subtitle: Text('@${b.username}${b.status != 'active' ? ' · disabled' : ''}${b.webhookError != null ? ' · webhook error' : ''}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () async {
                              await Navigator.push(context, MaterialPageRoute(builder: (_) => BotEditScreen(bot: b)));
                              _load();
                            },
                          ))
                      .toList(),
                ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('New bot')),
    );
  }
}

Future<void> showTokenDialog(BuildContext context, String token) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Bot token'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Keep it secret — anyone with the token controls your bot. It is shown only now.'),
        const SizedBox(height: 10),
        SelectableText(token, style: const TextStyle(fontFamily: 'monospace')),
        const SizedBox(height: 10),
        Text('API: ${AppConfig.serverUrl}/bot<token>/getMe', style: const TextStyle(fontSize: 12)),
      ]),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: token));
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('Copy & close'),
        ),
      ],
    ),
  );
}

class BotEditScreen extends StatefulWidget {
  const BotEditScreen({super.key, required this.bot});
  final MyBot bot;

  @override
  State<BotEditScreen> createState() => _BotEditScreenState();
}

class _BotEditScreenState extends State<BotEditScreen> {
  late final _name = TextEditingController(text: widget.bot.name);
  late final _about = TextEditingController(text: widget.bot.about);
  late final _menu = TextEditingController(text: widget.bot.menuUrl ?? '');
  late final _commands = TextEditingController(
    text: widget.bot.commands.map((c) => '${c['command']} - ${c['description']}').join('\n'),
  );
  late bool _privacy = widget.bot.groupPrivacy;
  bool _saving = false;

  Future<void> _save() async {
    final cmds = _commands.text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .map((l) {
          final i = l.indexOf(' - ');
          return i < 0 ? {'command': l, 'description': l} : {'command': l.substring(0, i).trim(), 'description': l.substring(i + 3).trim()};
        })
        .toList();
    setState(() => _saving = true);
    try {
      await context.read<AppServices>().api.patch('/bots/${widget.bot.id}', {
        'name': _name.text.trim(),
        'about': _about.text.trim(),
        'commands': cmds,
        'menu_url': _menu.text.trim().isEmpty ? null : _menu.text.trim(),
        'group_privacy': _privacy,
      });
      if (mounted) {
        showInfo(context, 'Saved');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bot;
    final api = context.read<AppServices>().api;
    return Scaffold(
      appBar: AppBar(
        title: Text('@${b.username}'),
        actions: [TextButton(onPressed: _saving ? null : _save, child: const Text('Save'))],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, maxLength: 64, decoration: const InputDecoration(labelText: 'Name')),
        TextField(controller: _about, maxLength: 512, maxLines: 3, decoration: const InputDecoration(labelText: 'About (shown before people press START)')),
        TextField(
          controller: _commands,
          maxLines: 6,
          decoration: const InputDecoration(labelText: 'Commands', hintText: 'start - Start the bot\nhelp - What I can do', alignLabelWithHint: true),
        ),
        const SizedBox(height: 8),
        TextField(controller: _menu, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Mini app URL (optional, https://)')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Group privacy'),
          subtitle: const Text('In groups, only receive /commands, @mentions and replies'),
          value: _privacy,
          onChanged: (v) => setState(() => _privacy = v),
        ),
        if (b.webhookUrl != null) ListTile(contentPadding: EdgeInsets.zero, title: const Text('Webhook'), subtitle: Text(b.webhookError ?? b.webhookUrl!)),
        ListTile(contentPadding: EdgeInsets.zero, title: const Text('Updates waiting'), trailing: Text('${b.pendingUpdates}')),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.key_outlined),
          title: const Text('New token'),
          subtitle: const Text('The old token stops working'),
          onTap: () async {
            if (!await confirm(context, 'Create a new token?', 'Your bot stops working until you put the new token in your code.', ok: 'Create')) return;
            try {
              final r = await api.post('/bots/${b.id}/token') as Map;
              if (context.mounted) await showTokenDialog(context, '${r['token']}');
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.delete_outline, color: Colors.red),
          title: const Text('Delete bot', style: TextStyle(color: Colors.red)),
          onTap: () async {
            if (!await confirm(context, 'Delete @${b.username}?', 'This can’t be undone.', ok: 'Delete', danger: true)) return;
            try {
              await api.delete('/bots/${b.id}');
              if (context.mounted) Navigator.pop(context);
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
        ),
      ]),
    );
  }
}
