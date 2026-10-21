import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../utils/format.dart';

/// Inline buttons under a bot's message.
class InlineKeyboard extends StatelessWidget {
  const InlineKeyboard({super.key, required this.message, required this.botId, this.botName = 'Bot'});
  final Message message;
  final int? botId;
  final String botName;

  Future<void> _press(BuildContext context, Map<String, dynamic> b) async {
    final services = context.read<AppServices>();
    if (b['url'] != null) {
      final ok = await confirm(context, 'Open link?', '${b['url']}', ok: 'Open');
      if (ok) launchUrl(Uri.parse('${b['url']}'), mode: LaunchMode.externalApplication);
      return;
    }
    final web = b['web_app'];
    if (web is Map && botId != null) {
      if (!context.mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => MiniAppScreen(botId: botId!, url: '${web['url']}', title: botName)));
      return;
    }
    final data = b['callback_data'];
    if (data == null) return;
    try {
      final r = await services.api.post('/messages/${message.id}/callback', {'data': data}) as Map;
      final qid = '${r['callback_query_id']}';
      // wait (briefly) for the bot's answer
      final answer = await services.socket.events
          .where((e) => e.name == 'bot:callback_answer' && '${e.data['callback_query_id']}' == qid)
          .map((e) => e.data)
          .first
          .timeout(const Duration(seconds: 12), onTimeout: () => <String, dynamic>{});
      if (!context.mounted) return;
      final text = '${answer['text'] ?? ''}';
      if (answer['url'] != null) launchUrl(Uri.parse('${answer['url']}'), mode: LaunchMode.externalApplication);
      if (text.isEmpty) return;
      if (answer['show_alert'] == true) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(content: Text(text), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))]),
        );
      } else {
        showInfo(context, text);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = message.inlineKeyboard;
    if (rows.isEmpty) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        children: rows
            .map((row) => Row(
                  children: row
                      .map((b) => Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: Theme.of(context).colorScheme.surface.withAlpha(200),
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                onPressed: () => _press(context, b),
                                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                  Flexible(child: Text('${b['text']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: accent))),
                                  if (b['url'] != null) Icon(Icons.north_east, size: 12, color: accent),
                                  if (b['web_app'] != null) Icon(Icons.apps, size: 12, color: accent),
                                ]),
                              ),
                            ),
                          ))
                      .toList(),
                ))
            .toList(),
      ),
    );
  }
}

/// A bot's mini app (web page) inside the app. The page gets signed user data in
/// `location.hash` (#chatAppData=…) and `window.ChatApp`: { initData, user, close(), sendData(text) }.
class MiniAppScreen extends StatefulWidget {
  const MiniAppScreen({super.key, required this.botId, required this.url, required this.title});
  final int botId;
  final String url;
  final String title;

  @override
  State<MiniAppScreen> createState() => _MiniAppScreenState();
}

class _MiniAppScreenState extends State<MiniAppScreen> {
  WebViewController? _controller;
  String? _error;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final api = context.read<AppServices>().api;
    try {
      final r = Map<String, dynamic>.from(await api.post('/bots/${widget.botId}/web-app', {}) as Map);
      final init = '${r['init_data']}';
      final uri = Uri.parse(widget.url);
      if (uri.scheme != 'https' && uri.scheme != 'http') throw const FormatException('bad url');
      final target = uri.replace(fragment: 'chatAppData=${Uri.encodeComponent(init)}');
      final js = 'window.ChatApp = { initData: ${jsonEncode(init)}, user: ${jsonEncode(Uri.splitQueryString(init)['user'] ?? '{}')}, '
          'close: function(){ ChatAppBridge.postMessage(JSON.stringify({type:"close"})); }, '
          'sendData: function(d){ ChatAppBridge.postMessage(JSON.stringify({type:"send_data", data: String(d)})); } }; '
          'try { window.ChatApp.user = JSON.parse(window.ChatApp.user); } catch(e) {} '
          'window.dispatchEvent(new Event("chatappready"));';
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel('ChatAppBridge', onMessageReceived: (msg) => _onBridge(msg.message))
        ..setNavigationDelegate(NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageFinished: (_) => _controller?.runJavaScript(js),
        ))
        ..loadRequest(target);
      if (mounted) setState(() => _controller = c);
    } catch (e) {
      if (mounted) setState(() => _error = 'This app could not be opened');
    }
  }

  Future<void> _onBridge(String raw) async {
    Map<String, dynamic> m;
    try {
      m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (m['type'] == 'close') {
      Navigator.pop(context);
    } else if (m['type'] == 'send_data') {
      try {
        await context.read<AppServices>().api.post('/bots/${widget.botId}/web-app-data', {'data': '${m['data']}', 'button_text': widget.title});
        if (mounted) Navigator.pop(context);
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () => _controller?.reload())],
        bottom: _progress > 0 && _progress < 100
            ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: _progress / 100))
            : null,
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : _controller == null
              ? const Center(child: CircularProgressIndicator())
              : WebViewWidget(controller: _controller!),
    );
  }
}

/// Shown in an empty chat with a bot: what it does + START.
class BotIntro extends StatelessWidget {
  const BotIntro({super.key, required this.chat, required this.onStart});
  final Chat chat;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final about = chat.bot?.about ?? '';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.smart_toy_outlined, size: 56),
          const SizedBox(height: 12),
          Text(chat.title, style: Theme.of(context).textTheme.titleLarge),
          if (about.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(about, textAlign: TextAlign.center)),
          const SizedBox(height: 16),
          FilledButton(onPressed: onStart, child: const Text('START')),
        ]),
      ),
    );
  }
}

/// "/" menu: the bot's commands.
Future<String?> pickBotCommand(BuildContext context, BotInfo bot) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: bot.commands
            .map((c) => ListTile(
                  leading: const Icon(Icons.terminal),
                  title: Text('/${c.$1}'),
                  subtitle: Text(c.$2),
                  onTap: () => Navigator.pop(ctx, '/${c.$1}'),
                ))
            .toList(),
      ),
    ),
  );
}
