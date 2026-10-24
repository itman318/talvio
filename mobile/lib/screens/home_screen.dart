import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/prefs.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import 'channel_screens.dart';
import 'secret_screens.dart';
import '../state/secret_store.dart';
import 'chat_screen.dart';
import 'folder_support_screens.dart';
import 'link_device_screen.dart';
import 'new_chat_screen.dart';
import 'settings_screens.dart';
import 'story_screens.dart';
import '../theme/brand.dart';
import '../widgets/premium.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _searching = false;
  final _search = TextEditingController();
  int? _folderId; // null = all chats
  List<(Map<String, dynamic>, Message)> _found = [];
  bool _searchingMessages = false;
  Timer? _debounce;

  void _onSearch(String q) {
    setState(() {});
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _found = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _searchingMessages = true);
      try {
        final r = await context.read<ChatStore>().searchMessages(q.trim());
        if (mounted && _search.text.trim() == q.trim()) setState(() => _found = r);
      } catch (_) {
      } finally {
        if (mounted) setState(() => _searchingMessages = false);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _refresh(ChatStore store) async {
    try {
      await Future.wait([store.loadChats(), store.loadStories(), store.loadAnnouncements(), store.loadFolders()]);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _compose() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(leading: const Icon(Icons.person_outline), title: const Text('New message'), onTap: () => Navigator.pop(ctx, 'chat')),
          ListTile(leading: const Icon(Icons.group_add_outlined), title: const Text('New group'), onTap: () => Navigator.pop(ctx, 'group')),
          if (context.read<AuthState>().feature('channels'))
            ListTile(leading: const Icon(Icons.campaign_outlined), title: const Text('New channel'), onTap: () => Navigator.pop(ctx, 'channel')),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    final Widget page = switch (choice) {
      'group' => const NewGroupScreen(),
      'channel' => const NewChannelScreen(),
      _ => const NewChatScreen(),
    };
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  void _openSearch() => setState(() {
        _searching = true;
        _search.clear();
        _found = [];
      });

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ChatStore>();
    final auth = context.watch<AuthState>();
    final q = _search.text.trim().toLowerCase();
    ChatFolder? folder;
    for (final f in store.folders) {
      if (f.id == _folderId) folder = f;
    }
    final main = store.mainChats;
    final requests = q.isEmpty && folder == null ? store.requests : const <Chat>[];
    var chats = folder == null ? main : main.where(folder.matches).toList();
    if (q.isNotEmpty) chats = chats.where((c) => c.title.toLowerCase().contains(q)).toList();
    final showStories = q.isEmpty && folder == null && auth.feature('stories');
    final secrets = q.isEmpty && folder == null ? context.watch<SecretStore>().sortedChats : const <SecretChat>[];
    final showFound = q.length >= 2;

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Search chats and messages', border: InputBorder.none),
                onChanged: _onSearch,
              )
            : Row(children: [
                const BrandMark(size: 30),
                const SizedBox(width: 10),
                Text(store.connected || !store.chatsLoaded ? AppConfig.appName : 'Connecting…',
                    style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.4)),
              ]),
        actions: [
          if (_searching)
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              _searching = !_searching;
              _search.clear();
              _found = [];
            }),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              final Widget page = switch (v) {
                'archived' => const ArchivedChatsScreen(),
                'folders' => const FoldersScreen(),
                'support' => const SupportListScreen(),
                'scan' => const LinkDeviceScreen(anyCode: true),
                _ => const SettingsScreen(),
              };
              Navigator.push(context, MaterialPageRoute(builder: (_) => page));
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'scan', child: Text('Scan QR code')),
              PopupMenuItem(value: 'archived', child: Text('Archived chats')),
              PopupMenuItem(value: 'folders', child: Text('Chat folders')),
              PopupMenuItem(value: 'support', child: Text('Help & support')),
            ],
          ),
        ],
        bottom: store.folders.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(44),
                child: SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      _FolderChip(label: 'All', selected: _folderId == null, onTap: () => setState(() => _folderId = null)),
                      ...store.folders.map((f) {
                        final unread = store.mainChats.where(f.matches).where((c) => !c.isMuted).fold<int>(0, (s, c) => s + c.unreadCount);
                        return _FolderChip(
                          label: unread > 0 ? '${f.name}  $unread' : f.name,
                          selected: _folderId == f.id,
                          onTap: () => setState(() => _folderId = f.id),
                          onLongPress: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EditFolderScreen(folder: f))),
                        );
                      }),
                    ],
                  ),
                ),
              ),
      ),
      body: Column(
        children: [
          if (auth.updateAvailable)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.primaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: const Text('A new version of the app is available. Please update from the store.'),
            ),
          ...store.announcements.map((a) => Container(
                width: double.infinity,
                color: const Color(0xFFFFF4D6),
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                child: Row(children: [
                  const Icon(Icons.campaign, color: Colors.orange),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(a.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(a.body),
                    ]),
                  ),
                  IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => store.dismissAnnouncement(a).catchError((_) {})),
                ]),
              )),
          Expanded(
            child: !store.chatsLoaded
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: () => _refresh(store),
                    child: showFound
                        ? _searchResults(chats)
                        : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 96), // room above the floating button
                      itemCount: 1 + (requests.isEmpty ? 0 : 1) + chats.length + secrets.length + (showStories ? 1 : 0) + (chats.isEmpty && secrets.isEmpty ? 1 : 0),
                      itemBuilder: (ctx, i0) {
                        if (i0 == 0) return _searchPill();
                        if (requests.isNotEmpty && i0 == 1) return _requestsRow(requests);
                        final i = i0 - 1 - (requests.isEmpty ? 0 : 1);
                        if (showStories && i == 0) return const StoryBar();
                        final si = i - (showStories ? 1 : 0);
                        if (si < secrets.length) {
                          return SecretChatTile(chat: secrets[si]);
                        }
                        final idx = si - secrets.length;
                        if (idx >= chats.length) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 40),
                            child: q.isNotEmpty
                                ? const EmptyState(tali: 'think', title: 'No chats found', subtitle: 'Try another name.')
                                : folder == null
                                ? EmptyState(
                                    tali: 'hello',
                                    title: 'Say hello!',
                                    subtitle: 'Start a conversation with a friend, create a group or a channel.',
                                    action: 'Start chatting',
                                    onAction: _compose,
                                  )
                                : const EmptyState(tali: 'think', title: 'Nothing here yet', subtitle: 'Chats that match this folder will show up here.'),
                          );
                        }
                        return ChatTile(chat: chats[idx]);
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: AuroraFab(icon: Icons.edit_rounded, tooltip: 'New message', onPressed: _compose),
    );
  }
}

