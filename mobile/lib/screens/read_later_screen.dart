import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/mascot.dart';
import '../widgets/message_extras.dart' show RemindersScreen;
import 'chat_screen.dart';

/// Messages saved with "Read later" (on all my devices), newest first.
class ReadLaterScreen extends StatefulWidget {
  const ReadLaterScreen({super.key});

  @override
  State<ReadLaterScreen> createState() => _ReadLaterScreenState();
}

class _ReadLaterScreenState extends State<ReadLaterScreen> {
  List<Map<String, dynamic>>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await context.read<ChatStore>().loadBookmarks();
      if (mounted) setState(() => _items = l);
    } catch (e) {
      if (mounted) {
        setState(() => _items = []);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final store = context.watch<ChatStore>();
    final visible = items?.where((i) => store.bookmarked.contains(((i['message'] as Map)['id'] as num).toInt())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Read later'), actions: [
        IconButton(
          tooltip: 'Reminders',
          icon: const Icon(Icons.alarm_rounded),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RemindersScreen())),
        ),
      ]),
      body: visible == null
          ? const Center(child: CircularProgressIndicator())
          : visible.isEmpty
              ? const TaviEmptyState(
                  pose: TaviPose.sleep,
                  title: 'Nothing saved yet',
                  text: 'Tap a message → “Read later” to keep it here. It shows up on all your devices.',
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                    itemBuilder: (_, i) {
                      final it = visible[i];
                      final chat = Map<String, dynamic>.from(it['chat'] as Map);
                      final m = Message.fromJson(Map<String, dynamic>.from(it['message'] as Map));
                      final url = chat['avatar_url'] as String?;
                      return Dismissible(
                        key: ValueKey(m.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: const Color(0xFFE5484D),
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(Icons.bookmark_remove_rounded, color: Colors.white),
                        ),
                        onDismissed: (_) => store.setBookmark(m, false).catchError((_) {}),
                        child: ListTile(
                          leading: Avatar(id: (chat['id'] as num).toInt(), name: '${chat['title']}', url: url == null ? null : AppConfig.absolute(url), size: 46),
                          title: Text('${chat['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(m.preview, maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 2),
                            Text(
                              '${m.sender?.name ?? ''}${m.sender != null ? ' · ' : ''}${DateFormat('d MMM, HH:mm').format(m.createdAt)}',
                              style: const TextStyle(fontSize: 12, color: Brand.muted),
                            ),
                          ]),
                          isThreeLine: true,
                          onTap: () async {
                            final c = await store.getChat((chat['id'] as num).toInt());
                            if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: c.id, initial: c)));
                          },
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
