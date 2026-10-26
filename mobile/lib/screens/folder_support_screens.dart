import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/extras.dart';
import '../theme/brand.dart';
import '../widgets/mascot.dart';
import '../widgets/premium.dart';
import 'more_screens.dart' show ContentPageScreen;

// ================================================================== chat folders
class FoldersScreen extends StatelessWidget {
  const FoldersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final folders = store.folders;
    return Scaffold(
      appBar: AppBar(title: const Text('Chat folders')),
      body: Column(children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Folders appear as tabs above your chat list. Drag to reorder.', style: TextStyle(color: Brand.muted)),
        ),
        Expanded(
          child: ReorderableListView(
            onReorder: (from, to) {
              final ids = folders.map((f) => f.id).toList();
              if (to > from) to -= 1;
              ids.insert(to, ids.removeAt(from));
              store.reorderFolders(ids).catchError((e) {
                if (context.mounted) showError(context, e);
              });
            },
            children: [
              for (final f in folders)
                ListTile(
                  key: ValueKey(f.id),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(f.name),
                  subtitle: Text(_describe(f)),
                  trailing: const Icon(Icons.drag_handle),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EditFolderScreen(folder: f))),
                ),
            ],
          ),
        ),
      ]),
      floatingActionButton: folders.length >= 10
          ? null
          : FloatingActionButton.extended(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EditFolderScreen())),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('New folder'),
            ),
    );
  }

  static String _describe(ChatFolder f) {
    final parts = <String>[
      if (f.includePrivate) 'Private chats',
      if (f.includeGroups) 'Groups',
      if (f.includeChannels) 'Channels',
      if (f.chatIds.isNotEmpty) '${f.chatIds.length} chats',
      if (f.unreadOnly) 'unread only',
    ];
    return parts.join(' · ');
  }
}

class EditFolderScreen extends StatefulWidget {
  const EditFolderScreen({super.key, this.folder});
  final ChatFolder? folder;

  @override
  State<EditFolderScreen> createState() => _EditFolderScreenState();
}

class _EditFolderScreenState extends State<EditFolderScreen> {
  late final TextEditingController _name;
  late bool _private;
  late bool _groups;
  late bool _channels;
  late bool _unread;
  late final Set<int> _chats;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final f = widget.folder;
    _name = TextEditingController(text: f?.name ?? '');
    _private = f?.includePrivate ?? false;
    _groups = f?.includeGroups ?? false;
    _channels = f?.includeChannels ?? false;
    _unread = f?.unreadOnly ?? false;
    _chats = {...?f?.chatIds};
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      showInfo(context, 'Give the folder a name');
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<ChatStore>().saveFolder(widget.folder, {
        'name': _name.text.trim(),
        'chat_ids': _chats.toList(),
        'include_private': _private,
        'include_groups': _groups,
        'include_channels': _channels,
        'include_unread_only': _unread,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (!await confirm(context, 'Delete folder?', 'Chats stay where they are.', ok: 'Delete', danger: true)) return;
    if (!mounted) return;
    try {
      await context.read<ChatStore>().deleteFolder(widget.folder!.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chats = context.watch<ChatStore>().chats;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folder == null ? 'New folder' : 'Edit folder'),
        actions: [
          if (widget.folder != null) IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
          TextButton(onPressed: _busy ? null : _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(controller: _name, maxLength: 24, decoration: const InputDecoration(labelText: 'Folder name', hintText: 'e.g. Work')),
          ),
          const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 4), child: Text('Include', style: TextStyle(fontWeight: FontWeight.w600))),
          CheckboxListTile(value: _private, title: const Text('All private chats'), onChanged: (v) => setState(() => _private = v!)),
          CheckboxListTile(value: _groups, title: const Text('All groups'), onChanged: (v) => setState(() => _groups = v!)),
          CheckboxListTile(value: _channels, title: const Text('All channels'), onChanged: (v) => setState(() => _channels = v!)),
          SwitchListTile(value: _unread, title: const Text('Only show unread chats'), onChanged: (v) => setState(() => _unread = v)),
          const Divider(),
          const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text('Or pick chats', style: TextStyle(fontWeight: FontWeight.w600))),
          ...chats.map((c) => CheckboxListTile(
                value: _chats.contains(c.id),
                secondary: Avatar(id: c.id, name: c.title, url: c.avatarAbsolute, size: 36, icon: c.isSavedMessages ? Icons.bookmark : null),
                title: Text(c.title),
                onChanged: (v) => setState(() => v == true ? _chats.add(c.id) : _chats.remove(c.id)),
              )),
        ],
      ),
    );
  }
}