extension on _HomeScreenState {
  Widget _searchPill() {
    if (_searching) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Material(
        color: dark ? const Color(0xFF161A2E) : const Color(0xFFEBEDF4),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _openSearch,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(children: [
              Icon(Icons.search_rounded, size: 21, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Text('Search', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 15)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _requestsRow(List<Chat> requests) {
    final unread = requests.fold<int>(0, (a, c) => a + c.unreadCount);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(gradient: Brand.auroraSoft(Theme.of(context).brightness == Brightness.dark), borderRadius: BorderRadius.circular(18)),
        child: const Icon(Icons.mark_email_unread_rounded, color: Brand.rose),
      ),
      title: const Text('Message requests', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      subtitle: Text(
        requests.length == 1 ? '${requests.first.title} wants to message you' : '${requests.length} people want to message you',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: unread > 0 ? CountBadge(unread, muted: true) : const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RequestsScreen())),
    );
  }

  Widget _searchResults(List<Chat> chats) {
    return ListView(children: [
      if (chats.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Chats', style: TextStyle(fontWeight: FontWeight.w600))),
      ...chats.map((c) => ChatTile(chat: c)),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          const Text('Messages', style: TextStyle(fontWeight: FontWeight.w600)),
          if (_searchingMessages) const Padding(padding: EdgeInsets.only(left: 8), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
        ]),
      ),
      if (!_searchingMessages && _found.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No messages found')),
      ..._found.map((r) {
        final (chatInfo, m) = r;
        final title = '${chatInfo['title'] ?? ''}';
        final avatar = chatInfo['avatar_url'] as String?;
        return ListTile(
          leading: Avatar(id: (chatInfo['id'] as num).toInt(), name: title, url: avatar == null ? null : AppConfig.absolute(avatar)),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${m.sender != null && chatInfo['type'] != 'private' ? '${m.sender!.firstName}: ' : ''}${m.preview}',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(chatListTime(m.createdAt), style: const TextStyle(fontSize: 12)),
          onTap: () {
            final id = (chatInfo['id'] as num).toInt();
            Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: id, initial: context.read<ChatStore>().chatById(id))));
          },
        );
      }),
    ]);
  }
}

