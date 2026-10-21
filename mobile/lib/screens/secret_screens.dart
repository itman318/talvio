import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:no_screenshot/no_screenshot.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../core/e2e.dart';
import '../models/models.dart';
import '../state/secret_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/extras.dart';
import '../theme/brand.dart';

const _green = Brand.accent;

/// Opens (or starts) a secret chat with [user].
Future<void> startSecretChat(BuildContext context, AppUser user) async {
  final store = context.read<SecretStore>();
  final existing = store.sortedChats.where((c) => c.peerId == user.id && c.status != 'closed').toList();
  if (existing.isNotEmpty) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => SecretChatScreen(chatId: existing.first.id)));
    return;
  }
  final ok = await confirm(
    context,
    'Start a secret chat?',
    'Messages are end-to-end encrypted and live only on this phone and ${user.firstName}’s phone. '
        'Nobody else — not even the server — can read them. They can’t be forwarded, and screenshots are blocked.',
    ok: 'Start',
  );
  if (!ok || !context.mounted) return;
  try {
    final c = await store.create(user);
    if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => SecretChatScreen(chatId: c.id)));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Row in the chat list.
class SecretChatTile extends StatelessWidget {
  const SecretChatTile({super.key, required this.chat});
  final SecretChat chat;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SecretStore>();
    final last = (store.messages[chat.id] ?? const <SecretMessage>[]).cast<SecretMessage?>().firstWhere((m) => m != null && !m.isService, orElse: () => null);
    final sub = chat.status == 'requested'
        ? 'Waiting for ${chat.peer?.firstName ?? 'them'} to come online…'
        : chat.status == 'closed'
            ? 'Secret chat closed'
            : store.isTyping(chat.id)
                ? 'typing…'
                : (last?.preview ?? 'Secret chat started');
    return ListTile(
      leading: Avatar(id: chat.peerId, name: chat.title, url: chat.peer?.avatarAbsolute, size: 52),
      title: Row(children: [
        const Icon(Icons.lock, size: 16, color: _green),
        const SizedBox(width: 4),
        Flexible(child: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _green, fontWeight: FontWeight.w600))),
      ]),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(chatListTime(chat.lastActivity), style: const TextStyle(fontSize: 12)),
        if (chat.unread > 0)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: _green, borderRadius: BorderRadius.circular(10)),
            child: Text('${chat.unread}', style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
      ]),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SecretChatScreen(chatId: chat.id))),
      onLongPress: () async {
        if (await confirm(context, 'Delete secret chat?', 'It will be closed for both of you and deleted from this phone.', ok: 'Delete', danger: true)) {
          store.closeAndDelete(chat.id);
        }
      },
    );
  }
}

class SecretChatScreen extends StatefulWidget {
  const SecretChatScreen({super.key, required this.chatId});
  final int chatId;

  @override
  State<SecretChatScreen> createState() => _SecretChatScreenState();
}