// ================================================================== support tickets
const _categories = <String, (String, IconData, Color)>{
  'account': ('Account & login', Icons.manage_accounts_rounded, Brand.sky),
  'bug': ('Something isn’t working', Icons.bug_report_rounded, Color(0xFFE5484D)),
  'abuse': ('Report abuse / safety', Icons.shield_rounded, Brand.amber),
  'payment': ('Payments', Icons.payments_rounded, Brand.green),
  'feature': ('Idea or feature', Icons.lightbulb_rounded, Brand.violet),
  'other': ('Something else', Icons.chat_rounded, Color(0xFF5E6B8C)),
};

(String, Color) _status(String s) => switch (s) {
      'open' => ('Waiting for support', Brand.amber),
      'pending' => ('Support replied', Brand.primary),
      'resolved' => ('Resolved', Brand.green),
      'closed' => ('Closed', Brand.muted),
      _ => (s, Brand.muted),
    };

Widget _statusChip(String status) {
  final (label, color) = _status(status);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(10)),
    child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
  );
}

/// Picks a screenshot and uploads it; returns the media id.
Future<int?> _pickScreenshot(BuildContext context) async {
  final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80, maxWidth: 1600);
  if (x == null || !context.mounted) return null;
  try {
    final m = await context.read<AppServices>().api.upload(x.path, kind: 'image');
    return (m['id'] as num).toInt();
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
}

String _deviceLine() {
  final os = Platform.isAndroid ? 'Android' : (Platform.isIOS ? 'iOS' : Platform.operatingSystem);
  return '$os ${Platform.operatingSystemVersion.split(' ').take(3).join(' ')} · Talvio v${AppConfig.appVersion}'.trim();
}

class SupportListScreen extends StatefulWidget {
  const SupportListScreen({super.key});

  @override
  State<SupportListScreen> createState() => _SupportListScreenState();
}

class _SupportListScreenState extends State<SupportListScreen> {
  List<SupportTicket>? _tickets;
  late final ChatStore _store;