class _FolderChip extends StatelessWidget {
  const _FolderChip({required this.label, required this.selected, required this.onTap, this.onLongPress});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onTap()),
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
    final draft = context.watch<AppPrefs>().draft(chat.id);
    final typing = store.typingText(chat);
    final last = chat.lastMessage;
    final mine = last != null && last.senderId == store.myId && !last.isSystem;
    final unread = chat.unreadCount > 0 || chat.markedUnread;

    String preview = '';
    if (last != null) {
      if (last.isSystem) {
        preview = systemText(last, store);
      } else {
        final prefix = mine && !chat.isChannel ? 'You: ' : (chat.isGroup ? '${last.sender?.firstName ?? ''}: ' : '');
        preview = '$prefix${last.preview}';
      }
    }

    Widget? tick;
    if (mine && !chat.isSavedMessages && !chat.isChannel) {
      if (last.sendState == SendState.sending) {
        tick = const Icon(Icons.schedule, size: 14, color: Brand.muted);
      } else if (last.sendState == SendState.failed) {
        tick = const Icon(Icons.error, size: 15, color: Colors.red);
      } else {
        tick = Icon(last.id <= chat.deliveredUpTo ? Icons.done_all : Icons.done,
            size: 16, color: last.id <= chat.readUpTo ? Brand.primary : Brand.muted);
      }
    }

    final online = chat.peer?.online == true && !chat.isSavedMessages && !chat.isBot;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Stack(clipBehavior: Clip.none, children: [
        Avatar(
          id: chat.id,
          name: chat.title,
          url: chat.avatarAbsolute,
          size: 54,
          icon: chat.isSavedMessages ? Icons.bookmark : null,
        ),
        if (online)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: Brand.accent,
                shape: BoxShape.circle,
                border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2.5),
              ),
            ),
          ),
      ]),
      title: Row(
        children: [
          // The name takes all the room it needs; only the time/ticks stay on the right.
          Expanded(
            child: Row(children: [
              if (chat.isGroup) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.group, size: 16)),
              if (chat.isChannel) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.campaign, size: 16)),
              Flexible(
                child: Text(chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: unread ? FontWeight.w800 : FontWeight.w600, fontSize: 16, letterSpacing: -0.2)),
              ),
              if (chat.isVerified) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified, size: 16, color: Brand.primary)),
              if (chat.isMuted) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.volume_off, size: 15, color: Brand.faint)),
            ]),
          ),
          const SizedBox(width: 6),
          if (tick != null) Padding(padding: const EdgeInsets.only(right: 4), child: tick),
          if (last != null)
            Text(chatListTime(last.createdAt),
                style: TextStyle(fontSize: 12, color: unread && !chat.isMuted ? Brand.primary : Brand.muted, fontWeight: unread ? FontWeight.w700 : FontWeight.w500)),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: typing == null && draft != null && draft.trim().isNotEmpty
                ? Text.rich(
                    TextSpan(children: [
                      const TextSpan(text: 'Draft: ', style: TextStyle(color: Colors.red)),
                      TextSpan(text: draft.replaceAll('\n', ' ')),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : Text(
                    typing ?? preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typing != null ? const TextStyle(color: Brand.primary) : null,
                  ),
          ),
          if (chat.unreadMentions > 0)
            Container(
              margin: const EdgeInsets.only(left: 6),
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: Brand.primary, shape: BoxShape.circle),
              child: const Text('@', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          if (chat.unreadCount > 0)
            Padding(padding: const EdgeInsets.only(left: 6), child: CountBadge(chat.unreadCount, muted: chat.isMuted))
          else if (chat.markedUnread)
            Container(
              margin: const EdgeInsets.only(left: 6),
              width: 14,
              height: 14,
              decoration: BoxDecoration(color: chat.isMuted ? Brand.faint : Brand.primary, shape: BoxShape.circle),
            )
          else if (chat.isPinned)
            const Icon(Icons.push_pin, size: 16, color: Brand.faint),
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
          leading: Icon(chat.unreadCount > 0 || chat.markedUnread ? Icons.mark_chat_read_outlined : Icons.mark_chat_unread_outlined),
          title: Text(chat.unreadCount > 0 || chat.markedUnread ? 'Mark as read' : 'Mark as unread'),
          onTap: () => Navigator.pop(ctx, 'unread'),
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
          title: Text(chat.isChannel ? 'Leave channel' : (chat.isGroup ? 'Leave group' : 'Delete chat'), style: const TextStyle(color: Colors.red)),
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
      case 'unread':
        await store.setMarkedUnread(chat, !(chat.unreadCount > 0 || chat.markedUnread));
        break;
      case 'archive':
        await store.updateChatSettings(chat.id, {'is_archived': !chat.isArchived});
        break;
      case 'delete':
        final ok = await confirm(
          context,
          chat.isMulti ? 'Leave “${chat.title}”?' : 'Delete chat?',
          chat.isMulti ? 'You will stop receiving messages from “${chat.title}”.' : 'The chat history will be removed for you.',
          ok: chat.isMulti ? 'Leave' : 'Delete',
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
                    if (mounted) setState(() => _future = context.read<ChatStore>().loadArchived());
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


/// Chats → Message requests.
class RequestsScreen extends StatelessWidget {
  const RequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final list = context.watch<ChatStore>().requests;
    return Scaffold(
      appBar: AppBar(title: const Text('Message requests')),
      body: list.isEmpty
          ? const EmptyState(tali: 'cool', title: 'No requests', subtitle: 'Messages from people who are not in your contacts wait here, without notifications.')
          : ListView(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Text('These people are not in your contacts. Open a chat to accept, block or delete it.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
              ),
              ...list.map((c) => ChatTile(chat: c)),
            ]),
    );
  }
}
