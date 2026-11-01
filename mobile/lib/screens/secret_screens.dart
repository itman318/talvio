import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../core/screen_guard.dart';
import '../core/e2e.dart';
import '../models/models.dart';
import '../state/secret_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';

const _green = Color(0xFF10B981);

/// The vault look: deep night-green in dark mode, soft mint in light mode, emerald for "me".
class _Vault {
  _Vault(this.dark);
  final bool dark;
  static _Vault of(BuildContext c) => _Vault(Theme.of(c).brightness == Brightness.dark);

  Color get accent => dark ? const Color(0xFF34D399) : const Color(0xFF059669);
  List<Color> get background => dark ? const [Color(0xFF07130F), Color(0xFF0B1B1A), Color(0xFF0A1420)] : const [Color(0xFFE9F7F1), Color(0xFFF2FAF7), Color(0xFFEAF4F6)];
  LinearGradient get mine => const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF0D9488)], begin: Alignment.topLeft, end: Alignment.bottomRight);
  Color get other => dark ? const Color(0xFF15262A) : Colors.white;
  Color get otherText => dark ? const Color(0xFFE6F2EF) : const Color(0xFF13201D);
  Color get meta => dark ? Colors.white.withValues(alpha: 0.55) : const Color(0xFF5D7570);
  Color get bar => dark ? const Color(0xFF0F1D1E) : Colors.white;
  Color get field => dark ? const Color(0xFF172A2B) : const Color(0xFFF0F6F4);
  Color get border => dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFDDEBE6);
}