class _SecretChatScreenState extends State<SecretChatScreen> {
  late final SecretStore _store;
  final _text = TextEditingController();
  DateTime _lastTyping = DateTime(2000);
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _store = context.read<SecretStore>();
    _store.openChat(widget.chatId);
    NoScreenshot.instance.screenshotOff().catchError((_) => false);
  }

  @override
  void dispose() {
    _store.openChat(null);
    NoScreenshot.instance.screenshotOn().catchError((_) => false);
    _text.dispose();
    super.dispose();
  }

  Future<void> _sendText() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    try {
      await _store.sendText(widget.chatId, t);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _attach() async {
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.photo), title: const Text('Photo'), onTap: () => Navigator.pop(ctx, 'photo')),
          ListTile(leading: const Icon(Icons.photo_camera), title: const Text('Camera'), onTap: () => Navigator.pop(ctx, 'camera')),
          ListTile(leading: const Icon(Icons.insert_drive_file), title: const Text('File'), onTap: () => Navigator.pop(ctx, 'file')),
        ]),
      ),
    );
    if (a == null) return;
    String? path;
    var image = false;
    if (a == 'file') {
      final r = await FilePicker.platform.pickFiles();
      path = r?.files.single.path;
    } else {
      final x = await ImagePicker().pickImage(source: a == 'camera' ? ImageSource.camera : ImageSource.gallery, maxWidth: 2048, imageQuality: 85);
      path = x?.path;
      image = true;
    }
    if (path == null) return;
    setState(() => _sending = true);
    try {
      await _store.sendFile(widget.chatId, path, image: image);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickTtl(SecretChat chat) async {
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Self-destruct timer'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('New messages disappear from both phones this long after they are read.'),
          ),
          ...secretTtlValues.map((s) => RadioListTile<int>(
                value: s,
                groupValue: chat.ttl,
                title: Text(ttlLabel(s)),
                onChanged: (x) => Navigator.pop(ctx, x),
              )),
        ],
      ),
    );
    if (v == null || v == chat.ttl) return;
    try {
      await _store.setTtl(chat.id, v);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _messageMenu(SecretMessage m) async {
    if (m.isService) return;
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          if (m.text.isNotEmpty) ListTile(leading: const Icon(Icons.copy), title: const Text('Copy text'), onTap: () => Navigator.pop(ctx, 'copy')),
          if (m.state == SecretSendState.failed) ListTile(leading: const Icon(Icons.refresh), title: const Text('Send again'), onTap: () => Navigator.pop(ctx, 'retry')),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('Delete for both', style: TextStyle(color: Colors.red)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ]),
      ),
    );
    switch (a) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        break;
      case 'retry':
        await _store.retry(widget.chatId, m);
        break;
      case 'delete':
        await _store.deleteMessages(widget.chatId, [m]);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SecretStore>();
    final chat = store.chats[widget.chatId];
    if (chat == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('This secret chat was deleted')));
    final list = store.messages[chat.id] ?? const <SecretMessage>[];
    final colors = ChatColors.of(context);
    final status = chat.status == 'requested'
        ? 'waiting for ${chat.peer?.firstName ?? 'them'}…'
        : chat.status == 'closed'
            ? 'closed'
            : store.isTyping(chat.id)
                ? 'typing…'
                : 'end-to-end encrypted';

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          Avatar(id: chat.peerId, name: chat.title, url: chat.peer?.avatarAbsolute, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.lock, size: 16, color: _green),
                const SizedBox(width: 4),
                Flexible(child: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17))),
              ]),
              Text(status, style: const TextStyle(fontSize: 13, color: _green)),
            ]),
          ),
        ]),
        actions: [
          if (chat.isActive)
            IconButton(
              tooltip: 'Self-destruct timer',
              icon: chat.ttl == 0
                  ? const Icon(Icons.timer_outlined)
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.timer, color: _green),
                      Text(ttlLabel(chat.ttl), style: const TextStyle(fontSize: 12, color: _green)),
                    ]),
              onPressed: () => _pickTtl(chat),
            ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'key') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => SecretKeyScreen(chat: chat)));
              } else if (v == 'close') {
                if (await confirm(context, 'Delete secret chat?', 'It will be closed for both of you and all messages will be deleted from this phone.',
                    ok: 'Delete', danger: true)) {
                  await store.closeAndDelete(chat.id);
                  if (context.mounted) Navigator.pop(context);
                }
              }
            },
            itemBuilder: (_) => [
              if (chat.fingerprint != null) const PopupMenuItem(value: 'key', child: Text('Encryption key')),
              const PopupMenuItem(value: 'close', child: Text('Delete secret chat')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: list.isEmpty
              ? const _Intro()
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  itemCount: list.length,
                  itemBuilder: (_, i) => _bubble(chat, list[i], colors),
                ),
        ),
        if (chat.isActive)
          SafeArea(
            top: false,
            child: Container(
              color: colors.bar,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: [
                IconButton(
                  icon: _sending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.attach_file),
                  onPressed: _sending ? null : _attach,
                ),
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(hintText: 'Secret message', border: InputBorder.none),
                    onChanged: (_) {
                      if (DateTime.now().difference(_lastTyping).inSeconds >= 3) {
                        _lastTyping = DateTime.now();
                        _store.sendTyping(chat.id);
                      }
                    },
                  ),
                ),
                IconButton(icon: const Icon(Icons.arrow_upward_rounded, color: _green), onPressed: _sendText),
              ]),
            ),
          )
        else
          Container(
            width: double.infinity,
            color: colors.bar,
            padding: const EdgeInsets.all(16),
            child: SafeArea(
              top: false,
              child: Text(
                chat.status == 'requested' ? 'You can write once ${chat.peer?.firstName ?? 'they'} opens the app.' : 'This secret chat is closed.',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.meta),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _bubble(SecretChat chat, SecretMessage m, ChatColors colors) {
    if (m.isService) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(color: Colors.black.withAlpha(60), borderRadius: BorderRadius.circular(12)),
          child: Text(m.text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
      );
    }
    final mine = m.outgoing;
    final left = m.expiresAt?.difference(DateTime.now());
    Widget tick;
    switch (m.state) {
      case SecretSendState.sending:
        tick = Icon(Icons.schedule, size: 14, color: colors.meta);
        break;
      case SecretSendState.failed:
        tick = const Icon(Icons.error, size: 15, color: Colors.red);
        break;
      case SecretSendState.read:
        tick = const Icon(Icons.done_all, size: 15, color: _green);
        break;
      case SecretSendState.delivered:
        tick = Icon(Icons.done_all, size: 15, color: colors.meta);
        break;
      case SecretSendState.sent:
        tick = Icon(Icons.done, size: 15, color: colors.meta);
        break;
    }
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _messageMenu(m),
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 5),
          decoration: BoxDecoration(color: mine ? colors.mine : colors.other, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            if (m.media != null) _SecretMediaView(chatId: chat.id, message: m),
            if (m.text.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(m.text, style: TextStyle(fontSize: 15.5, height: 1.3, color: Theme.of(context).colorScheme.onSurface)),
              ),
            const SizedBox(height: 2),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (m.ttl > 0) ...[
                Icon(Icons.timer, size: 12, color: left == null ? colors.meta : _green),
                const SizedBox(width: 2),
                Text(left == null ? ttlLabel(m.ttl) : ttlLabel(left.inSeconds.clamp(0, 1 << 30).toInt()), style: TextStyle(fontSize: 11, color: colors.meta)),
                const SizedBox(width: 6),
              ],
              Text(messageTime(m.sentAt), style: TextStyle(fontSize: 11, color: colors.meta)),
              if (mine) ...[const SizedBox(width: 3), tick],
            ]),
          ]),
        ),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final colors = ChatColors.of(context);
    Widget row(IconData i, String t) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [Icon(i, size: 18, color: _green), const SizedBox(width: 8), Expanded(child: Text(t))]),
        );
    return Center(
      child: Container(
        margin: const EdgeInsets.all(28),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: colors.other, borderRadius: BorderRadius.circular(16)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [Icon(Icons.lock, color: _green), SizedBox(width: 8), Text('Secret chat', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16))]),
          const SizedBox(height: 10),
          row(Icons.enhanced_encryption_outlined, 'End-to-end encrypted — only the two phones can read it'),
          row(Icons.cloud_off_outlined, 'Nothing is kept on the server after delivery'),
          row(Icons.timer_outlined, 'Optional self-destruct timer'),
          row(Icons.no_photography_outlined, 'Screenshots blocked, no forwarding'),
          row(Icons.phone_android, 'Lives only on this phone'),
        ]),
      ),
    );
  }
}

