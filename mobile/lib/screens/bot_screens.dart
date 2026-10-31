import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/chat_links.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/mascot.dart';
import '../widgets/premium.dart';
import 'chat_screen.dart';
import 'global_search_screen.dart';

/// Settings → My bots: create bots and get their Talvio Bot API token.
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

  Future<void> _openBotForge() async {
    final store = context.read<ChatStore>();
    try {
      final id = await store.botByUsername('BotForge');
      if (id == null) throw Exception();
      final chat = await store.openPrivateWith(id);
      if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
    } catch (_) {
      if (mounted) showInfo(context, 'BotForge isn’t available on this server yet');
    }
  }

  Widget _botFatherCard() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: _openBotForge,
            child: Ink(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(22)),
              child: Row(children: [
                const AppMascot(pose: TaviPose.think, size: 64),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('BotForge', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                    SizedBox(height: 3),
                    Text('Create and manage bots right in a chat: /newbot, /mybots, /setcommands…',
                        style: TextStyle(color: Colors.white, fontSize: 13)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final bots = _bots;
    return Scaffold(
      appBar: AppBar(title: const Text('My bots'), actions: [
        IconButton(
          tooltip: 'Discover bots',
          icon: const Icon(Icons.travel_explore_rounded),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GlobalSearchScreen(initialFilter: 'bots'))),
        ),
      ]),
      body: bots == null
          ? const Center(child: CircularProgressIndicator())
          : bots.isEmpty
              ? ListView(children: [
                  _botFatherCard(),
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Bots are programs that chat with people. Create one here or with BotForge, then use its key with the Talvio Bot API on your server.', textAlign: TextAlign.center),
                  ),
                ])
              : ListView(
                  children: [_botFatherCard(), SettingsGroup(title: 'Your bots', children: bots
                      .map<Widget>((b) => ListTile(
                            leading: Avatar(id: b.id, name: b.name, url: b.avatarAbsolute, size: 44, icon: b.avatarUrl == null ? Icons.smart_toy_rounded : null),
                            title: Text(b.name),
                            subtitle: Text('@${b.username}${b.status != 'active' ? ' · disabled' : ''}${b.webhookError != null ? ' · webhook error' : ''}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () async {
                              await Navigator.push(context, MaterialPageRoute(builder: (_) => BotEditScreen(bot: b)));
                              _load();
                            },
                          ))
                      .toList())],
                ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('New bot')),
    );
  }
}

