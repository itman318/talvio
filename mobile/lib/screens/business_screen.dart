import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/premium.dart';

/// Quick replies, cached for the composer ("/" in any chat shows them).
class QuickReplies {
  static List<Map<String, dynamic>> list = [];
  static bool _loaded = false;

  static Future<void> load(AppServices s, {bool force = false}) async {
    if (_loaded && !force) return;
    try {
      list = (await s.api.get('/me/quick-replies') as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      _loaded = true;
    } catch (_) {}
  }

  /// Replies whose shortcut starts with what's typed after "/".
  static List<Map<String, dynamic>> match(String typed) {
    if (!typed.startsWith('/') || typed.contains(' ') || typed.contains('\n')) return const [];
    final q = typed.substring(1).toLowerCase();
    return list.where((r) => '${r['shortcut']}'.startsWith(q)).take(6).toList();
  }
}

const _days = [('mon', 'Monday'), ('tue', 'Tuesday'), ('wed', 'Wednesday'), ('thu', 'Thursday'), ('fri', 'Friday'), ('sat', 'Saturday'), ('sun', 'Sunday')];

/// Settings → Talvio Business: greeting, away message, working hours, quick replies.
class BusinessScreen extends StatefulWidget {
  const BusinessScreen({super.key});

  @override
  State<BusinessScreen> createState() => _BusinessScreenState();
}

class _BusinessScreenState extends State<BusinessScreen> {
  Map<String, dynamic>? _s;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppServices>();
    try {
      final s = Map<String, dynamic>.from(await api.api.get('/me/business') as Map);
      await QuickReplies.load(api, force: true);
      if (mounted) setState(() => _s = s);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<bool> _save(Map<String, dynamic> patch) async {
    try {
      final s = Map<String, dynamic>.from(await context.read<AppServices>().api.put('/me/business', {
        ...patch,
        'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
      }) as Map);
      if (mounted) setState(() => _s = s);
      return true;
    } catch (e) {
      if (mounted) showError(context, e);
      return false;
    }
  }

  Future<String?> _editText(String title, String current, String hint) async {
    final c = TextEditingController(text: current);
    final r = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, minLines: 3, maxLines: 8, maxLength: 1000, decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    return r;
  }

  Future<void> _toggle(String key, String textKey, bool v, String title, String hint) async {
    if (v && '${_s![textKey]}'.trim().isEmpty) {
      final t = await _editText(title, '', hint);
      if (t == null || t.isEmpty) return;
      await _save({key: true, textKey: t});
      return;
    }
    await _save({key: v});
  }

  String _fmt(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  String _hoursSummary(Map hours) {
    if (hours.isEmpty) return 'Open 24/7';
    final open = _days.where((d) => (hours[d.$1] as List?)?.isNotEmpty ?? false).length;
    return '$open day${open == 1 ? '' : 's'} a week';
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      appBar: AppBar(title: const Text('Talvio Business')),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.only(bottom: 32), children: [
              Container(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(20)),
                child: const Row(children: [
                  Icon(Icons.storefront_rounded, color: Colors.white, size: 34),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text('Answer customers faster: greet new people, reply when you’re away and send saved answers with “/”.',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, height: 1.35)),
                  ),
                ]),
              ),
              SettingsGroup(title: 'Greeting message', children: [
                SettingsSwitchTile(
                  icon: Icons.waving_hand_rounded,
                  color: Brand.amber,
                  title: 'Greet new customers',
                  subtitle: 'Sent automatically when someone writes to you for the first time',
                  value: s['greeting_on'] == true,
                  onChanged: (v) => _toggle('greeting_on', 'greeting_text', v, 'Greeting message', 'Hi! Thanks for reaching out — how can we help?'),
                ),
                SettingsTile(
                  icon: Icons.edit_note_rounded,
                  color: Brand.sky,
                  title: 'Message',
                  subtitle: '${s['greeting_text']}'.isEmpty ? 'Not written yet' : '${s['greeting_text']}',
                  onTap: () async {
                    final t = await _editText('Greeting message', '${s['greeting_text']}', 'Hi! Thanks for reaching out — how can we help?');
                    if (t != null && t.isNotEmpty) await _save({'greeting_text': t});
                  },
                ),
                SettingsTile(
                  icon: Icons.hourglass_bottom_rounded,
                  color: Brand.violet,
                  title: 'Greet again after',
                  trailing: '${s['greeting_days']} day${s['greeting_days'] == 1 ? '' : 's'} of silence',
                  onTap: () async {
                    final d = await showModalBottomSheet<int>(
                      context: context,
                      builder: (c) => SafeArea(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          for (final n in const [1, 7, 14, 28])
                            ListTile(title: Text('$n day${n == 1 ? '' : 's'}'), trailing: s['greeting_days'] == n ? const Icon(Icons.check_rounded, color: Brand.primary) : null, onTap: () => Navigator.pop(c, n)),
                        ]),
                      ),
                    );
                    if (d != null) await _save({'greeting_days': d});
                  },
                ),
              ]),
              SettingsGroup(title: 'Away message', children: [
                SettingsSwitchTile(
                  icon: Icons.nightlight_round,
                  color: Brand.violet,
                  title: 'Reply when I’m away',
                  subtitle: 'Once every 6 hours per person',
                  value: s['away_on'] == true,
                  onChanged: (v) => _toggle('away_on', 'away_text', v, 'Away message', 'We’re closed right now and will reply as soon as we open.'),
                ),
                SettingsTile(
                  icon: Icons.edit_note_rounded,
                  color: Brand.sky,
                  title: 'Message',
                  subtitle: '${s['away_text']}'.isEmpty ? 'Not written yet' : '${s['away_text']}',
                  onTap: () async {
                    final t = await _editText('Away message', '${s['away_text']}', 'We’re closed right now and will reply as soon as we open.');
                    if (t != null && t.isNotEmpty) await _save({'away_text': t});
                  },
                ),
                SettingsTile(
                  icon: Icons.schedule_rounded,
                  color: Brand.green,
                  title: 'Send it',
                  trailing: const {'always': 'Always', 'outside_hours': 'Outside working hours', 'offline': 'When I’m offline'}[s['away_mode']] ?? '',
                  onTap: () async {
                    final m = await showModalBottomSheet<String>(
                      context: context,
                      builder: (c) => SafeArea(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          for (final o in const [('outside_hours', 'Outside working hours'), ('offline', 'When I’m offline'), ('always', 'Always')])
                            ListTile(title: Text(o.$2), trailing: s['away_mode'] == o.$1 ? const Icon(Icons.check_rounded, color: Brand.primary) : null, onTap: () => Navigator.pop(c, o.$1)),
                        ]),
                      ),
                    );
                    if (m != null) await _save({'away_mode': m});
                  },
                ),
              ]),
              SettingsGroup(title: 'Working hours', children: [
                SettingsTile(
                  icon: Icons.access_time_filled_rounded,
                  color: Brand.rose,
                  title: 'Opening hours',
                  trailing: _hoursSummary(Map.from(s['hours'] as Map? ?? {})),
                  onTap: () async {
                    final h = await Navigator.push<Map<String, dynamic>>(
                      context,
                      MaterialPageRoute(builder: (_) => _HoursScreen(hours: Map<String, dynamic>.from(s['hours'] as Map? ?? {}), fmt: _fmt)),
                    );
                    if (h != null) await _save({'hours': h});
                  },
                ),
              ]),
              SettingsGroup(title: 'Quick replies', children: [
                for (final r in QuickReplies.list)
                  SettingsTile(
                    icon: Icons.bolt_rounded,
                    color: Brand.primary,
                    title: '/${r['shortcut']}',
                    subtitle: '${r['text']}',
                    onTap: () => _editReply(r),
                  ),
                SettingsTile(icon: Icons.add_rounded, color: Brand.green, title: 'New quick reply', onTap: () => _editReply(null)),
              ]),
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 2, 22, 0),
                child: Text('In any chat, type “/” and pick a quick reply — or type its shortcut, like /price.', style: TextStyle(color: Brand.muted, fontSize: 12.5, height: 1.35)),
              ),
            ]),
    );
  }

  Future<void> _editReply(Map<String, dynamic>? r) async {
    final sc = TextEditingController(text: r == null ? '' : '${r['shortcut']}');
    final tx = TextEditingController(text: r == null ? '' : '${r['text']}');
    final api = context.read<AppServices>();
    final res = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(r == null ? 'New quick reply' : 'Quick reply'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: sc, autofocus: r == null, decoration: const InputDecoration(prefixText: '/', labelText: 'Shortcut', hintText: 'price')),
          const SizedBox(height: 8),
          TextField(controller: tx, minLines: 3, maxLines: 8, maxLength: 4000, decoration: const InputDecoration(labelText: 'Message')),
        ]),
        actions: [
          if (r != null) TextButton(onPressed: () => Navigator.pop(d, 'delete'), child: const Text('Delete', style: TextStyle(color: Color(0xFFE5484D)))),
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, 'save'), child: const Text('Save')),
        ],
      ),
    );
    try {
      if (res == 'delete' && r != null) await api.api.delete('/me/quick-replies/${r['id']}');
      if (res == 'save') {
        final body = {'shortcut': sc.text.trim(), 'text': tx.text.trim()};
        r == null ? await api.api.post('/me/quick-replies', body) : await api.api.put('/me/quick-replies/${r['id']}', body);
      }
      if (res != null) {
        await QuickReplies.load(api, force: true);
        if (mounted) setState(() {});
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
    sc.dispose();
    tx.dispose();
  }
}