  @override
  void initState() {
    super.initState();
    _store = context.read<ChatStore>();
    _store.supportUpdates.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _store.supportUpdates.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<AppServices>().api.get('/support/tickets') as List;
      if (mounted) setState(() => _tickets = data.map((j) => SupportTicket.fromJson(Map<String, dynamic>.from(j as Map))).toList());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _new([String category = 'other']) async {
    final created = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => NewTicketScreen(category: category)));
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = _tickets;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final open = t?.where((x) => x.status != 'closed' && x.status != 'resolved').toList() ?? [];
    final done = t?.where((x) => x.status == 'closed' || x.status == 'resolved').toList() ?? [];
    Widget tile(SupportTicket x) {
      final (label, icon, color) = _categories[x.category] ?? _categories['other']!;
      return ListTile(
        leading: Stack(clipBehavior: Clip.none, children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(13)),
            child: Icon(icon, color: color, size: 22),
          ),
          if (x.unread)
            Positioned(
              right: -2,
              top: -2,
              child: Container(width: 12, height: 12, decoration: BoxDecoration(color: Brand.rose, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2))),
            ),
        ]),
        title: Row(children: [
          Expanded(child: Text(x.subject, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: x.unread ? FontWeight.w800 : FontWeight.w600))),
          if (x.updatedAt != null) Text(chatListTime(x.updatedAt!), style: const TextStyle(fontSize: 12, color: Brand.muted)),
        ]),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            _statusChip(x.status),
            const SizedBox(width: 8),
            Expanded(child: Text(x.lastMessage ?? label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
          ]),
        ),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => TicketScreen(ticketId: x.id)));
          _load();
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Help & support')),
      body: t == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                  decoration: BoxDecoration(gradient: Brand.auroraSoft(dark), borderRadius: BorderRadius.circular(24)),
                  child: Column(children: [
                    Row(children: [
                      const TaviMascot(pose: TaviPose.wave, size: 74),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('How can we help?', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                          SizedBox(height: 3),
                          Text('Our team replies right here, usually within a day.', style: TextStyle(fontSize: 13, color: Brand.muted)),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    GridView.count(
                      crossAxisCount: 3,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.15,
                      children: [
                        for (final e in _categories.entries)
                          Material(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => _new(e.key),
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                  Icon(e.value.$2, color: e.value.$3, size: 24),
                                  const SizedBox(height: 6),
                                  Text(e.value.$1, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, height: 1.15)),
                                ]),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextButton.icon(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ContentPageScreen(slug: 'faq', fallbackTitle: 'FAQ'))),
                      icon: const Icon(Icons.quiz_rounded, size: 18),
                      label: const Text('Read the FAQ first'),
                    ),
                  ]),
                ),
                if (open.isNotEmpty) SettingsGroup(title: 'Open requests', children: [for (final x in open) tile(x)]),
                if (done.isNotEmpty) SettingsGroup(title: 'Earlier', children: [for (final x in done) tile(x)]),
              ]),
            ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _new, icon: const Icon(Icons.edit_rounded), label: const Text('New request')),
    );
  }
}

class NewTicketScreen extends StatefulWidget {
  const NewTicketScreen({super.key, this.category = 'other'});
  final String category;

  @override
  State<NewTicketScreen> createState() => _NewTicketScreenState();
}

class _NewTicketScreenState extends State<NewTicketScreen> {
  final _subject = TextEditingController();
  final _message = TextEditingController();
  late String _category = widget.category;
  bool _busy = false;
  bool _device = true;
  int? _shot;

  Future<void> _send() async {
    if (_subject.text.trim().length < 3 || _message.text.trim().isEmpty) {
      showInfo(context, 'Add a short subject and describe what happened');
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<AppServices>().api.post('/support/tickets', {
        'subject': _subject.text.trim(),
        'category': _category,
        'message': _message.text.trim(),
        if (_device) 'device': _deviceLine(),
        if (_shot != null) 'media_id': _shot,
      });
      if (mounted) {
        showInfo(context, 'Sent — we’ll reply here');
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New request')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        const Text('TOPIC', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Brand.muted)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in _categories.entries)
            ChoiceChip(
              avatar: Icon(e.value.$2, size: 17, color: _category == e.key ? Colors.white : e.value.$3),
              label: Text(e.value.$1),
              selected: _category == e.key,
              onSelected: (_) => setState(() => _category = e.key),
            ),
        ]),
        const SizedBox(height: 16),
        TextField(controller: _subject, maxLength: 150, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Subject', hintText: 'e.g. I can’t send photos')),
        const SizedBox(height: 6),
        TextField(
          controller: _message,
          maxLength: 4000,
          minLines: 5,
          maxLines: 12,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'What happened?', hintText: 'What did you do, what did you expect, what happened instead?', alignLabelWithHint: true),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            final id = await _pickScreenshot(context);
            if (id != null && mounted) setState(() => _shot = id);
          },
          icon: Icon(_shot == null ? Icons.add_photo_alternate_rounded : Icons.check_circle_rounded, color: _shot == null ? null : Brand.green),
          label: Text(_shot == null ? 'Add a screenshot' : 'Screenshot added — tap to change'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include phone & app version'),
          subtitle: Text(_deviceLine(), style: const TextStyle(fontSize: 12)),
          value: _device,
          onChanged: (v) => setState(() => _device = v),
        ),
        const SizedBox(height: 8),
        AuroraButton(label: 'Send request', icon: Icons.send_rounded, busy: _busy, onPressed: _send),
      ]),
    );
  }
}

