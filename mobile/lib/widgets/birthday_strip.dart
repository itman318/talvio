import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../screens/chat_screen.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'avatar.dart';

/// Top of the chat list: contacts whose birthday is today or coming up this week.
class BirthdayStrip extends StatefulWidget {
  const BirthdayStrip({super.key});

  @override
  State<BirthdayStrip> createState() => _BirthdayStripState();
}

class _BirthdayStripState extends State<BirthdayStrip> {
  static List<(AppUser, int)>? _cache;
  static String? _cacheDay;
  bool _hidden = false;

  String get _today {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getString('bday_hidden') == _today) {
        if (mounted) setState(() => _hidden = true);
        return;
      }
      if (!mounted) return;
      final store = context.read<ChatStore>();
      final key = '$_today:${store.myId}'; // per day and per account
      if (_cacheDay != key) {
        _cache = null;
        _cache = await store.upcomingBirthdays();
        _cacheDay = key;
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _hide() async {
    setState(() => _hidden = true);
    try {
      (await SharedPreferences.getInstance()).setString('bday_hidden', _today);
    } catch (_) {}
  }

  Future<void> _wish(AppUser u) async {
    try {
      final chat = await context.read<ChatStore>().openPrivateWith(u.id);
      if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _cache;
    if (_hidden || list == null || list.isEmpty) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final today = list.where((x) => x.$2 == 0).toList();
    final first = (today.isNotEmpty ? today : list).first;
    final name = first.$1.firstName.isEmpty ? first.$1.name : first.$1.firstName;
    final others = list.length - 1;
    final title = today.isNotEmpty
        ? (today.length == 1 ? 'It’s $name’s birthday today 🎉' : '$name and ${today.length - 1} more have a birthday today 🎉')
        : '$name’s birthday is ${first.$2 == 1 ? 'tomorrow' : 'in ${first.$2} days'}';
    final sub = today.isNotEmpty ? 'Tap to send a wish' : (others > 0 ? '+$others more this week' : 'Tap to open the chat');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => list.length == 1 || today.length == 1 ? _wish(first.$1) : _showAll(list),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), gradient: Brand.auroraSoft(dark)),
            child: Row(children: [
              Stack(clipBehavior: Clip.none, children: [
                Avatar(id: first.$1.id, name: first.$1.name, url: first.$1.avatarAbsolute, size: 40),
                const Positioned(right: -6, bottom: -4, child: Text('🎂', style: TextStyle(fontSize: 18))),
              ]),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(sub, style: const TextStyle(color: Brand.muted, fontSize: 12.5)),
                ]),
              ),
              IconButton(tooltip: 'Hide for today', icon: const Icon(Icons.close_rounded, size: 18), onPressed: _hide),
            ]),
          ),
        ),
      ),
    );
  }

  void _showAll(List<(AppUser, int)> list) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Birthdays this week', style: TextStyle(fontWeight: FontWeight.w700))),
          for (final (u, days) in list)
            ListTile(
              leading: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute, size: 40),
              title: Text(u.name),
              subtitle: Text(days == 0 ? 'Today 🎉' : (days == 1 ? 'Tomorrow' : 'In $days days · ${u.birthday?.label ?? ''}')),
              trailing: const Icon(Icons.chat_bubble_outline_rounded),
              onTap: () {
                Navigator.pop(ctx);
                _wish(u);
              },
            ),
        ]),
      ),
    );
  }
}