Future<void> showTokenDialog(BuildContext context, String token) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Bot key'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Keep it secret — anyone with the key controls your bot. It is shown only now, copy it.'),
        const SizedBox(height: 10),
        SelectableText(token, style: const TextStyle(fontFamily: 'monospace')),
        const SizedBox(height: 10),
        Text('Talvio Bot API v2: POST ${AppConfig.serverUrl}/api/bots/v2/profile.get\nHeader: X-Bot-Key: <key>', style: const TextStyle(fontSize: 12)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: token));
            if (ctx.mounted) {
              Navigator.pop(ctx);
              showInfo(context, 'Key copied');
            }
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('Copy key'),
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
  late MyBot _bot = widget.bot;
  late final _name = TextEditingController(text: widget.bot.name);
  late final _about = TextEditingController(text: widget.bot.about);
  late final _menu = TextEditingController(text: widget.bot.menuUrl ?? '');
  late final _inline = TextEditingController(text: widget.bot.inlinePlaceholder ?? '');
  late final _commands = TextEditingController(
    text: widget.bot.commands.map((c) => '${c['command']} - ${c['description']}').join('\n'),
  );
  late bool _privacy = widget.bot.groupPrivacy;
  late bool _inlineOn = widget.bot.inlinePlaceholder != null;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _about, _menu, _inline, _commands]) {
      c.dispose();
    }
    super.dispose();
  }

  List<Map<String, String>> _parseCommands() => _commands.text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .map((l) {
        final i = l.indexOf(' - ');
        final cmd = (i < 0 ? l : l.substring(0, i)).trim().replaceFirst('/', '');
        return {'command': cmd, 'description': i < 0 ? cmd : l.substring(i + 3).trim()};
      })
      .toList();

  Future<void> _patch(Map<String, dynamic> body, {String? ok}) async {
    try {
      final r = await context.read<AppServices>().api.patch('/bots/${_bot.id}', body);
      if (!mounted) return;
      setState(() => _bot = MyBot.fromJson(Map<String, dynamic>.from(r as Map)));
      if (ok != null) showInfo(context, ok);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      showInfo(context, 'The bot needs a name');
      return;
    }
    final menu = _menu.text.trim();
    if (menu.isNotEmpty && !menu.startsWith('https://')) {
      showInfo(context, 'The mini app address must start with https://');
      return;
    }
    setState(() => _saving = true);
    await _patch({
      'name': _name.text.trim(),
      'about': _about.text.trim(),
      'commands': _parseCommands(),
      'menu_url': menu.isEmpty ? null : menu,
      'group_privacy': _privacy,
      'inline_placeholder': _inlineOn ? (_inline.text.trim().isEmpty ? 'Search…' : _inline.text.trim()) : null,
    }, ok: 'Saved');
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _photo() async {
    final a = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_library_rounded), title: const Text('Choose photo'), onTap: () => Navigator.pop(ctx, 'pick')),
          if (_bot.avatarUrl != null)
            ListTile(leading: const Icon(Icons.delete_outline_rounded, color: Colors.red), title: const Text('Remove photo', style: TextStyle(color: Colors.red)), onTap: () => Navigator.pop(ctx, 'remove')),
        ]),
      ),
    );
    if (a == null || !mounted) return;
    if (a == 'remove') return _patch({'avatar_media_id': null}, ok: 'Photo removed');
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
    if (x == null || !mounted) return;
    try {
      final m = await context.read<AppServices>().api.upload(x.path, kind: 'avatar');
      await _patch({'avatar_media_id': m['id']}, ok: 'Photo updated');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _openChat() async {
    final store = context.read<ChatStore>();
    try {
      final chat = await store.openPrivateWith(_bot.id);
      if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _newKey() async {
    if (!await confirm(context, 'Create a new key?', 'The old key stops working right away. Put the new key in your bot’s code.', ok: 'Create')) return;
    if (!mounted) return;
    try {
      final r = await context.read<AppServices>().api.post('/bots/${_bot.id}/token') as Map;
      if (mounted) await showTokenDialog(context, '${r['token']}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _field(TextEditingController c, String label, {String? hint, int maxLines = 1, int? maxLength, TextInputType? type, String? helper}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: TextField(
          controller: c,
          maxLines: maxLines,
          maxLength: maxLength,
          keyboardType: type,
          decoration: InputDecoration(labelText: label, hintText: hint, helperText: helper, helperMaxLines: 2, alignLabelWithHint: maxLines > 1),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final b = _bot;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final link = publicChatLink(b.username);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit bot'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        const SizedBox(height: 8),
        Center(
          child: GestureDetector(
            onTap: _photo,
            child: Stack(clipBehavior: Clip.none, children: [
              Avatar(id: b.id, name: b.name, url: b.avatarAbsolute, size: 92, icon: b.avatarUrl == null ? Icons.smart_toy_rounded : null),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 3)),
                  child: const Icon(Icons.photo_camera_rounded, size: 16, color: Colors.white),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        Center(child: Text(b.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
        const SizedBox(height: 2),
        Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('@${b.username}', style: const TextStyle(color: Brand.muted)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: (b.status == 'active' ? Brand.green : const Color(0xFFE5484D)).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(b.status == 'active' ? 'Active' : 'Disabled',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: b.status == 'active' ? Brand.green : const Color(0xFFE5484D))),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            for (final (icon, label, fn) in [
              (Icons.chat_bubble_rounded, 'Open chat', _openChat),
              (Icons.link_rounded, 'Copy link', () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (mounted) showInfo(context, 'Link copied');
              }),
              (Icons.key_rounded, 'New key', _newKey),
            ])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Material(
                    color: dark ? Colors.white.withValues(alpha: 0.06) : Brand.primary.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: fn,
                      child: SizedBox(
                        height: 62,
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(icon, color: Brand.primary, size: 22),
                          const SizedBox(height: 4),
                          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        SettingsGroup(title: 'Profile', children: [
          _field(_name, 'Name', maxLength: 64),
          _field(_about, 'About', hint: 'What your bot does', helper: 'People see this before they press Start', maxLines: 3, maxLength: 512),
        ]),
        SettingsGroup(title: 'Commands', children: [
          _field(_commands, 'One per line', hint: 'start - Start the bot\nhelp - What I can do', maxLines: 6, helper: 'People see them in the / menu of the chat'),
        ]),
        SettingsGroup(title: 'Features', children: [
          SettingsSwitchTile(
            icon: Icons.manage_search_rounded,
            color: Brand.violet,
            title: 'Inline mode',
            subtitle: 'People type @${b.username} in any chat to use it',
            value: _inlineOn,
            onChanged: (v) => setState(() => _inlineOn = v),
          ),
          if (_inlineOn) _field(_inline, 'Placeholder', hint: 'Search…', maxLength: 64),
          SettingsSwitchTile(
            icon: Icons.groups_rounded,
            color: Brand.sky,
            title: 'Group privacy',
            subtitle: 'In groups, only see /commands, @mentions and replies',
            value: _privacy,
            onChanged: (v) => setState(() => _privacy = v),
          ),
          _field(_menu, 'Mini app address (optional)', hint: 'https://…', type: TextInputType.url),
        ]),
        SettingsGroup(title: 'Connection', children: [
          SettingsTile(
            icon: b.webhookUrl == null ? Icons.sync_rounded : (b.webhookError == null ? Icons.cloud_done_rounded : Icons.cloud_off_rounded),
            color: b.webhookUrl == null ? Brand.sky : (b.webhookError == null ? Brand.green : const Color(0xFFE5484D)),
            title: b.webhookUrl == null ? 'Getting updates by polling' : (b.webhookError == null ? 'Webhook is working' : 'Webhook error'),
            subtitle: b.webhookUrl == null ? 'Your server calls events.poll' : (b.webhookError ?? b.webhookUrl),
            maxSubtitleLines: 2,
            trailingWidget: b.webhookUrl == null
                ? null
                : TextButton(
                    onPressed: () async {
                      if (await confirm(context, 'Remove the webhook?', 'Events will wait until your server calls events.poll.', ok: 'Remove')) {
                        await _patch({'remove_webhook': true}, ok: 'Webhook removed');
                      }
                    },
                    child: const Text('Remove'),
                  ),
          ),
          SettingsTile(icon: Icons.inbox_rounded, color: Brand.amber, title: 'Events waiting', trailing: '${b.pendingUpdates}'),
          SettingsTile(
            icon: Icons.menu_book_rounded,
            color: Brand.primary,
            title: 'Talvio Bot API',
            subtitle: 'POST ${AppConfig.serverUrl}/api/bots/v2/<method> · header X-Bot-Key',
            maxSubtitleLines: 2,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: '${AppConfig.serverUrl}/api/bots/v2/'));
              if (mounted) showInfo(context, 'API address copied');
            },
          ),
        ]),
        SettingsGroup(children: [
          SettingsTile(
            icon: Icons.delete_outline_rounded,
            color: const Color(0xFFE5484D),
            title: 'Delete bot',
            danger: true,
            onTap: () async {
              if (!await confirm(context, 'Delete @${b.username}?', 'The bot stops working and its username is freed. This can’t be undone.', ok: 'Delete', danger: true)) return;
              if (!mounted) return;
              try {
                await context.read<AppServices>().api.delete('/bots/${b.id}');
                if (mounted) Navigator.pop(context);
              } catch (e) {
                if (mounted) showError(context, e);
              }
            },
          ),
        ]),
      ]),
    );
  }
}
