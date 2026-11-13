import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'coins_screen.dart' show CoinIcon, CoinsScreen, fmtCoins;

const _topics = {
  'news': 'News', 'tech': 'Tech', 'sports': 'Sports', 'entertainment': 'Entertainment', 'education': 'Education',
  'business': 'Business', 'religion': 'Religion', 'lifestyle': 'Lifestyle', 'gaming': 'Gaming', 'other': 'Other',
};
const _countries = {'PK': '🇵🇰 Pakistan', 'AE': '🇦🇪 UAE', 'SA': '🇸🇦 Saudi Arabia', 'IN': '🇮🇳 India', 'BD': '🇧🇩 Bangladesh', 'GB': '🇬🇧 UK', 'US': '🇺🇸 USA', 'QA': '🇶🇦 Qatar', 'OM': '🇴🇲 Oman', 'KW': '🇰🇼 Kuwait'};

(String, Color) _state(Map a) {
  if (a['review'] == 'rejected') return ('Not approved', Brand.rose);
  if (a['status'] == 'ended') return ('Ended', Brand.muted);
  if (a['review'] == 'pending') return ('In review', Brand.amber);
  if (a['status'] == 'paused') return ('Paused', Brand.sky);
  return ('Running', Brand.green);
}

Widget _pill(String t, Color c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Text(t, style: TextStyle(color: c, fontSize: 11.5, fontWeight: FontWeight.w800)),
    );

/// Advertise: the member's own sponsored messages, paid with coins.
class AdsScreen extends StatefulWidget {
  const AdsScreen({super.key});

  @override
  State<AdsScreen> createState() => _AdsScreenState();
}

class _AdsScreenState extends State<AdsScreen> {
  Map<String, dynamic>? _meta;
  List<Map<String, dynamic>> _ads = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppServices>().api;
    try {
      final r = await Future.wait([api.get('/ads/meta'), api.get('/ads/mine')]);
      if (!mounted) return;
      setState(() {
        _meta = Map<String, dynamic>.from(r[0] as Map);
        _ads = [for (final a in r[1] as List) Map<String, dynamic>.from(a as Map)];
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _meta;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? const Color(0xFF1A1E33) : Colors.white;
    return Scaffold(
      appBar: AppBar(title: const Text('Advertise')),
      floatingActionButton: m == null || m['open'] != true
          ? null
          : FloatingActionButton.extended(
              onPressed: () async {
                final made = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => _NewAdScreen(meta: m)));
                if (made == true) _load();
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('New ad'),
            ),
      body: m == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFFFF7A59), Color(0xFFE5484D), Color(0xFF8F72FF)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.campaign_rounded, color: Colors.white, size: 34),
                    const SizedBox(height: 8),
                    const Text('Reach people in channels', style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text('Your short ad appears at the end of public channels with ${fmtCoins((m['min_subscribers'] as num).toInt())}+ subscribers. '
                        'You choose the topics and pay only for real views.',
                        style: const TextStyle(color: Colors.white, height: 1.35)),
                    const SizedBox(height: 12),
                    Row(children: [
                      _stat('${fmtCoins(((m['reach'] as Map)['channels'] as num).toInt())}', 'channels'),
                      const SizedBox(width: 18),
                      _stat(_compact(((m['reach'] as Map)['subscribers'] as num).toInt()), 'subscribers'),
                    ]),
                  ]),
                ),
                if (m['open'] != true) ...[
                  const SizedBox(height: 14),
                  const Text('Advertising is not open yet.', textAlign: TextAlign.center, style: TextStyle(color: Brand.muted)),
                ],
                const SizedBox(height: 18),
                Text(_ads.isEmpty ? 'Your ads' : 'Your ads (${_ads.length})', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                const SizedBox(height: 8),
                if (_ads.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('No ads yet. Tap “New ad” to make your first one.', textAlign: TextAlign.center, style: TextStyle(color: Brand.muted)),
                  ),
                for (final a in _ads)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: card,
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () async {
                          await Navigator.push(context, MaterialPageRoute(builder: (_) => _AdDetailScreen(id: (a['id'] as num).toInt())));
                          _load();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text('${a['advertiser']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                              _pill(_state(a).$1, _state(a).$2),
                            ]),
                            const SizedBox(height: 4),
                            Text('${a['text']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Brand.muted)),
                            const SizedBox(height: 10),
                            Row(children: [
                              _mini(Icons.visibility_rounded, fmtCoins((a['impressions'] as num).toInt())),
                              _mini(Icons.touch_app_rounded, fmtCoins((a['clicks'] as num).toInt())),
                              _mini(Icons.percent_rounded, '${a['ctr']}'),
                              const Spacer(),
                              const CoinIcon(size: 14),
                              const SizedBox(width: 4),
                              Text('${fmtCoins((a['spent_coins'] as num).toInt())} / ${fmtCoins((a['budget_coins'] as num).toInt())}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                            ]),
                          ]),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
    );
  }

  static String _compact(int n) => n >= 1000000 ? '${(n / 1000000).toStringAsFixed(1)}M' : n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}K' : '$n';

  Widget _stat(String v, String l) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(v, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
        Text(l, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]);

  Widget _mini(IconData i, String t) => Padding(
        padding: const EdgeInsets.only(right: 14),
        child: Row(children: [Icon(i, size: 15, color: Brand.muted), const SizedBox(width: 4), Text(t, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))]),
      );
}

