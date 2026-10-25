import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/premium.dart';
import 'settings_screens.dart' show TwoStepScreen;

/// Settings → Login activity: every login of the last 60 days, plus blocked attempts
/// (someone had the code but not the two-step password, or typed a wrong password).
class LoginActivityScreen extends StatefulWidget {
  const LoginActivityScreen({super.key});

  @override
  State<LoginActivityScreen> createState() => _LoginActivityScreenState();
}

class _LoginActivityScreenState extends State<LoginActivityScreen> {
  List<Map<String, dynamic>>? _events;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppServices>().api.get('/me/login-activity') as List;
      if (mounted) setState(() => _events = r.map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } catch (e) {
      if (mounted) {
        setState(() => _events = []);
        showError(context, e);
      }
    }
  }

  Future<void> _notMe(Map<String, dynamic> e) async {
    final ok = await confirm(
      context,
      'Log this device out?',
      '“${_device(e)}” will be logged out right away. Then turn on two-step verification so a code alone isn’t enough to log in.',
      ok: 'Log out',
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      await context.read<AppServices>().api.post('/me/login-activity/${e['session_id']}/not-me');
      await _load();
      if (!mounted) return;
      showInfo(context, 'That device was logged out');
      Navigator.push(context, MaterialPageRoute(builder: (_) => const TwoStepScreen()));
    } catch (err) {
      if (mounted) showError(context, err);
    }
  }

  static String _device(Map<String, dynamic> e) {
    final name = '${e['device_name'] ?? ''}'.trim();
    final platform = '${e['platform'] ?? ''}';
    final p = {'android': 'Android', 'ios': 'iPhone', 'web': 'Web browser', 'desktop': 'Computer'}[platform] ?? '';
    if (name.isEmpty) return p.isEmpty ? 'Unknown device' : p;
    return p.isEmpty ? name : '$name · $p';
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    final fmt = DateFormat('EEE d MMM, HH:mm');
    final blocked = events?.where((e) => e['kind'] != 'login').length ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Login activity')),
      body: events == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: (blocked > 0 ? Brand.amber : Brand.green).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(children: [
                    Icon(blocked > 0 ? Icons.gpp_maybe_rounded : Icons.verified_user_rounded, color: blocked > 0 ? Brand.amber : Brand.green, size: 34),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        blocked > 0
                            ? '$blocked blocked login attempt${blocked == 1 ? '' : 's'} in the last 60 days. If it wasn’t you, keep your login codes private and use a strong two-step password.'
                            : 'No suspicious activity. You’ll get an alert whenever a new device logs in.',
                        style: const TextStyle(fontSize: 13.5, height: 1.35),
                      ),
                    ),
                  ]),
                ),
                SettingsGroup(title: 'Last 60 days', children: [
                  if (events.isEmpty) const ListTile(title: Text('Nothing yet')),
                  for (final e in events) _row(e, fmt),
                ]),
              ]),
            ),
    );
  }

  Widget _row(Map<String, dynamic> e, DateFormat fmt) {
    final kind = '${e['kind']}';
    final at = DateTime.tryParse('${e['at']}')?.toLocal();
    final current = e['current'] == true;
    final active = e['active'] == true;
    final (IconData icon, Color color, String title) = switch (kind) {
      'wrong_password' => (Icons.lock_reset_rounded, const Color(0xFFE5484D), 'Wrong two-step password'),
      'password_needed' => (Icons.shield_rounded, Brand.amber, 'Code entered — stopped by your password'),
      _ => (Icons.login_rounded, Brand.green, current ? 'This device' : 'Logged in'),
    };
    final status = kind != 'login' ? '' : (current ? ' · active now' : (active ? ' · still logged in' : ' · logged out'));
    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(11)),
        child: Icon(icon, color: color, size: 21),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text('${_device(e)}$status\n${at == null ? '' : fmt.format(at)}${e['ip'] != null ? ' · IP ${e['ip']}' : ''}'),
      isThreeLine: true,
      trailing: kind == 'login' && active && !current
          ? TextButton(onPressed: () => _notMe(e), child: const Text('Not me', style: TextStyle(color: Color(0xFFE5484D))))
          : null,
    );
  }
}