class _SecretMediaView extends StatefulWidget {
  const _SecretMediaView({required this.chatId, required this.message});
  final int chatId;
  final SecretMessage message;

  @override
  State<_SecretMediaView> createState() => _SecretMediaViewState();
}

class _SecretMediaViewState extends State<_SecretMediaView> {
  bool _loading = false;
  String? _error;

  Future<String?> _get() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      return await context.read<SecretStore>().loadMedia(widget.chatId, widget.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open');
      return null;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    final m = widget.message.media!;
    if (m.kind == 'image' && m.localPath == null && m.size < 15 * 1024 * 1024) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _get());
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message.media!;
    final path = m.localPath;
    if (m.kind == 'image' && path != null) {
      return GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
              body: Center(child: InteractiveViewer(child: Image.file(File(path)))),
            ),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 320), child: Image.file(File(path), fit: BoxFit.cover)),
        ),
      );
    }
    return InkWell(
      onTap: _loading
          ? null
          : () async {
              final p = m.localPath ?? await _get();
              if (p != null) OpenFilex.open(p);
            },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            backgroundColor: _green,
            child: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(m.kind == 'image' ? Icons.image : Icons.insert_drive_file, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(_error ?? fileSize(m.size), style: const TextStyle(fontSize: 12)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Fingerprint check: both phones should show the same emoji and code.
class SecretKeyScreen extends StatelessWidget {
  const SecretKeyScreen({super.key, required this.chat});
  final SecretChat chat;

  @override
  Widget build(BuildContext context) {
    final fp = chat.fingerprint!;
    final hex = E2E.fingerprintHex(fp);
    return Scaffold(
      appBar: AppBar(title: const Text('Encryption key')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        Text(E2E.fingerprintEmoji(fp).join('  '), textAlign: TextAlign.center, style: const TextStyle(fontSize: 44)),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 14,
          runSpacing: 10,
          children: hex.map((h) => Text(h, style: const TextStyle(fontFamily: 'monospace', fontSize: 20, letterSpacing: 1))).toList(),
        ),
        const SizedBox(height: 28),
        Text(
          'If these emoji and numbers look the same on ${chat.peer?.firstName ?? 'their'}’s phone, '
          'your chat is end-to-end encrypted and nobody is in the middle.',
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }
}