class _NewAdScreen extends StatefulWidget {
  const _NewAdScreen({required this.meta});
  final Map<String, dynamic> meta;

  @override
  State<_NewAdScreen> createState() => _NewAdScreenState();
}

class _NewAdScreenState extends State<_NewAdScreen> {
  final _name = TextEditingController();
  final _text = TextEditingController();
  final _button = TextEditingController(text: 'Open');
  final _url = TextEditingController();
  late final _cpm = TextEditingController(text: '${widget.meta['min_cpm']}');
  late final _budget = TextEditingController(text: '${widget.meta['min_budget']}');
  final _cap = TextEditingController();
  final Set<String> _cats = {};
  final Set<String> _ctry = {};
  bool _busy = false;

  int get _cpmN => int.tryParse(_cpm.text) ?? 0;
  int get _budgetN => int.tryParse(_budget.text) ?? 0;

  Future<void> _create() async {
    final minCpm = (widget.meta['min_cpm'] as num).toInt();
    final minBudget = (widget.meta['min_budget'] as num).toInt();
    if (_name.text.trim().isEmpty || _text.text.trim().length < 5 || _url.text.trim().isEmpty) {
      showInfo(context, 'Fill in the name, the text (5+ letters) and the link');
      return;
    }
    if (_cpmN < minCpm || _budgetN < minBudget) {
      showInfo(context, 'At least ${fmtCoins(minCpm)} coins per 1,000 views and a ${fmtCoins(minBudget)}-coin budget');
      return;
    }
    final balance = (widget.meta['balance'] as num).toInt();
    if (_budgetN > balance) {
      final go = await confirm(context, 'Not enough coins', 'The budget is ${fmtCoins(_budgetN)} coins and you have ${fmtCoins(balance)}. Get more coins?', ok: 'Get coins');
      if (go && mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const CoinsScreen()));
      return;
    }
    if (!await confirm(context, 'Start this ad?', '${fmtCoins(_budgetN)} coins are held from your balance now. You pay ${fmtCoins(_cpmN)} coins per 1,000 views; whatever is not spent comes back when the ad ends. The ad starts after a quick review.', ok: 'Start') || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<AppServices>().api.post('/ads', {
        'advertiser': _name.text.trim(), 'text': _text.text.trim(), 'button_text': _button.text.trim(), 'url': _url.text.trim(),
        'categories': _cats.toList(), 'countries': _ctry.toList(), 'cpm_coins': _cpmN, 'budget_coins': _budgetN,
        if (_cap.text.trim().isNotEmpty) 'daily_cap_coins': int.tryParse(_cap.text.trim()),
      });
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      showInfo(context, 'Sent for review — usually within a few hours');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final views = _cpmN > 0 ? (_budgetN * 1000 ~/ _cpmN) : 0;
    return Scaffold(
      appBar: AppBar(title: const Text('New ad')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        const Text('Preview', style: TextStyle(color: Brand.muted, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: dark ? const Color(0xFF242A44) : const Color(0xFFF1F2F7), borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Sponsored · ${_name.text.isEmpty ? 'Your name' : _name.text}', style: const TextStyle(fontSize: 12, color: Brand.muted, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(_text.text.isEmpty ? 'Your ad text appears here.' : _text.text, style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: OutlinedButton(onPressed: null, child: Text(_button.text.isEmpty ? 'Open' : _button.text))),
          ]),
        ),
        const SizedBox(height: 16),
        TextField(controller: _name, maxLength: 40, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Name (brand, shop, channel)')),
        TextField(controller: _text, maxLength: 160, maxLines: 3, minLines: 2, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Ad text')),
        TextField(controller: _button, maxLength: 24, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Button text')),
        TextField(controller: _url, autocorrect: false, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Link', hintText: 'https://… or @channel')),
        const SizedBox(height: 18),
        const Text('Topics', style: TextStyle(fontWeight: FontWeight.w800)),
        const Text('Shown in channels about these. None = all topics.', style: TextStyle(color: Brand.muted, fontSize: 12.5)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final e in _topics.entries)
            FilterChip(label: Text(e.value), selected: _cats.contains(e.key), onSelected: (v) => setState(() => v ? _cats.add(e.key) : _cats.remove(e.key))),
        ]),
        const SizedBox(height: 14),
        const Text('Countries', style: TextStyle(fontWeight: FontWeight.w800)),
        const Text('From the viewer’s phone number. None = everywhere.', style: TextStyle(color: Brand.muted, fontSize: 12.5)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final e in _countries.entries)
            FilterChip(label: Text(e.value), selected: _ctry.contains(e.key), onSelected: (v) => setState(() => v ? _ctry.add(e.key) : _ctry.remove(e.key))),
        ]),
        const SizedBox(height: 18),
        const Text('Budget', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _cpm,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: 'Coins per 1,000 views', helperText: 'min ${widget.meta['min_cpm']} · higher shows first'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _budget,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: 'Total budget', helperText: 'min ${fmtCoins((widget.meta['min_budget'] as num).toInt())} coins'),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _cap,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Daily limit (optional)', hintText: 'coins per day'),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Brand.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
          child: Text('≈ ${fmtCoins(views)} views for ${fmtCoins(_budgetN)} coins (≈ \$${(_budgetN / 100).toStringAsFixed(2)}). '
              'Each person is counted once a day. You have ${fmtCoins((widget.meta['balance'] as num).toInt())} coins.',
              style: const TextStyle(height: 1.35)),
        ),
        const SizedBox(height: 10),
        const Text('Ads are reviewed before they run. No scams, gambling, adult content, fake offers or anything illegal. Unspent coins come back when an ad ends or is not approved.',
            style: TextStyle(color: Brand.muted, fontSize: 12.5, height: 1.35)),
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : _create,
          child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)) : const Text('Send for review'),
        ),
      ]),
    );
  }
}

