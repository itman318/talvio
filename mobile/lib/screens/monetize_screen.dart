import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'coins_screen.dart' show CoinIcon, fmtCoins;

/// Channel → Monetization: the requirements, and turning earning on.
class MonetizeScreen extends StatefulWidget {
  const MonetizeScreen({super.key, required this.chat});
  final Chat chat;

  @override
  State<MonetizeScreen> createState() => _MonetizeScreenState();
}

class _MonetizeScreenState extends State<MonetizeScreen> {
  Map<String, dynamic>? _s;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/chats/${widget.chat.id}/monetization') as Map);
      if (mounted) setState(() => _s = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _set(bool on) async {
    if (!on && !await confirm(context, 'Turn off monetization?', 'The channel stops earning, and its paid subscription becomes free.', ok: 'Turn off', danger: true)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.post('/chats/${widget.chat.id}/monetization', {'on': on}) as Map);
      widget.chat.monetized = r['monetized'] == true;
      if (!on) widget.chat.subPrice = 0;
      if (mounted) {
        setState(() => _s = r);
        showInfo(context, on ? 'Monetization is on 🎉' : 'Monetization is off');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? const Color(0xFF1A1E33) : Colors.white;
    return Scaffold(
      appBar: AppBar(title: const Text('Monetization')),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: s['monetized'] == true ? const [Color(0xFF12B89C), Color(0xFF0E8F7A)] : const [Color(0xFF2B2350), Color(0xFF4A2FD8)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(s['monetized'] == true ? Icons.verified_rounded : Icons.monetization_on_rounded, color: Colors.white, size: 32),
                    const SizedBox(height: 8),
                    Text(s['monetized'] == true ? 'This channel earns' : 'Earn from your channel',
                        style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text(
                      '• ${(s['shares'] as Map)['ads_percent']}% of the ad money for views in your channel\n'
                      '• ${(s['shares'] as Map)['tips_percent']}% of tips on your posts\n'
                      '• ${(s['shares'] as Map)['subs_percent']}% of a paid subscription you set',
                      style: const TextStyle(color: Colors.white, height: 1.5),
                    ),
                  ]),
                ),
                if (s['monetized'] == true) ...[
                  const SizedBox(height: 14),
                  Row(children: [
                    _earn(card, 'Tips', (s['earned'] as Map)['tips']),
                    const SizedBox(width: 8),
                    _earn(card, 'Subscriptions', (s['earned'] as Map)['subscriptions']),
                    const SizedBox(width: 8),
                    _earn(card, 'Ads (all channels)', (s['earned'] as Map)['ads_all_channels']),
                  ]),
                ],
                const SizedBox(height: 18),
                const Text('Requirements', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                const SizedBox(height: 8),
                Material(
                  color: card,
                  borderRadius: BorderRadius.circular(18),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    for (final raw in s['checks'] as List)
                      Builder(builder: (_) {
                        final c = raw as Map;
                        final ok = c['ok'] == true;
                        return ListTile(
                          leading: Icon(ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: ok ? Brand.green : Brand.muted),
                          title: Text('${c['label']}', style: TextStyle(fontWeight: FontWeight.w600, color: ok ? null : Theme.of(context).colorScheme.onSurface)),
                          subtitle: !ok && c['have'] != null ? Text('Now: ${fmtCoins((c['have'] as num).toInt())} of ${fmtCoins((c['need'] as num).toInt())}') : null,
                        );
                      }),
                  ]),
                ),
                const SizedBox(height: 18),
                if (s['monetized'] == true)
                  TextButton(onPressed: _busy ? null : () => _set(false), child: const Text('Turn off monetization', style: TextStyle(color: Brand.rose)))
                else
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: _busy || s['eligible'] != true ? null : () => _set(true),
                    child: Text(s['eligible'] == true ? 'Turn on monetization' : 'Complete the requirements first'),
                  ),
                const SizedBox(height: 10),
                const Text('Earnings come as coins. Channels that break the rules (fake views, scams, stolen content) lose monetization and their earnings can be removed.',
                    textAlign: TextAlign.center, style: TextStyle(color: Brand.muted, fontSize: 12.5, height: 1.35)),
              ]),
            ),
    );
  }

  Widget _earn(Color card, String label, Object? v) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const CoinIcon(size: 15),
              const SizedBox(width: 4),
              Flexible(child: Text(fmtCoins(((v as num?) ?? 0).toInt()), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
            ]),
            const SizedBox(height: 2),
            Text(label, textAlign: TextAlign.center, style: const TextStyle(color: Brand.muted, fontSize: 11.5)),
          ]),
        ),
      );
}
