import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/reminders.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'avatar.dart';

// ------------------------------------------------------------------ edit history
/// "edited" → the earlier versions of the message.
Future<void> showEditHistory(BuildContext context, Message m) async {
  final api = context.read<AppServices>().api;
  final fmt = DateFormat('d MMM, HH:mm');
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.55,
      child: FutureBuilder(
        future: api.get('/messages/${m.id}/edits'),
        builder: (ctx, snap) {
          if (snap.hasError) return Center(child: Text(friendlyError(snap.error!)));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final versions = ((snap.data as Map)['versions'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList().reversed.toList();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text('Edit history', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            for (final v in versions)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: v['current'] == true ? Brand.primary.withValues(alpha: 0.1) : Theme.of(ctx).colorScheme.surfaceContainerHighest,
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(v['current'] == true ? 'Now · ${fmt.format(DateTime.parse('${v['at']}').toLocal())}' : fmt.format(DateTime.parse('${v['at']}').toLocal()),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: v['current'] == true ? Brand.primary : Brand.muted)),
                  const SizedBox(height: 4),
                  Text('${v['text']}'.isEmpty ? '(no text)' : '${v['text']}'),
                ]),
              ),
          ]);
        },
      ),
    ),
  );
}

// ------------------------------------------------------------------ message info
/// Who got and read my message.
Future<void> showMessageInfo(BuildContext context, Message m) async {
  final store = context.read<ChatStore>();
  final fmt = DateFormat('d MMM, HH:mm');
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.6,
      child: FutureBuilder<Map<String, dynamic>>(
        future: store.messageInfo(m),
        builder: (ctx, snap) {
          if (snap.hasError) return Center(child: Text(friendlyError(snap.error!)));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          List<AppUser> users(String k) => ((snap.data![k] as List?) ?? const []).map((e) => AppUser.fromJson(Map<String, dynamic>.from(e as Map))).toList();
          final read = users('read'), delivered = users('delivered'), waiting = users('waiting'), played = users('played');
          Widget section(String title, IconData icon, Color color, List<AppUser> list) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                  child: Row(children: [
                    Icon(icon, size: 18, color: color),
                    const SizedBox(width: 6),
                    Text('$title · ${list.length}', style: TextStyle(fontWeight: FontWeight.w800, color: color)),
                  ]),
                ),
                for (final u in list)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Avatar(id: u.id, name: u.name, url: u.avatarAbsolute, size: 36),
                    title: Text(u.name),
                  ),
              ]);
          return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
            const Text('Message info', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Sent ${fmt.format(m.createdAt)}', style: const TextStyle(color: Brand.muted)),
            if (played.isNotEmpty) section(m.type == 'video_note' ? 'Watched' : 'Listened', Icons.mic_rounded, const Color(0xFF12A150), played),
            if (read.isNotEmpty) section('Read', Icons.done_all_rounded, Brand.accent, read),
            if (delivered.isNotEmpty) section('Delivered', Icons.done_all_rounded, Brand.muted, delivered),
            if (waiting.isNotEmpty) section('Not delivered yet', Icons.done_rounded, Brand.faint, waiting),
            if (read.isEmpty && delivered.isEmpty && waiting.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Nobody else is here yet'))),
          ]);
        },
      ),
    ),
  );
}

// ------------------------------------------------------------------ remind me
/// Message menu → Remind me: pick when, then a notification on this phone brings you back to the message.
Future<void> pickReminder(BuildContext context, Chat chat, Message m) async {
  final now = DateTime.now();
  final tonight = DateTime(now.year, now.month, now.day, 21);
  final tomorrow = DateTime(now.year, now.month, now.day + 1, 9);
  final options = <(String, DateTime)>[
    ('In 1 hour', now.add(const Duration(hours: 1))),
    ('In 3 hours', now.add(const Duration(hours: 3))),
    if (tonight.isAfter(now.add(const Duration(minutes: 30)))) ('Tonight at 9 PM', tonight),
    ('Tomorrow at 9 AM', tomorrow),
    ('Next week', DateTime(now.year, now.month, now.day + 7, 9)),
  ];
  final choice = await showModalBottomSheet<Object>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Align(alignment: Alignment.centerLeft, child: Text('Remind me', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
        ),
        for (final (label, at) in options)
          ListTile(
            leading: const Icon(Icons.alarm_rounded),
            title: Text(label),
            subtitle: Text(DateFormat('EEE d MMM, h:mm a').format(at)),
            onTap: () => Navigator.pop(ctx, at),
          ),
        ListTile(leading: const Icon(Icons.edit_calendar_rounded), title: const Text('Pick date & time'), onTap: () => Navigator.pop(ctx, 'custom')),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return;
  DateTime? at = choice is DateTime ? choice : null;
  if (choice == 'custom') {
    final d = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 365)), initialDate: now);
    if (d == null || !context.mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
    if (t == null) return;
    at = DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }
  if (at == null || !at.isAfter(DateTime.now())) {
    if (context.mounted) showInfo(context, 'Pick a time in the future');
    return;
  }
  final ok = await Reminders.add(Reminder(
    id: Reminders.newId(),
    chatId: chat.id,
    messageId: m.id,
    chatTitle: chat.title,
    preview: m.type == 'text' ? m.text : m.preview,
    at: at,
  ));
  if (context.mounted) {
    showInfo(context, ok ? 'I\'ll remind you ${DateFormat('EEE d MMM, h:mm a').format(at)}' : 'Allow notifications for Talvio to get reminders');
  }
}