class _HoursScreen extends StatefulWidget {
  const _HoursScreen({required this.hours, required this.fmt});
  final Map<String, dynamic> hours;
  final String Function(int) fmt;

  @override
  State<_HoursScreen> createState() => _HoursScreenState();
}

class _HoursScreenState extends State<_HoursScreen> {
  late final Map<String, List<int>?> _h = {
    for (final d in _days)
      d.$1: ((widget.hours[d.$1] as List?)?.isNotEmpty ?? false) ? [((widget.hours[d.$1] as List).first as List)[0] as int, ((widget.hours[d.$1] as List).first as List)[1] as int] : null,
  };
  late bool _always = widget.hours.isEmpty;

  Future<int?> _pick(int m) async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60));
    return t == null ? null : t.hour * 60 + t.minute;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Opening hours'), actions: [
        TextButton(
          onPressed: () {
            if (_always) {
              Navigator.pop(context, <String, dynamic>{});
              return;
            }
            Navigator.pop(context, {
              for (final e in _h.entries)
                if (e.value != null) e.key: [e.value],
            });
          },
          child: const Text('Save'),
        ),
      ]),
      body: ListView(children: [
        SettingsGroup(children: [
          SettingsSwitchTile(icon: Icons.all_inclusive_rounded, color: Brand.green, title: 'Open 24/7', value: _always, onChanged: (v) => setState(() => _always = v)),
        ]),
        if (!_always)
          SettingsGroup(title: 'Days', children: [
            for (final d in _days)
              ListTile(
                title: Text(d.$2, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: _h[d.$1] == null
                    ? const Text('Closed')
                    : InkWell(
                        onTap: () async {
                          final a = await _pick(_h[d.$1]![0]);
                          if (a == null || !mounted) return;
                          final b = await _pick(_h[d.$1]![1]);
                          if (b == null) return;
                          if (b <= a) {
                            if (mounted) showInfo(context, 'Closing time must be after opening time');
                            return;
                          }
                          setState(() => _h[d.$1] = [a, b]);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text('${widget.fmt(_h[d.$1]![0])} – ${widget.fmt(_h[d.$1]![1])}  ✎', style: const TextStyle(color: Brand.primary, fontWeight: FontWeight.w700)),
                        ),
                      ),
                trailing: Switch(value: _h[d.$1] != null, onChanged: (v) => setState(() => _h[d.$1] = v ? [540, 1080] : null)),
              ),
          ]),
      ]),
    );
  }
}
