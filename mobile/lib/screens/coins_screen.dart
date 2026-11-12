import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../core/socket_service.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'crypto_checkout.dart';
import 'new_chat_screen.dart' show PickUsersScreen;

/// 12345 → "12,345"
String fmtCoins(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// The Hushavia coin: a gold disc with an "H".
class CoinIcon extends StatelessWidget {
  const CoinIcon({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(colors: [Color(0xFFFFE08A), Color(0xFFF5B544), Color(0xFFD98E12)], begin: Alignment.topLeft, end: Alignment.bottomRight),
          border: Border.all(color: const Color(0xFFB87708), width: size * 0.06),
          boxShadow: [BoxShadow(color: const Color(0xFFF5B544).withValues(alpha: 0.35), blurRadius: size * 0.25, offset: Offset(0, size * 0.08))],
        ),
        alignment: Alignment.center,
        child: Text('H', style: TextStyle(color: const Color(0xFF7A4B00), fontWeight: FontWeight.w900, fontSize: size * 0.56, height: 1)),
      );
}

/// Hushavia Coins: the balance, buying packs with USDT, sending to a friend, history.
class CoinsScreen extends StatefulWidget {
  const CoinsScreen({super.key, this.sendTo});

  /// Opened from a profile: go straight to "send coins to this person".
  final AppUser? sendTo;

  @override
  State<CoinsScreen> createState() => _CoinsScreenState();
}

class _CoinsScreenState extends State<CoinsScreen> {
  Map<String, dynamic>? _info;
  bool _busy = false;
  StreamSubscription<SocketEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = context.read<AppServices>().socket.events.where((e) => e.name == 'coins:updated').listen((_) => _load(resume: false));
    _load().then((_) {
      if (widget.sendTo != null && mounted && _info != null) _send(widget.sendTo);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load({bool resume = true}) async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/coins') as Map);
      if (mounted) setState(() => _info = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (resume && mounted && await resumeWalletPayment(context) && mounted) _load(resume: false);
  }

  int get _balance => ((_info?['balance'] as num?) ?? 0).toInt();

  Future<void> _buy(Map<String, dynamic> pack) async {
    setState(() => _busy = true);
    try {
      final ok = await payWithWallet(context, body: {'coin_pack_id': pack['id']}, networks: _info?['crypto_networks'] as List? ?? const [], what: 'Coins');
      if (ok && mounted) {
        HapticFeedback.heavyImpact();
        showInfo(context, '${fmtCoins((pack['total'] as num).toInt())} coins added 🪙');
      }
      if (mounted) _load(resume: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send(AppUser? to) async {
    if (_balance < 1) {
      showInfo(context, 'You have no coins yet. Get a pack first.');
      return;
    }
    var user = to;
    if (user == null) {
      final picked = await Navigator.push<List<AppUser>>(context, MaterialPageRoute(builder: (_) => const PickUsersScreen(title: 'Send coins to')));
      if (picked == null || picked.isEmpty || !mounted) return;
      if (picked.length > 1) showInfo(context, 'Coins go to one person at a time — sending to ${picked.first.name}.');
      user = picked.first;
    }
    final amount = TextEditingController();
    final note = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          final n = int.tryParse(amount.text) ?? 0;
          final tooMuch = n > _balance;
          return AlertDialog(
            title: Text('Send coins to ${user!.name}'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: amount,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                onChanged: (_) => set(() {}),
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                decoration: InputDecoration(
                  prefixIcon: const Padding(padding: EdgeInsets.all(12), child: CoinIcon(size: 22)),
                  hintText: '0',
                  errorText: tooMuch ? 'You have ${fmtCoins(_balance)}' : null,
                  helperText: 'Balance: ${fmtCoins(_balance)}',
                ),
              ),
              const SizedBox(height: 10),
              TextField(controller: note, maxLength: 120, decoration: const InputDecoration(labelText: 'Message (optional)', counterText: '')),
              const SizedBox(height: 4),
              const Text('A gift can’t be taken back.', style: TextStyle(color: Brand.muted, fontSize: 12.5)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: n >= 1 && !tooMuch ? () => Navigator.pop(ctx, true) : null, child: const Text('Send')),
            ],
          );
        },
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<AppServices>().api.post('/coins/send', {'user_id': user.id, 'amount': int.parse(amount.text), if (note.text.trim().isNotEmpty) 'note': note.text.trim()});
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      showInfo(context, '${fmtCoins(int.parse(amount.text))} coins sent to ${user.name} 🎁');
      _load(resume: false);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _plus(Map<String, dynamic> p) async {
    final price = (p['coins'] as num).toInt();
    if (_balance < price) {
      showInfo(context, 'You need ${fmtCoins(price - _balance)} more coins for this plan.');
      return;
    }
    if (!await confirm(context, 'Hushavia Plus · ${p['name']}', '${fmtCoins(price)} coins will be taken from your balance.', ok: 'Pay') || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<AppServices>().api.post('/coins/plus', {'plan_id': p['plan_id']});
      if (!mounted) return;
      await context.read<AuthState>().refreshMe();
      if (mounted) showInfo(context, 'Hushavia Plus is active ⭐');
      _load(resume: false);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static const _kinds = {
    'purchase': ('Bought', Icons.add_circle_rounded, Brand.green),
    'gift_sent': ('Sent to', Icons.north_east_rounded, Brand.rose),
    'gift_received': ('From', Icons.card_giftcard_rounded, Brand.green),
    'plus': ('Hushavia Plus', Icons.star_rounded, Brand.premium),
    'admin': ('Hushavia', Icons.verified_rounded, Brand.sky),
    'tip_sent': ('Tip to', Icons.volunteer_activism_rounded, Brand.rose),
    'tip_received': ('Tip from', Icons.volunteer_activism_rounded, Brand.green),
    'sub_paid': ('Subscription', Icons.campaign_rounded, Brand.violet),
    'sub_income': ('Subscriber', Icons.campaign_rounded, Brand.green),
    'giveaway': ('Giveaway started', Icons.celebration_rounded, Brand.violet),
    'giveaway_win': ('Giveaway prize', Icons.emoji_events_rounded, Brand.amber),
    'giveaway_refund': ('Giveaway refund', Icons.undo_rounded, Brand.sky),
  };

  /// "Sent to Hina", "Tip to Bilal", "Subscription · Hina Daily"
  String _title(Map h, String label) {
    final peer = h['peer'] as Map?;
    final kind = '${h['kind']}';
    if (kind.startsWith('sub_') || kind.startsWith('giveaway')) return label;
    return peer != null ? '$label ${peer['name']}' : label;
  }

  String _when(String? iso) {
    if (iso == null) return '';
    final d = DateTime.parse(iso).toLocal();
    return '${d.day}/${d.month}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? const Color(0xFF1A1E33) : Colors.white;
    return Scaffold(
      appBar: AppBar(title: const Text('Hushavia Coins')),
      body: info == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _load(resume: false),
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFF2B2350), Color(0xFF4A2FD8), Color(0xFF7C5CFF)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                    borderRadius: BorderRadius.circular(26),
                    boxShadow: [BoxShadow(color: Brand.primary.withValues(alpha: 0.3), blurRadius: 24, offset: const Offset(0, 10))],
                  ),
                  child: Column(children: [
                    const Text('Your balance', style: TextStyle(color: Colors.white70, fontSize: 13.5)),
                    const SizedBox(height: 8),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const CoinIcon(size: 38),
                      const SizedBox(width: 10),
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: _balance.toDouble()),
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeOutCubic,
                        builder: (_, v, __) => Text(fmtCoins(v.round()), style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w900, letterSpacing: -1)),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Brand.primaryDeep, minimumSize: const Size.fromHeight(48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                      onPressed: _busy ? null : () => _send(null),
                      icon: const Icon(Icons.card_giftcard_rounded, size: 20),
                      label: const Text('Send to a friend', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ]),
                ),
                const SizedBox(height: 20),
                const Text('Get coins', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                const SizedBox(height: 2),
                const Text('Paid with USDT from your wallet', style: TextStyle(color: Brand.muted, fontSize: 13)),
                const SizedBox(height: 10),
                if ((info['packs'] as List).isEmpty)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: Brand.amber.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                    child: Row(children: [
                      const Icon(Icons.info_outline_rounded, color: Brand.amber),
                      const SizedBox(width: 10),
                      Expanded(child: Text('${info['buy_note'] ?? 'Buying coins is not open yet.'}')),
                    ]),
                  ),
                for (final raw in info['packs'] as List)
                  Builder(builder: (_) {
                    final p = Map<String, dynamic>.from(raw as Map);
                    final bonus = (p['bonus'] as num).toInt();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Material(
                        color: card,
                        borderRadius: BorderRadius.circular(18),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: _busy ? null : () => _buy(p),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
                            child: Row(children: [
                              const CoinIcon(size: 34),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Text(fmtCoins((p['total'] as num).toInt()), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 19)),
                                    if (p['badge'] != null) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                        decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFFFFB347), Color(0xFF8F72FF)]), borderRadius: BorderRadius.circular(8)),
                                        child: Text('${p['badge']}'.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                                      ),
                                    ],
                                  ]),
                                  Text(bonus > 0 ? '${fmtCoins((p['coins'] as num).toInt())} + ${fmtCoins(bonus)} bonus' : 'coins', style: TextStyle(color: bonus > 0 ? Brand.green : Brand.muted, fontSize: 13, fontWeight: bonus > 0 ? FontWeight.w700 : FontWeight.w400)),
                                ]),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                decoration: BoxDecoration(color: Brand.primary, borderRadius: BorderRadius.circular(12)),
                                child: Text('${p['price_text']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    );
                  }),
                if ((info['plus'] as List).isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Use your coins', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  const SizedBox(height: 8),
                  Material(
                    color: card,
                    borderRadius: BorderRadius.circular(18),
                    clipBehavior: Clip.antiAlias,
                    child: Column(children: [
                      for (final raw in info['plus'] as List)
                        ListTile(
                          leading: const Icon(Icons.star_rounded, color: Brand.premium),
                          title: Text('Hushavia Plus · ${(raw as Map)['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            const CoinIcon(size: 16),
                            const SizedBox(width: 5),
                            Text(fmtCoins((raw['coins'] as num).toInt()), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: _balance >= (raw['coins'] as num) ? Theme.of(context).colorScheme.onSurface : Brand.muted)),
                          ]),
                          onTap: _busy ? null : () => _plus(Map<String, dynamic>.from(raw)),
                        ),
                    ]),
                  ),
                ],
                const SizedBox(height: 20),
                const Text('History', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                const SizedBox(height: 8),
                if ((info['history'] as List).isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 18), child: Center(child: Text('Nothing yet', style: TextStyle(color: Brand.muted))))
                else
                  Material(
                    color: card,
                    borderRadius: BorderRadius.circular(18),
                    clipBehavior: Clip.antiAlias,
                    child: Column(children: [
                      for (final raw in info['history'] as List)
                        Builder(builder: (_) {
                          final h = raw as Map;
                          final k = _kinds['${h['kind']}'] ?? ('Coins', Icons.circle, Brand.muted);
                          final delta = (h['delta'] as num).toInt();
                          final title = _title(h, k.$1);
                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(radius: 18, backgroundColor: k.$3.withValues(alpha: 0.14), child: Icon(k.$2, color: k.$3, size: 19)),
                            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                            subtitle: Text([_when(h['created_at'] as String?), if (h['note'] != null && '${h['note']}'.isNotEmpty) '${h['note']}'].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: Text('${delta > 0 ? '+' : ''}${fmtCoins(delta)}', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: delta > 0 ? Brand.green : null)),
                          );
                        }),
                    ]),
                  ),
                const SizedBox(height: 16),
                Text('${info['rules'] ?? ''}', textAlign: TextAlign.center, style: const TextStyle(color: Brand.muted, fontSize: 12.5, height: 1.35)),
              ]),
            ),
    );
  }
}
