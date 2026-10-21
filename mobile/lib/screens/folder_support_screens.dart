import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/extras.dart';

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
          child: Text('Folders appear as tabs above your chat list. Drag to reorder.', style: TextStyle(color: Colors.black54)),
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
const _categories = {
  'account': 'Account & login',
  'bug': 'Something isn’t working',
  'abuse': 'Report abuse / safety',
  'payment': 'Payments',
  'feature': 'Feature request',
  'other': 'Other',
};

String _statusText(String s) => switch (s) {
      'open' => 'Waiting for support',
      'pending' => 'Support replied',
      'resolved' => 'Resolved',
      'closed' => 'Closed',
      _ => s,
    };

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

  @override
  Widget build(BuildContext context) {
    final t = _tickets;
    return Scaffold(
      appBar: AppBar(title: const Text('Help & support')),
      body: t == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: t.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 120),
                      Icon(Icons.support_agent, size: 64, color: Colors.black26),
                      SizedBox(height: 12),
                      Center(child: Text('Need help? Send us a message and\nour team will reply here.', textAlign: TextAlign.center)),
                    ])
                  : ListView(
                      children: t
                          .map((x) => ListTile(
                                leading: Icon(x.unread ? Icons.mark_email_unread : Icons.mail_outline,
                                    color: x.unread ? const Color(0xFF2AABEE) : null),
                                title: Text(x.subject, style: TextStyle(fontWeight: x.unread ? FontWeight.bold : FontWeight.normal)),
                                subtitle: Text('${_statusText(x.status)}${x.lastMessage != null ? ' · ${x.lastMessage}' : ''}',
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                                trailing: x.updatedAt == null ? null : Text(chatListTime(x.updatedAt!), style: const TextStyle(fontSize: 12)),
                                onTap: () async {
                                  await Navigator.push(context, MaterialPageRoute(builder: (_) => TicketScreen(ticketId: x.id)));
                                  _load();
                                },
                              ))
                          .toList(),
                    ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final created = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const NewTicketScreen()));
          if (created == true) _load();
        },
        icon: const Icon(Icons.add),
        label: const Text('New request'),
      ),
    );
  }
}

class NewTicketScreen extends StatefulWidget {
  const NewTicketScreen({super.key});

  @override
  State<NewTicketScreen> createState() => _NewTicketScreenState();
}

class _NewTicketScreenState extends State<NewTicketScreen> {
  final _subject = TextEditingController();
  final _message = TextEditingController();
  String _category = 'other';
  bool _busy = false;

  Future<void> _send() async {
    if (_subject.text.trim().length < 3 || _message.text.trim().isEmpty) {
      showInfo(context, 'Add a subject and describe the problem');
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<AppServices>().api.post('/support/tickets', {
        'subject': _subject.text.trim(),
        'category': _category,
        'message': _message.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New support request'), actions: [
        TextButton(onPressed: _busy ? null : _send, child: const Text('Send')),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<String>(
          value: _category,
          decoration: const InputDecoration(labelText: 'Topic'),
          items: _categories.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
          onChanged: (v) => setState(() => _category = v!),
        ),
        const SizedBox(height: 8),
        TextField(controller: _subject, maxLength: 150, decoration: const InputDecoration(labelText: 'Subject')),
        TextField(
          controller: _message,
          maxLength: 4000,
          minLines: 5,
          maxLines: 12,
          decoration: const InputDecoration(labelText: 'Describe the problem', alignLabelWithHint: true),
        ),
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
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/support/tickets/${widget.ticketId}') as Map);
      if (!mounted) return;
      setState(() {
        _ticket = SupportTicket.fromJson(Map<String, dynamic>.from(r['ticket'] as Map));
        _messages = (r['messages'] as List).map((j) => SupportMessage.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _send() async {
    final text = _reply.text.trim();
    if (text.isEmpty) return;
    try {
      await context.read<AppServices>().api.post('/support/tickets/${widget.ticketId}/messages', {'text': text});
      _reply.clear();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _close() async {
    if (!await confirm(context, 'Close this request?', 'Open a new request if you need more help later.', ok: 'Close')) return;
    try {
      await context.read<AppServices>().api.post('/support/tickets/${widget.ticketId}/close');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _ticket;
    final closed = t?.status == 'closed';
    final cc = ChatColors.of(context);
    return Scaffold(
      backgroundColor: cc.background,
      appBar: AppBar(
        title: Text(t?.subject ?? 'Support', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [if (t != null && !closed) TextButton(onPressed: _close, child: const Text('Close'))],
      ),
      body: Column(children: [
        if (t != null)
          Container(
            width: double.infinity,
            color: cc.bar,
            padding: const EdgeInsets.all(8),
            child: Text(_statusText(t.status), textAlign: TextAlign.center, style: TextStyle(color: cc.meta)),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: _messages
                .map((m) => Align(
                      alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: m.fromUser ? cc.mine : cc.other,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (!m.fromUser) const Text('Support team', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2AABEE), fontSize: 13)),
                          Text(m.text),
                          const SizedBox(height: 2),
                          Text('${chatListTime(m.createdAt)} ${messageTime(m.createdAt)}', style: TextStyle(fontSize: 11, color: cc.meta)),
                        ]),
                      ),
                    ))
                .toList(),
          ),
        ),
        if (!closed)
          SafeArea(
            top: false,
            child: Container(
              color: cc.bar,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _reply,
                    minLines: 1,
                    maxLines: 5,
                    decoration: const InputDecoration(hintText: 'Write a message…', border: InputBorder.none),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send, color: Color(0xFF2AABEE)), onPressed: _send),
              ]),
            ),
          ),
      ]),
    );
  }
}