/// Settings → Reminders.
class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  List<Reminder>? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await Reminders.upcoming();
    if (mounted) setState(() => _list = l);
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final fmt = DateFormat('EEE d MMM, h:mm a');
    return Scaffold(
      appBar: AppBar(title: const Text('Reminders')),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('No reminders.\nLong-press any message → Remind me.', textAlign: TextAlign.center, style: TextStyle(color: Brand.muted)),
                  ),
                )
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                  itemBuilder: (_, i) {
                    final r = list[i];
                    return ListTile(
                      leading: CircleAvatar(backgroundColor: Brand.primary.withValues(alpha: 0.12), child: const Icon(Icons.alarm_rounded, color: Brand.primary)),
                      title: Text(r.chatTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${fmt.format(r.at)}\n${r.preview}', maxLines: 2, overflow: TextOverflow.ellipsis),
                      isThreeLine: true,
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Cancel reminder',
                        onPressed: () async {
                          await Reminders.cancel(r.id);
                          _load();
                        },
                      ),
                    );
                  },
                ),
    );
  }
}

// ------------------------------------------------------------------ checklists
final _checkLine = RegExp(r'^(\s*)\[([ xX])\] (.*)$');

/// True when the message has checklist lines ("[ ] item" / "[x] item").
bool hasChecklist(String text) => text.split('\n').any((l) => _checkLine.hasMatch(l));

/// Text with tappable checkboxes. Only the sender can tick (it updates the message for everyone).
class ChecklistText extends StatelessWidget {
  const ChecklistText({super.key, required this.message, required this.canTick, this.style});
  final Message message;
  final bool canTick;
  final TextStyle? style;

  Future<void> _toggle(BuildContext context, int line) async {
    final lines = message.text.split('\n');
    final m = _checkLine.firstMatch(lines[line]);
    if (m == null) return;
    final done = m.group(2)!.toLowerCase() == 'x';
    lines[line] = '${m.group(1)}[${done ? ' ' : 'x'}] ${m.group(3)}';
    try {
      await context.read<ChatStore>().editMessage(message, lines.join('\n'));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final lines = message.text.split('\n');
    final items = lines.where((l) => _checkLine.hasMatch(l)).toList();
    final doneCount = items.where((l) => _checkLine.firstMatch(l)!.group(2)!.toLowerCase() == 'x').length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < lines.length; i++)
        if (_checkLine.firstMatch(lines[i]) case final m?)
          InkWell(
            onTap: canTick ? () => _toggle(context, i) : null,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.only(top: 1, right: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: m.group(2)!.toLowerCase() == 'x' ? Brand.aurora : null,
                    border: m.group(2)!.toLowerCase() == 'x' ? null : Border.all(color: (base.color ?? Brand.muted).withValues(alpha: 0.5), width: 1.6),
                  ),
                  child: m.group(2)!.toLowerCase() == 'x' ? const Icon(Icons.check_rounded, size: 14, color: Colors.white) : null,
                ),
                Flexible(
                  child: Text(
                    m.group(3)!,
                    style: base.copyWith(
                      decoration: m.group(2)!.toLowerCase() == 'x' ? TextDecoration.lineThrough : null,
                      color: m.group(2)!.toLowerCase() == 'x' ? base.color?.withValues(alpha: 0.55) : base.color,
                    ),
                  ),
                ),
              ]),
            ),
          )
        else if (lines[i].trim().isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(lines[i], style: base.copyWith(fontWeight: FontWeight.w700))),
      if (items.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('$doneCount of ${items.length} done', style: TextStyle(fontSize: 11.5, color: base.color?.withValues(alpha: 0.6))),
        ),
    ]);
  }
}

