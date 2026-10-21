import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import 'chat_screen.dart';
import 'new_chat_screen.dart';
import 'settings_screens.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _searching = false;
  final _search = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final auth = context.watch<AuthState>();
    final q = _search.text.trim().toLowerCase();
    final chats = q.isEmpty ? store.chats : store.chats.where((c) => c.title.toLowerCase().contains(q)).toList();

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search chats', border: InputBorder.none),
                onChanged: (_) => setState(() {}),
              )
            : Text(store.connected || !store.chatsLoaded ? 'Chats' : 'Connecting…'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              _search.clear();
            }),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'archived') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const ArchivedChatsScreen()));
              } else if (v == 'settings') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'archived', child: Text('Archived chats')),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (auth.updateAvailable)
            Container(
              width: double.infinity,
              color: const Color(0xFFE6F4FF),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: const Text('A new version of the app is available. Please update from the store.'),
            ),
          Expanded(
            child: !store.chatsLoaded
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: () => store.loadChats().catchError((e) {
                      if (context.mounted) showError(context, e);
                    }),
                    child: chats.isEmpty
                        ? ListView(children: const [
                            SizedBox(height: 140),
                            Icon(Icons.forum_outlined, size: 64, color: Colors.black26),
                            SizedBox(height: 12),
                            Center(child: Text('No chats yet.\nTap the pencil to start messaging.', textAlign: TextAlign.center)),
                          ])
                        : ListView.separated(
                            itemCount: chats.length,
                            separatorBuilder: (_, __) => const Divider(height: 1, indent: 80),
                            itemBuilder: (ctx, i) => ChatTile(chat: chats[i]),
                          ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NewChatScreen())),
        child: const Icon(Icons.edit),
      ),
    );
  }
}

class ChatTile extends StatelessWidget {
  const ChatTile({super.key, required this.chat});
  final Chat chat;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final typing = store.typingText(chat);
    final last = chat.lastMessage;
    final mine = last != null && last.senderId == store.myId && !last.isSystem;

    String preview = '';
    if (last != null) {
      if (last.isSystem) {
        preview = systemText(last, store);
      } else {
        final prefix = mine ? 'You: ' : (chat.isGroup ? '${last.sender?.firstName ?? ''}: ' : '');
        preview = '$prefix${last.preview}';
      }
    }

    Widget? tick;
    if (mine && last != null && !chat.isSavedMessages) {
      if (last.sendState == SendState.sending) {
        tick = const Icon(Icons.schedule, size: 14, color: Colors.black45);
      } else if (last.sendState == SendState.failed) {
        tick = const Icon(Icons.error, size: 15, color: Colors.red);
      } else {
        tick = Icon(last.id <= chat.deliveredUpTo ? Icons.done_all : Icons.done,
            size: 16, color: last.id <= chat.readUpTo ? const Color(0xFF2AABEE) : Colors.black45);
      }
    }

    return ListTile(
      leading: Avatar(
        id: chat.id,
        name: chat.title,
        url: chat.avatarAbsolute,
        size: 54,
        icon: chat.isSavedMessages ? Icons.bookmark : null,
      ),
      title: Row(
        children: [
          if (chat.isGroup) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.group, size: 16)),
          Flexible(child: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (chat.peer?.isVerified == true) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified, size: 16, color: Color(0xFF2AABEE))),
          if (chat.isMuted) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.volume_off, size: 15, color: Colors.black38)),
          const Spacer(),
          if (tick != null) Padding(padding: const EdgeInsets.only(right: 4), child: tick),
          if (last != null) Text(chatListTime(last.createdAt), style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              typing ?? preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typing != null ? const TextStyle(color: Color(0xFF2AABEE)) : null,
            ),
          ),
          if (chat.unreadCount > 0)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: chat.isMuted ? Colors.black38 : const Color(0xFF2AABEE),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('${chat.unreadCount > 999 ? '999+' : chat.unreadCount}', style: const TextStyle(color: Colors.white, fontSize: 12)),
            )
          else if (chat.isPinned)
            const Icon(Icons.push_pin, size: 16, color: Colors.black38),
        ],
      ),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat))),
      onLongPress: () => showChatActions(context, chat),
    );
  }
}

Future<void> showChatActions(BuildContext context, Chat chat) async {
  final store = context.read<ChatStore>();
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Wrap(children: [
        ListTile(
          leading: Icon(chat.isPinned ? Icons.push_pin_outlined : Icons.push_pin),
          title: Text(chat.isPinned ? 'Unpin' : 'Pin to top'),
          onTap: () => Navigator.pop(ctx, 'pin'),
        ),
        ListTile(
          leading: Icon(chat.isMuted ? Icons.volume_up : Icons.volume_off),
          title: Text(chat.isMuted ? 'Unmute' : 'Mute notifications'),
          onTap: () => Navigator.pop(ctx, 'mute'),
        ),
        ListTile(
          leading: Icon(chat.isArchived ? Icons.unarchive : Icons.archive),
          title: Text(chat.isArchived ? 'Unarchive' : 'Archive'),
          onTap: () => Navigator.pop(ctx, 'archive'),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline, color: Colors.red),
          title: Text(chat.isGroup ? 'Leave group' : 'Delete chat', style: const TextStyle(color: Colors.red)),
          onTap: () => Navigator.pop(ctx, 'delete'),
        ),
      ]),
    ),
  );
  if (action == null || !context.mounted) return;
  try {
    switch (action) {
      case 'pin':
        await store.updateChatSettings(chat.id, {'is_pinned': !chat.isPinned});
        break;
      case 'mute':
        await store.updateChatSettings(chat.id, {'muted_until': chat.isMuted ? null : 'forever'});
        break;
      case 'archive':
        await store.updateChatSettings(chat.id, {'is_archived': !chat.isArchived});
        break;
      case 'delete':
        final ok = await confirm(
          context,
          chat.isGroup ? 'Leave group?' : 'Delete chat?',
          chat.isGroup ? 'You will stop receiving messages from “${chat.title}”.' : 'The chat history will be removed for you.',
          ok: chat.isGroup ? 'Leave' : 'Delete',
          danger: true,
        );
        if (ok) await store.leaveOrDelete(chat.id);
        break;
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class ArchivedChatsScreen extends StatefulWidget {
  const ArchivedChatsScreen({super.key});

  @override
  State<ArchivedChatsScreen> createState() => _ArchivedChatsScreenState();
}

class _ArchivedChatsScreenState extends State<ArchivedChatsScreen> {
  late Future<List<Chat>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<ChatStore>().loadArchived();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Archived chats')),
      body: FutureBuilder<List<Chat>>(
        future: _future,
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return snap.hasError ? Center(child: Text('${snap.error}')) : const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          if (list.isEmpty) return const Center(child: Text('No archived chats'));
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) => ListTile(
              leading: Avatar(id: list[i].id, name: list[i].title, url: list[i].avatarAbsolute),
              title: Text(list[i].title),
              subtitle: Text(list[i].lastMessage?.preview ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.unarchive),
                tooltip: 'Unarchive',
                onPressed: () async {
                  try {
                    await context.read<ChatStore>().updateChatSettings(list[i].id, {'is_archived': false});
                    setState(() => _future = context.read<ChatStore>().loadArchived());
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: list[i].id, initial: list[i]))),
            ),
          );
        },
      ),
    );
  }
}
