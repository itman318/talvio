import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../theme/brand.dart';

/// Pick up to 10 chats to forward messages to.
class ForwardScreen extends StatefulWidget {
  const ForwardScreen({super.key, required this.fromChatId, required this.messageIds});

  final int fromChatId;
  final List<int> messageIds;

  @override
  State<ForwardScreen> createState() => _ForwardScreenState();
}

class _ForwardScreenState extends State<ForwardScreen> {
  final Set<int> _selected = {};
  bool _busy = false;

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await context.read<ChatStore>().forward(widget.fromChatId, widget.messageIds, _selected.toList());
      if (!mounted) return;
      showInfo(context, 'Forwarded');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chats = context.watch<ChatStore>().chats.where((c) => !c.isSuspended && c.peer?.blocked != true).toList();
    return Scaffold(
      appBar: AppBar(title: Text(_selected.isEmpty ? 'Forward to…' : '${_selected.length} selected')),
      body: ListView.builder(
        itemCount: chats.length,
        itemBuilder: (_, i) {
          final c = chats[i];
          final selected = _selected.contains(c.id);
          return ListTile(
            leading: Avatar(id: c.id, name: c.title, url: c.avatarAbsolute, icon: c.isSavedMessages ? Icons.bookmark : null),
            title: Text(c.title),
            trailing: Icon(selected ? Icons.check_circle : Icons.circle_outlined, color: selected ? Brand.primary : Colors.black26),
            onTap: () => setState(() {
              if (selected) {
                _selected.remove(c.id);
              } else if (_selected.length < 10) {
                _selected.add(c.id);
              }
            }),
          );
        },
      ),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton(
              onPressed: _busy ? null : _send,
              child: _busy ? const CircularProgressIndicator(color: Colors.white) : const Icon(Icons.arrow_upward_rounded),
            ),
    );
  }
}
