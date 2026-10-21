import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import 'chat_screen.dart';

/// Search field + results for finding users by @username or phone number.
class UserSearch extends StatefulWidget {
  const UserSearch({super.key, required this.onTap, this.selectedIds = const {}, this.header});

  final void Function(AppUser user) onTap;
  final Set<int> selectedIds;
  final Widget? header;

  @override
  State<UserSearch> createState() => _UserSearchState();
}

class _UserSearchState extends State<UserSearch> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<AppUser> _results = [];
  List<AppUser> _contacts = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    context.read<AppServices>().api.get('/contacts').then((data) {
      if (!mounted) return;
      setState(() => _contacts = (data as List).map((j) => AppUser.fromJson(Map<String, dynamic>.from(j as Map))).toList());
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(v.trim()));
  }

  Future<void> _search(String q) async {
    if (q.length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);
    try {
      final data = await context.read<AppServices>().api.get('/users/search', query: {'q': q});
      if (!mounted) return;
      setState(() => _results = (data as List).map((j) => AppUser.fromJson(Map<String, dynamic>.from(j as Map))).toList());
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showing = _q.text.trim().length >= 2 ? _results : _contacts;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _q,
            autofocus: true,
            onChanged: _onChanged,
            decoration: InputDecoration(
              hintText: 'Search @username or phone (+92…)',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _loading ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : null,
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              if (widget.header != null && _q.text.isEmpty) widget.header!,
              if (_q.text.trim().length < 2 && _contacts.isNotEmpty)
                const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Contacts', style: TextStyle(fontWeight: FontWeight.w600))),
              if (_q.text.trim().length >= 2 && !_loading && _results.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No users found'))),
              ...showing.map((u) => ListTile(
                    leading: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute),
                    title: Text(u.name),
                    subtitle: Text(u.username != null ? '@${u.username}' : lastSeenText(u)),
                    trailing: widget.selectedIds.contains(u.id) ? const Icon(Icons.check_circle, color: Color(0xFF2AABEE)) : null,
                    onTap: () => widget.onTap(u),
                  )),
            ],
          ),
        ),
      ],
    );
  }
}

class NewChatScreen extends StatelessWidget {
  const NewChatScreen({super.key});

  Future<void> _openWith(BuildContext context, int userId) async {
    try {
      final chat = await context.read<ChatStore>().openPrivateWith(userId);
      if (!context.mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myId = context.read<ChatStore>().myId!;
    return Scaffold(
      appBar: AppBar(title: const Text('New message')),
      body: UserSearch(
        onTap: (u) => _openWith(context, u.id),
        header: Column(children: [
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.group_add)),
            title: const Text('New group'),
            onTap: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const NewGroupScreen())),
          ),
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.bookmark)),
            title: const Text('Saved Messages'),
            onTap: () => _openWith(context, myId),
          ),
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.link)),
            title: const Text('Join group with invite code'),
            onTap: () => showJoinGroupDialog(context),
          ),
          const Divider(height: 1),
        ]),
      ),
    );
  }
}

Future<void> showJoinGroupDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Join a group'),
      content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'Paste invite code')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Next')),
      ],
    ),
  );
  if (code == null || code.isEmpty || !context.mounted) return;
  final store = context.read<ChatStore>();
  try {
    final p = await store.invitePreview(code.split('/').last);
    if (!context.mounted) return;
    if (p['is_member'] == true) {
      final chat = await store.getChat((p['chat_id'] as num).toInt());
      if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
      return;
    }
    final ok = await confirm(context, p['title'] as String, '${p['member_count']} members\n\n${p['description'] ?? ''}'.trim(), ok: 'Join group');
    if (!ok || !context.mounted) return;
    final chat = await store.joinByInvite(code.split('/').last);
    if (context.mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final Map<int, AppUser> _selected = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_selected.isEmpty ? 'Add members' : '${_selected.length} selected')),
      body: Column(children: [
        if (_selected.isNotEmpty)
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: _selected.values
                  .map((u) => Padding(
                        padding: const EdgeInsets.all(4),
                        child: InputChip(
                          avatar: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute, size: 24),
                          label: Text(u.firstName.isEmpty ? u.name : u.firstName),
                          onDeleted: () => setState(() => _selected.remove(u.id)),
                        ),
                      ))
                  .toList(),
            ),
          ),
        Expanded(
          child: UserSearch(
            selectedIds: _selected.keys.toSet(),
            onTap: (u) => setState(() {
              if (_selected.containsKey(u.id)) {
                _selected.remove(u.id);
              } else {
                _selected[u.id] = u;
              }
            }),
          ),
        ),
      ]),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _GroupDetailsScreen(members: _selected.values.toList()))),
        child: const Icon(Icons.arrow_forward),
      ),
    );
  }
}

class _GroupDetailsScreen extends StatefulWidget {
  const _GroupDetailsScreen({required this.members});
  final List<AppUser> members;

  @override
  State<_GroupDetailsScreen> createState() => _GroupDetailsScreenState();
}

class _GroupDetailsScreenState extends State<_GroupDetailsScreen> {
  final _title = TextEditingController();
  String? _avatar;
  bool _busy = false;

  Future<void> _create() async {
    if (_title.text.trim().isEmpty) {
      showInfo(context, 'Enter a group name');
      return;
    }
    setState(() => _busy = true);
    try {
      final (chat, skipped) = await context.read<ChatStore>().createGroup(
            _title.text.trim(),
            widget.members.map((u) => u.id).toList(),
            avatarPath: _avatar,
          );
      if (!mounted) return;
      if (skipped.isNotEmpty) {
        showInfo(context, '${skipped.length} people could not be added because of their privacy settings. Share the invite code with them.');
      }
      Navigator.of(context).popUntil((r) => r.isFirst);
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            GestureDetector(
              onTap: () async {
                final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
                if (x != null) setState(() => _avatar = x.path);
              },
              child: CircleAvatar(
                radius: 32,
                backgroundColor: const Color(0xFF2AABEE),
                backgroundImage: _avatar != null ? FileImage(File(_avatar!)) : null,
                child: _avatar == null ? const Icon(Icons.add_a_photo, color: Colors.white) : null,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: _title,
                autofocus: true,
                maxLength: 128,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Group name'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Text('${widget.members.length} members', style: const TextStyle(fontWeight: FontWeight.w600)),
          ...widget.members.map((u) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute, size: 40),
                title: Text(u.name),
              )),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _busy ? null : _create,
        child: _busy ? const CircularProgressIndicator(color: Colors.white) : const Icon(Icons.check),
      ),
    );
  }
}