/// Composer → Checklist: title + items → "[ ] item" lines.
Future<String?> buildChecklist(BuildContext context) async {
  final title = TextEditingController();
  final items = <TextEditingController>[TextEditingController(), TextEditingController()];
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('New checklist', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          TextField(controller: title, decoration: const InputDecoration(hintText: 'Title (optional)')),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.4),
            child: ListView(shrinkWrap: true, children: [
              for (var i = 0; i < items.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: TextField(
                    controller: items[i],
                    autofocus: i == 0,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.radio_button_unchecked_rounded, size: 20),
                      hintText: 'Item ${i + 1}',
                    ),
                    onSubmitted: (_) {
                      if (i == items.length - 1 && items[i].text.trim().isNotEmpty) setSt(() => items.add(TextEditingController()));
                    },
                  ),
                ),
            ]),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: () => setSt(() => items.add(TextEditingController())), icon: const Icon(Icons.add), label: const Text('Add item')),
          ),
          FilledButton(
            onPressed: () {
              final list = items.map((c) => c.text.trim()).where((s) => s.isNotEmpty).toList();
              if (list.isEmpty) return;
              final t = title.text.trim();
              Navigator.pop(ctx, [if (t.isNotEmpty) t, ...list.map((s) => '[ ] $s')].join('\n'));
            },
            child: const Text('Send checklist'),
          ),
        ]),
      ),
    ),
  );
}

// ------------------------------------------------------------------ #tags (My Notes)
final tagRe = RegExp(r'(^|\s)#([\p{L}\p{N}_]{2,32})', unicode: true);

/// All #tags used in these messages, most used first.
List<String> tagsIn(Iterable<Message> messages) {
  final count = <String, int>{};
  for (final m in messages) {
    for (final t in tagRe.allMatches(m.text)) {
      final tag = t.group(2)!.toLowerCase();
      count[tag] = (count[tag] ?? 0) + 1;
    }
  }
  final l = count.keys.toList()..sort((a, b) => count[b]!.compareTo(count[a]!));
  return l;
}

bool messageHasTag(Message m, String tag) => tagRe.allMatches(m.text).any((t) => t.group(2)!.toLowerCase() == tag);

// ------------------------------------------------------------------ reaction burst
/// A little celebration when you react: the emoji pops and a few copies fly out.
void showReactionBurst(BuildContext context, String emoji, {Offset? at}) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  final size = MediaQuery.of(context).size;
  final center = at ?? Offset(size.width / 2, size.height * 0.45);
  late OverlayEntry entry;
  entry = OverlayEntry(builder: (_) => _Burst(emoji: emoji, center: center, onDone: () => entry.remove()));
  overlay.insert(entry);
}

class _Burst extends StatefulWidget {
  const _Burst({required this.emoji, required this.center, required this.onDone});
  final String emoji;
  final Offset center;
  final VoidCallback onDone;

  @override
  State<_Burst> createState() => _BurstState();
}

class _BurstState extends State<_Burst> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..forward().whenComplete(widget.onDone);
  final _rnd = math.Random();
  late final List<(double, double, double)> _parts = List.generate(9, (i) {
    final a = -math.pi / 2 + (i - 4) * 0.33 + (_rnd.nextDouble() - 0.5) * 0.2;
    return (a, 70 + _rnd.nextDouble() * 60, 0.45 + _rnd.nextDouble() * 0.35);
  });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = _c.value;
          final pop = Curves.elasticOut.transform((t * 1.6).clamp(0.0, 1.0));
          final fade = t < 0.7 ? 1.0 : (1 - t) / 0.3;
          return Stack(children: [
            Positioned(
              left: widget.center.dx - 40,
              top: widget.center.dy - 40,
              child: Opacity(
                opacity: fade.clamp(0.0, 1.0),
                child: Transform.scale(scale: 0.4 + pop * 1.1, child: SizedBox(width: 80, height: 80, child: Center(child: Text(widget.emoji, style: const TextStyle(fontSize: 48))))),
              ),
            ),
            for (final (angle, dist, scale) in _parts)
              Positioned(
                left: widget.center.dx + math.cos(angle) * dist * Curves.easeOut.transform(t) - 14,
                top: widget.center.dy + math.sin(angle) * dist * Curves.easeOut.transform(t) + 40 * t * t - 14,
                child: Opacity(
                  opacity: (1 - t).clamp(0.0, 1.0),
                  child: Transform.scale(scale: scale, child: Text(widget.emoji, style: const TextStyle(fontSize: 28))),
                ),
              ),
          ]);
        },
      ),
    );
  }
}