class _AdDetailScreen extends StatefulWidget {
  const _AdDetailScreen({required this.id});
  final int id;

  @override
  State<_AdDetailScreen> createState() => _AdDetailScreenState();
}

class _AdDetailScreenState extends State<_AdDetailScreen> {
  Map<String, dynamic>? _a;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/ads/${widget.id}/stats') as Map);
      if (mounted) setState(() => _a = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _act(String action, [Map<String, dynamic>? body]) async {
    setState(() => _busy = true);
    try {
      await context.read<AppServices>().api.post('/ads/${widget.id}/$action', body ?? {});
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _topUp() async {
    final ctl = TextEditingController(text: '1000');
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add to the budget'),
        content: TextField(controller: ctl, autofocus: true, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Coins', prefixIcon: Padding(padding: EdgeInsets.all(12), child: CoinIcon(size: 20)))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(ctl.text)), child: const Text('Add')),
        ],
      ),
    );
    if (n != null && n > 0) await _act('topup', {'coins': n});
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? const Color(0xFF1A1E33) : Colors.white;
    return Scaffold(
      appBar: AppBar(title: Text(a == null ? 'Ad' : '${a['advertiser']}')),
      body: a == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
                Row(children: [_pill(_state(a).$1, _state(a).$2), const Spacer(), Text('${fmtCoins((a['cpm_coins'] as num).toInt())} coins / 1,000 views', style: const TextStyle(color: Brand.muted, fontSize: 13))]),
                if (a['reject_reason'] != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Brand.rose.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
                    child: Text('Not approved: ${a['reject_reason']}\nThe unspent coins are back in your balance.'),
                  ),
                ],
                const SizedBox(height: 12),
                Row(children: [
                  _box(card, 'Views', fmtCoins((a['impressions'] as num).toInt())),
                  const SizedBox(width: 8),
                  _box(card, 'Clicks', fmtCoins((a['clicks'] as num).toInt())),
                  const SizedBox(width: 8),
                  _box(card, 'CTR', '${a['ctr']}%'),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  _box(card, 'Spent', fmtCoins((a['spent_coins'] as num).toInt())),
                  const SizedBox(width: 8),
                  _box(card, 'Left', fmtCoins(((a['left_coins'] as num?) ?? 0).toInt())),
                  const SizedBox(width: 8),
                  _box(card, 'Budget', fmtCoins((a['budget_coins'] as num).toInt())),
                ]),
                const SizedBox(height: 18),
                const Text('Last 14 days', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 8),
                Container(
                  height: 150,
                  padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
                  decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(18)),
                  child: _Bars(days: [for (final d in a['days'] as List) Map<String, dynamic>.from(d as Map)]),
                ),
                if ((a['top_channels'] as List).isNotEmpty) ...[
                  const SizedBox(height: 18),
                  const Text('Top channels', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(18)),
                    child: Column(children: [
                      for (final c in a['top_channels'] as List)
                        ListTile(dense: true, leading: const Icon(Icons.campaign_rounded), title: Text('${(c as Map)['title']}'), trailing: Text('${fmtCoins((c['views'] as num).toInt())} views')),
                    ]),
                  ),
                ],
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(14)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${a['text']}', style: const TextStyle(fontSize: 15)),
                    const SizedBox(height: 6),
                    Text('${a['url']}', style: const TextStyle(color: Brand.muted, fontSize: 12.5)),
                  ]),
                ),
                if (a['status'] != 'ended' && a['review'] != 'rejected') ...[
                  const SizedBox(height: 18),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _act(a['status'] == 'paused' ? 'resume' : 'pause'),
                        icon: Icon(a['status'] == 'paused' ? Icons.play_arrow_rounded : Icons.pause_rounded),
                        label: Text(a['status'] == 'paused' ? 'Resume' : 'Pause'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: FilledButton.icon(onPressed: _busy ? null : _topUp, icon: const Icon(Icons.add_rounded), label: const Text('Add budget'))),
                  ]),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            if (await confirm(context, 'Stop this ad?', 'It ends now and the unspent coins come back to your balance.', ok: 'Stop', danger: true)) _act('stop');
                          },
                    child: const Text('Stop and get unspent coins back', style: TextStyle(color: Brand.rose)),
                  ),
                ],
              ]),
            ),
    );
  }

  Widget _box(Color card, String label, String value) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Brand.muted, fontSize: 12)),
          ]),
        ),
      );
}

/// Daily views as bars.
class _Bars extends StatelessWidget {
  const _Bars({required this.days});
  final List<Map<String, dynamic>> days;

  @override
  Widget build(BuildContext context) {
    final max = days.fold<int>(1, (m, d) => ((d['views'] as num).toInt() > m) ? (d['views'] as num).toInt() : m);
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (final d in days)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              Flexible(
                child: FractionallySizedBox(
                  heightFactor: ((d['views'] as num).toInt() / max).clamp(0.02, 1.0),
                  child: Container(decoration: BoxDecoration(color: Brand.primary, borderRadius: BorderRadius.circular(4))),
                ),
              ),
              const SizedBox(height: 4),
              Text('${d['day']}'.substring(8), style: const TextStyle(fontSize: 9.5, color: Brand.muted)),
            ]),
          ),
        ),
    ]);
  }
}
