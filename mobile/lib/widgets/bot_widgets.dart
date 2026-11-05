import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/chat_links.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../theme/brand.dart';
import '../utils/format.dart';

/// Inline buttons under a bot's message.
class InlineKeyboard extends StatelessWidget {
  const InlineKeyboard({super.key, required this.message, required this.botId, this.botName = 'Bot'});
  final Message message;
  final int? botId;
  final String botName;

  Future<void> _press(BuildContext context, Map<String, dynamic> b) async {
    final copy = b['copy_text'];
    if (copy is Map && copy['text'] != null) {
      await Clipboard.setData(ClipboardData(text: '${copy['text']}'));
      if (context.mounted) showInfo(context, 'Copied to clipboard');
      return;
    }
    final services = context.read<AppServices>();
    if (b['url'] != null) {
      final url = '${b['url']}';
      HapticFeedback.selectionClick();
      // Hushavia links (channels, groups, invites, bots) open right here in the app; others in the browser
      if (await openChatLink(context, url)) return;
      final uri = Uri.tryParse(url);
      if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    final web = b['web_app'];
    if (web is Map && botId != null) {
      if (!context.mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => MiniAppScreen(botId: botId!, url: '${web['url']}', title: botName)));
      return;
    }
    if (b.containsKey('switch_inline_query')) {
      // "share via the bot": hand the text over so it can be pasted into any chat
      await Clipboard.setData(ClipboardData(text: '${b['switch_inline_query'] ?? ''}'));
      if (context.mounted) showInfo(context, 'Copied — paste it in any chat');
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
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              for (final (i, b) in row.indexed) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(child: _KeyButton(data: b, onTap: () => _press(context, b))),
              ],
            ]),
          ),
      ]),
    );
  }
}

/// One button under a message: a soft violet tile with the action's small mark (link, copy, app…).
class _KeyButton extends StatefulWidget {
  const _KeyButton({required this.data, required this.onTap});
  final Map<String, dynamic> data;
  final VoidCallback onTap;

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final b = widget.data;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? const Color(0xFFCBBEFF) : Brand.primary;
    final IconData? mark = b['url'] != null
        ? Icons.arrow_outward_rounded
        : b['copy_text'] != null
            ? Icons.content_copy_rounded
            : b['web_app'] != null
                ? Icons.grid_view_rounded
                : b.containsKey('switch_inline_query')
                    ? Icons.ios_share_rounded
                    : null;
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 90),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minHeight: 42),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: _down
                ? Brand.primary.withValues(alpha: dark ? 0.34 : 0.18)
                : (dark ? Brand.primary.withValues(alpha: 0.22) : Brand.primary.withValues(alpha: 0.09)),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Brand.primary.withValues(alpha: dark ? 0.35 : 0.18), width: 0.8),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Flexible(
              child: Text('${b['text']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 14.5, letterSpacing: -0.1)),
            ),
            if (mark != null) ...[const SizedBox(width: 5), Icon(mark, size: 14, color: fg.withValues(alpha: 0.75))],
          ]),
        ),
      ),
    );
  }
}

/// A bot's mini app (web page) inside the app. The page gets signed user data in
/// `location.hash` (#hushaviaData=…) and `window.Hushavia`: { initData, user, close(), sendData(text) }.
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
      final target = uri.replace(fragment: 'hushaviaData=${Uri.encodeComponent(init)}');
      final js = 'window.Hushavia = { initData: ${jsonEncode(init)}, user: ${jsonEncode(Uri.splitQueryString(init)['user'] ?? '{}')}, '
          'close: function(){ HushaviaBridge.postMessage(JSON.stringify({type:"close"})); }, '
          'sendData: function(d){ HushaviaBridge.postMessage(JSON.stringify({type:"send_data", data: String(d)})); } }; '
          'try { window.Hushavia.user = JSON.parse(window.Hushavia.user); } catch(e) {} '
          'window.dispatchEvent(new Event("chatappready"));';
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel('HushaviaBridge', onMessageReceived: (msg) => _onBridge(msg.message))
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


/// Compact "menu" button next to the message box in bot chats (commands or the mini app).
class BotMenuButton extends StatelessWidget {
  const BotMenuButton({super.key, required this.onTap, this.onLongPress, this.hasApp = false});
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool hasApp;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: hasApp ? 'Open app (hold for commands)' : 'Bot commands',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Ink(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle),
            child: Icon(hasApp ? Icons.grid_view_rounded : Icons.menu_rounded, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}

/// A bot's reply keyboard: rows of large buttons shown under the message box.
class BotReplyKeyboard extends StatelessWidget {
  const BotReplyKeyboard({super.key, required this.markup, required this.onPressed});
  final Map<String, dynamic> markup;
  final ValueChanged<Map<String, dynamic>> onPressed;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final rows = (markup['keyboard'] as List)
        .whereType<List>()
        .map((r) => r.map((b) => b is Map ? Map<String, dynamic>.from(b) : <String, dynamic>{'text': '$b'}).toList())
        .toList();
    final big = markup['resize_keyboard'] == false;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.36),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF151929).withValues(alpha: 0.94) : const Color(0xFFEFF1F7).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(18),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in rows)
                Row(children: [
                  for (final b in row)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Material(
                          color: dark ? const Color(0xFF242A42) : Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          elevation: 0.5,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => onPressed(b),
                            child: SizedBox(
                              height: big ? 56 : 44,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    if (b['request_location'] == true) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.location_on_rounded, size: 16, color: Brand.primary)),
                                    Flexible(
                                      child: Text(
                                        '${b['text']}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5, color: dark ? Colors.white : const Color(0xFF1B1F33)),
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ]),
            ],
          ),
        ),
      ),
    );
  }
}
