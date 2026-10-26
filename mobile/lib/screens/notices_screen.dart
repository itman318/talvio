import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/mascot.dart';
import 'chat_screen.dart';
import 'folder_support_screens.dart' show TicketScreen;
import 'settings_screens.dart' show SessionsScreen;
import 'login_activity_screen.dart';

/// Talvio notifications: new logins, security events, groups you were added to, admin rights,
/// support replies and payments — newest first. Opening the screen marks them as read.
class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key});

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen> {
  List<Map<String, dynamic>>? _items;
  late final ChatStore _store;

  static const _look = <String, (IconData, Color)>{
    'login': (Icons.devices_rounded, Brand.sky),
    'security': (Icons.shield_rounded, Color(0xFFE5484D)),
    'group': (Icons.groups_rounded, Brand.green),
    'admin': (Icons.admin_panel_settings_rounded, Brand.violet),
    'support': (Icons.support_agent_rounded, Brand.primary),
    'payment': (Icons.payments_rounded, Brand.amber),
    'account': (Icons.person_rounded, Color(0xFF5E6B8C)),
    'system': (Icons.campaign_rounded, Brand.rose),
  };

  @override
  void initState() {
    super.initState();
    _store = context.read<ChatStore>();
    _store.lastNotice.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _store.lastNotice.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<AppServices>().api;
    try {
      final r = Map<String, dynamic>.from(await api.get('/notices') as Map);
      if (!mounted) return;
      setState(() => _items = (r['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList());
      if ((r['unread'] as num? ?? 0) > 0) {
        await api.post('/notices/read');
      }
      _store.noticeUnread.value = 0;
    } catch (e) {
      if (mounted) {
        setState(() => _items ??= []);
        showError(context, e);
      }
    }
  }

  Future<void> _open(Map<String, dynamic> n) async {
    final data = Map<String, dynamic>.from((n['data'] as Map?) ?? {});
    final kind = '${n['kind']}';
    Widget? page;
    if (data['chat_id'] != null) {
      final id = (data['chat_id'] as num).toInt();
      final chat = _store.chatById(id);
      if (chat == null) {
        showInfo(context, 'You are no longer in this chat');
        return;
      }
      page = ChatScreen(chatId: id, initial: chat);
    } else if (data['ticket_id'] != null) {
      page = TicketScreen(ticketId: (data['ticket_id'] as num).toInt());
    } else if (kind == 'login') {
      page = const SessionsScreen();
    } else if (kind == 'security') {
      page = const LoginActivityScreen();
    }
    if (page != null) await Navigator.push(context, MaterialPageRoute(builder: (_) => page!));
  }

  Future<void> _clearAll() async {
    if (!await confirm(context, 'Clear all notifications?', 'They will be removed from this list on all your devices.', ok: 'Clear')) return;
    if (!mounted) return;
    try {
      await context.read<AppServices>().api.delete('/notices');
      if (mounted) setState(() => _items = []);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  String _day(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final rows = <Widget>[];
    String? lastDay;
    for (final n in items ?? const <Map<String, dynamic>>[]) {
      final at = DateTime.tryParse('${n['created_at']}')?.toLocal() ?? DateTime.now();
      final day = _day(at);
      if (day != lastDay) {
        lastDay = day;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 6),
          child: Text(day.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Brand.muted)),
        ));
      }
      final (icon, color) = _look['${n['kind']}'] ?? _look['system']!;
      final unread = n['read'] != true;
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
        child: Material(
          color: unread ? Brand.primary.withValues(alpha: dark ? 0.12 : 0.06) : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => _open(n),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(13)),
                  child: Icon(icon, color: color, size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text('${n['title']}', style: TextStyle(fontWeight: unread ? FontWeight.w800 : FontWeight.w700, fontSize: 14.5))),
                      Text(messageTime(at), style: const TextStyle(fontSize: 11.5, color: Brand.muted)),
                    ]),
                    if ('${n['body'] ?? ''}'.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text('${n['body']}', style: TextStyle(fontSize: 13, height: 1.35, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ],
                  ]),
                ),
                if (unread)
                  Padding(padding: const EdgeInsets.only(left: 6, top: 4), child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: Brand.rose, shape: BoxShape.circle))),
              ]),
            ),
          ),
        ),
      ));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications'), actions: [
        if ((items ?? []).isNotEmpty) IconButton(tooltip: 'Clear all', icon: const Icon(Icons.delete_sweep_outlined), onPressed: _clearAll),
      ]),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: items.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 90),
                      TaviEmptyState(
                        pose: TaviPose.sleep,
                        title: 'All quiet',
                        text: 'New logins to your account, groups you are added to, admin rights, support replies and payments show up here.',
                      ),
                    ])
                  : ListView(padding: const EdgeInsets.only(bottom: 24), children: rows),
            ),
    );
  }
}