class TicketScreen extends StatefulWidget {
  const TicketScreen({super.key, required this.ticketId});
  final int ticketId;

  @override
  State<TicketScreen> createState() => _TicketScreenState();
}

class _TicketScreenState extends State<TicketScreen> {
  SupportTicket? _ticket;
  List<SupportMessage> _messages = [];
  final _reply = TextEditingController();
  late final ChatStore _store;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _store = context.read<ChatStore>();
    _store.supportUpdates.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _store.supportUpdates.removeListener(_load);
    _reply.dispose();
    super.dispose();
  }

  void _apply(Map<String, dynamic> r) {
    _ticket = SupportTicket.fromJson(Map<String, dynamic>.from(r['ticket'] as Map));
    _messages = (r['messages'] as List).map((j) => SupportMessage.fromJson(Map<String, dynamic>.from(j as Map))).toList();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/support/tickets/${widget.ticketId}') as Map);
      if (mounted) setState(() => _apply(r));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _send({int? mediaId}) async {
    final text = _reply.text.trim();
    if (text.isEmpty && mediaId == null) return;
    setState(() => _sending = true);
    try {
      final r = await context.read<AppServices>().api.post('/support/tickets/${widget.ticketId}/messages', {'text': text, if (mediaId != null) 'media_id': mediaId});
      _reply.clear();
      if (mounted) setState(() => _apply(Map<String, dynamic>.from(r as Map)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _close() async {
    if (!await confirm(context, 'Close this request?', 'Open a new request if you need more help later.', ok: 'Close')) return;
    if (!mounted) return;
    try {
      final r = await context.read<AppServices>().api.post('/support/tickets/${widget.ticketId}/close');
      if (mounted) setState(() => _apply(Map<String, dynamic>.from(r as Map)));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _rate(int stars) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${'★' * stars}${'☆' * (5 - stars)}', textAlign: TextAlign.center, style: const TextStyle(color: Brand.amber, fontSize: 28)),
        content: TextField(controller: note, maxLength: 500, maxLines: 3, decoration: const InputDecoration(hintText: 'Anything to add? (optional)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await context.read<AppServices>().api.post('/support/tickets/${widget.ticketId}/rate', {'rating': stars, 'comment': note.text.trim()});
      if (mounted) {
        setState(() => _apply(Map<String, dynamic>.from(r as Map)));
        showInfo(context, 'Thank you for the feedback!');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _bubble(SupportMessage m, ChatColors cc) {
    final mine = m.fromUser;
    final fg = mine ? Colors.white : Theme.of(context).colorScheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (!mine)
          Padding(
            padding: const EdgeInsets.only(right: 6, bottom: 4),
            child: Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle),
              child: const Icon(Icons.support_agent_rounded, color: Colors.white, size: 18),
            ),
          ),
        Flexible(
          child: Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
            decoration: BoxDecoration(
              color: mine ? null : cc.other,
              gradient: mine ? Brand.mineGradient : null,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(mine ? 18 : 6),
                bottomRight: Radius.circular(mine ? 6 : 18),
              ),
              border: mine ? null : Border.all(color: Theme.of(context).brightness == Brightness.dark ? Colors.white12 : const Color(0xFFE8EBF2), width: 0.8),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!mine) const Text('Talvio Support', style: TextStyle(fontWeight: FontWeight.w800, color: Brand.primary, fontSize: 12.5)),
              if (m.mediaUrl != null) ...[
                const SizedBox(height: 4),
                _SupportPicture(message: m),
              ],
              if (m.text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: SelectableText(m.text, style: TextStyle(color: fg, fontSize: 15, height: 1.35))),
              const SizedBox(height: 3),
              Align(
                alignment: Alignment.centerRight,
                child: Text('${chatListTime(m.createdAt)} ${messageTime(m.createdAt)}', style: TextStyle(fontSize: 11, color: mine ? Colors.white70 : cc.meta)),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _ticket;
    final closed = t?.status == 'closed';
    final cc = ChatColors.of(context);
    return Scaffold(
      backgroundColor: cc.background,
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t?.subject ?? 'Support', maxLines: 1, overflow: TextOverflow.ellipsis),
          if (t != null) Text('Request #${t.id}', style: const TextStyle(fontSize: 12, color: Brand.muted, fontWeight: FontWeight.w500)),
        ]),
        actions: [if (t != null && !closed) TextButton(onPressed: _close, child: const Text('Close'))],
      ),
      body: Column(children: [
        if (t != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: _status(t.status).$2.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              Icon(t.status == 'resolved' || t.status == 'closed' ? Icons.check_circle_rounded : Icons.schedule_rounded, size: 18, color: _status(t.status).$2),
              const SizedBox(width: 8),
              Expanded(child: Text(_status(t.status).$1, style: TextStyle(fontWeight: FontWeight.w700, color: _status(t.status).$2))),
              Text((_categories[t.category] ?? _categories['other']!).$1, style: const TextStyle(fontSize: 12, color: Brand.muted)),
            ]),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            children: [
              for (final m in _messages) _bubble(m, cc),
              if (t != null && t.canRate)
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(18)),
                  child: Column(children: [
                    const Text('How did we do?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 6),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      for (var i = 1; i <= 5; i++)
                        IconButton(onPressed: () => _rate(i), icon: const Icon(Icons.star_rounded, size: 32, color: Brand.amber), tooltip: '$i'),
                    ]),
                  ]),
                ),
              if (t?.rating != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Center(child: Text('You rated this ${'★' * t!.rating!}${'☆' * (5 - t.rating!)}', style: const TextStyle(color: Brand.muted))),
                ),
            ],
          ),
        ),
        if (!closed)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: Row(children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(24)),
                    child: Row(children: [
                      IconButton(
                        tooltip: 'Add a screenshot',
                        icon: const Icon(Icons.add_photo_alternate_rounded, color: Brand.muted),
                        onPressed: _sending
                            ? null
                            : () async {
                                final id = await _pickScreenshot(context);
                                if (id != null) await _send(mediaId: id);
                              },
                      ),
                      Expanded(
                        child: TextField(
                          controller: _reply,
                          minLines: 1,
                          maxLines: 5,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(hintText: 'Write a message…', border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false),
                        ),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(width: 6),
                Material(
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: Ink(
                    decoration: const BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle),
                    child: InkWell(
                      onTap: _sending ? null : () => _send(),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: _sending
                            ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.send_rounded, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// A screenshot in a support conversation (tap to see it big).
class _SupportPicture extends StatelessWidget {
  const _SupportPicture({required this.message});
  final SupportMessage message;

  @override
  Widget build(BuildContext context) {
    final info = MediaInfo(id: message.mediaId ?? 0, kind: 'image', mime: 'image/jpeg', size: 0, name: 'support.jpg', url: message.mediaUrl!);
    return FutureBuilder<File>(
      future: context.read<AppServices>().media.get(info),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const SizedBox(width: 200, height: 140, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        return GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => Scaffold(
                backgroundColor: Colors.black,
                appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
                body: Center(child: InteractiveViewer(maxScale: 5, child: Image.file(snap.data!))),
              ),
            ),
          ),
          child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(snap.data!, width: 220, fit: BoxFit.cover, cacheWidth: 600)),
        );
      },
    );
  }
}