/// Avatar with a small emerald lock on it.
class _VaultAvatar extends StatelessWidget {
  const _VaultAvatar({required this.id, required this.name, this.url, this.size = 52});
  final int id;
  final String name;
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return Stack(clipBehavior: Clip.none, children: [
      Avatar(id: id, name: name, url: url, size: size),
      Positioned(
        right: -3,
        bottom: -3,
        child: Container(
          padding: EdgeInsets.all(size * 0.06),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(colors: [Color(0xFF34D399), Color(0xFF0D9488)]),
            border: Border.all(color: bg, width: 2),
          ),
          child: Icon(Icons.lock_rounded, size: size * 0.24, color: Colors.white),
        ),
      ),
    ]);
  }
}

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
    'Start a vault chat?',
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
            ? 'Vault chat closed'
            : store.isTyping(chat.id)
                ? 'typing…'
                : (last?.preview ?? 'Vault chat started');
    return ListTile(
      leading: _VaultAvatar(id: chat.peerId, name: chat.title, url: chat.peer?.avatarAbsolute, size: 52),
      title: Row(children: [
        Flexible(child: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _Vault.of(context).accent, fontWeight: FontWeight.w700))),
        const SizedBox(width: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: _green.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
          child: Text('VAULT', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: _Vault.of(context).accent)),
        ),
      ]),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(chatListTime(chat.lastActivity), style: const TextStyle(fontSize: 12)),
        if (chat.unread > 0)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(gradient: _Vault.of(context).mine, borderRadius: BorderRadius.circular(10)),
            child: Text('${chat.unread}', style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
      ]),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SecretChatScreen(chatId: chat.id))),
      onLongPress: () async {
        if (await confirm(context, 'Delete vault chat?', 'It will be closed for both of you and deleted from this phone.', ok: 'Delete', danger: true)) {
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
    ScreenGuard.acquire();
  }

  @override
  void dispose() {
    _store.openChat(null);
    ScreenGuard.release();
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
    if (chat == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('This vault chat was deleted')));
    final list = store.messages[chat.id] ?? const <SecretMessage>[];
    final v = _Vault.of(context);
    final status = chat.status == 'requested'
        ? 'waiting for ${chat.peer?.firstName ?? 'them'}…'
        : chat.status == 'closed'
            ? 'closed'
            : store.isTyping(chat.id)
                ? 'typing…'
                : 'end-to-end encrypted';

    return Scaffold(
      backgroundColor: v.background[1],
      appBar: AppBar(
        backgroundColor: v.bar,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 0,
        shape: Border(bottom: BorderSide(color: v.border)),
        title: Row(children: [
          _VaultAvatar(id: chat.peerId, name: chat.title, url: chat.peer?.avatarAbsolute, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              Row(children: [
                Icon(Icons.shield_rounded, size: 13, color: v.accent),
                const SizedBox(width: 4),
                Flexible(child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: v.accent, fontWeight: FontWeight.w600))),
              ]),
            ]),
          ),
        ]),
        actions: [
          if (chat.isActive)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _pickTtl(chat),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: chat.ttl == 0 ? Colors.transparent : _green.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(chat.ttl == 0 ? Icons.timer_outlined : Icons.timer_rounded, size: 20, color: chat.ttl == 0 ? null : v.accent),
                    if (chat.ttl > 0) ...[
                      const SizedBox(width: 4),
                      Text(ttlLabel(chat.ttl), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: v.accent)),
                    ],
                  ]),
                ),
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (val) async {
              if (val == 'key') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => SecretKeyScreen(chat: chat)));
              } else if (val == 'close') {
                if (await confirm(context, 'Delete vault chat?', 'It will be closed for both of you and all messages will be deleted from this phone.',
                    ok: 'Delete', danger: true)) {
                  await store.closeAndDelete(chat.id);
                  if (context.mounted) Navigator.pop(context);
                }
              }
            },
            itemBuilder: (_) => [
              if (chat.fingerprint != null) const PopupMenuItem(value: 'key', child: Text('Encryption key')),
              const PopupMenuItem(value: 'close', child: Text('Delete vault chat')),
            ],
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: LinearGradient(colors: v.background, begin: Alignment.topCenter, end: Alignment.bottomCenter)),
        child: Column(children: [
          Expanded(
            child: list.isEmpty
                ? const _Intro()
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                    itemCount: list.length,
                    itemBuilder: (_, i) => _bubble(chat, list[i], v),
                  ),
          ),
          if (chat.isActive)
            Container(
              decoration: BoxDecoration(color: v.bar, border: Border(top: BorderSide(color: v.border))),
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
              child: SafeArea(
                top: false,
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  IconButton(
                    icon: _sending
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.attach_file_rounded, color: v.meta),
                    onPressed: _sending ? null : _attach,
                  ),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(color: v.field, borderRadius: BorderRadius.circular(22)),
                      child: TextField(
                        controller: _text,
                        minLines: 1,
                        maxLines: 5,
                        enableIMEPersonalizedLearning: false, // the keyboard shouldn't learn vault messages
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: 'Encrypted message',
                          hintStyle: TextStyle(color: v.meta),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 11),
                          prefixIcon: Icon(Icons.lock_outline_rounded, size: 16, color: v.accent),
                          prefixIconConstraints: const BoxConstraints(minWidth: 24),
                        ),
                        onChanged: (_) {
                          if (DateTime.now().difference(_lastTyping).inSeconds >= 3) {
                            _lastTyping = DateTime.now();
                            _store.sendTyping(chat.id);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: _sendText,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(shape: BoxShape.circle, gradient: v.mine),
                      child: const Icon(Icons.arrow_upward_rounded, color: Colors.white),
                    ),
                  ),
                ]),
              ),
            )
          else
            Container(
              width: double.infinity,
              decoration: BoxDecoration(color: v.bar, border: Border(top: BorderSide(color: v.border))),
              padding: const EdgeInsets.all(16),
              child: SafeArea(
                top: false,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(chat.status == 'requested' ? Icons.hourglass_top_rounded : Icons.lock_rounded, size: 18, color: v.meta),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      chat.status == 'requested' ? 'You can write once ${chat.peer?.firstName ?? 'they'} opens the app.' : 'This vault chat is closed.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: v.meta),
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _bubble(SecretChat chat, SecretMessage m, _Vault v) {
    if (m.isService) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: _green.withValues(alpha: v.dark ? 0.16 : 0.12), borderRadius: BorderRadius.circular(14)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.shield_outlined, size: 13, color: v.accent),
            const SizedBox(width: 5),
            Flexible(child: Text(m.text, textAlign: TextAlign.center, style: TextStyle(color: v.accent, fontSize: 12.5, fontWeight: FontWeight.w600))),
          ]),
        ),
      );
    }
    final mine = m.outgoing;
    final left = m.expiresAt?.difference(DateTime.now());
    final meta = mine ? Colors.white.withValues(alpha: 0.78) : v.meta;
    Widget tick;
    switch (m.state) {
      case SecretSendState.sending:
        tick = Icon(Icons.schedule_rounded, size: 13, color: meta);
        break;
      case SecretSendState.failed:
        tick = const Icon(Icons.error_rounded, size: 15, color: Color(0xFFFFB4B4));
        break;
      case SecretSendState.read:
        tick = const Icon(Icons.done_all_rounded, size: 15, color: Colors.white);
        break;
      case SecretSendState.delivered:
        tick = Icon(Icons.done_all_rounded, size: 15, color: meta);
        break;
      case SecretSendState.sent:
        tick = Icon(Icons.done_rounded, size: 15, color: meta);
        break;
    }
    const r = Radius.circular(18);
    const tail = Radius.circular(5);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _messageMenu(m),
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          margin: const EdgeInsets.symmetric(vertical: 2.5),
          padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
          decoration: BoxDecoration(
            gradient: mine ? v.mine : null,
            color: mine ? null : v.other,
            borderRadius: BorderRadius.only(topLeft: r, topRight: r, bottomLeft: mine ? r : tail, bottomRight: mine ? tail : r),
            border: mine ? null : Border.all(color: v.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            if (m.media != null) _SecretMediaView(chatId: chat.id, message: m),
            if (m.text.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(m.text, style: TextStyle(fontSize: 15.5, height: 1.3, color: mine ? Colors.white : v.otherText)),
              ),
            const SizedBox(height: 3),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (m.ttl > 0) ...[
                Icon(Icons.local_fire_department_rounded, size: 12, color: left == null ? meta : (mine ? Colors.white : const Color(0xFFF59E0B))),
                const SizedBox(width: 2),
                Text(left == null ? ttlLabel(m.ttl) : ttlLabel(left.inSeconds.clamp(0, 1 << 30).toInt()), style: TextStyle(fontSize: 11, color: meta)),
                const SizedBox(width: 6),
              ],
              Text(messageTime(m.sentAt), style: TextStyle(fontSize: 11, color: meta)),
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
    final v = _Vault.of(context);
    Widget row(IconData i, String t) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: _green.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(9)),
              child: Icon(i, size: 17, color: v.accent),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(t, style: TextStyle(color: v.otherText, height: 1.3))),
          ]),
        );
    return Center(
      child: SingleChildScrollView(
        child: Container(
          margin: const EdgeInsets.all(26),
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
          decoration: BoxDecoration(color: v.other, borderRadius: BorderRadius.circular(24), border: Border.all(color: v.border)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: v.mine,
                boxShadow: [BoxShadow(color: _green.withValues(alpha: 0.35), blurRadius: 22, offset: const Offset(0, 8))],
              ),
              child: const Icon(Icons.shield_rounded, color: Colors.white, size: 32),
            ),
            const SizedBox(height: 12),
            Text('Vault chat', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 19, color: v.otherText)),
            const SizedBox(height: 4),
            Text('Only you two can read this', style: TextStyle(color: v.meta)),
            const SizedBox(height: 14),
            row(Icons.enhanced_encryption_rounded, 'End-to-end encrypted — only the two phones can read it'),
            row(Icons.cloud_off_rounded, 'Nothing is kept on the server after delivery'),
            row(Icons.local_fire_department_rounded, 'Optional self-destruct timer'),
            row(Icons.no_photography_rounded, 'Screenshots blocked, no forwarding'),
            row(Icons.phone_android_rounded, 'Lives only on this phone'),
          ]),
        ),
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
            backgroundColor: Colors.white.withValues(alpha: 0.25),
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
    final v = _Vault.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Encryption key')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 24, 18, 22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(colors: v.dark ? const [Color(0xFF0F2A24), Color(0xFF102028)] : const [Color(0xFFE3F6EE), Color(0xFFEAF5F7)]),
            border: Border.all(color: v.border),
          ),
          child: Column(children: [
            Icon(Icons.verified_user_rounded, size: 40, color: v.accent),
            const SizedBox(height: 14),
            Text(E2E.fingerprintEmoji(fp).join('  '), textAlign: TextAlign.center, style: const TextStyle(fontSize: 40)),
            const SizedBox(height: 18),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: hex
                  .map((h) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: v.other, borderRadius: BorderRadius.circular(10), border: Border.all(color: v.border)),
                        child: Text(h, style: TextStyle(fontFamily: 'monospace', fontSize: 17, letterSpacing: 1, fontWeight: FontWeight.w600, color: v.otherText)),
                      ))
                  .toList(),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        Text(
          'Compare these with ${chat.peer?.firstName ?? 'them'}’s phone. If the emoji and numbers are the same, '
          'your chat is end-to-end encrypted and nobody is in the middle.',
          textAlign: TextAlign.center,
          style: TextStyle(color: v.meta, height: 1.4),
        ),
      ]),
    );
  }
}
