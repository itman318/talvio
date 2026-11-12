import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/services.dart';
import '../core/socket_service.dart';
import '../state/auth_state.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'coins_screen.dart' show CoinIcon, fmtCoins;
import 'wallet_screen.dart' show walletSendForChat;

/// "Add coins": the member's own USDT address. Whatever arrives there becomes coins.
class DepositScreen extends StatefulWidget {
  const DepositScreen({super.key});

  @override
  State<DepositScreen> createState() => _DepositScreenState();
}

class _DepositScreenState extends State<DepositScreen> {
  Map<String, dynamic>? _d;
  bool _checking = false;
  StreamSubscription<SocketEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = context.read<AppServices>().socket.events.where((e) => e.name == 'coins:updated').listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/coins/deposit') as Map);
      if (mounted) setState(() => _d = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.post('/coins/deposit/check', {}) as Map);
      if (!mounted) return;
      final added = (r['added'] as num?)?.toInt() ?? 0;
      final confirming = (r['confirming'] as num?)?.toInt() ?? 0;
      showInfo(context, added > 0
          ? '${fmtCoins(added)} coins added 🪙'
          : confirming > 0
              ? 'Your payment is on the network — coins come in about a minute'
              : 'Nothing has arrived yet. Payments usually show within a minute or two.');
      setState(() => _d = {...?_d, 'deposits': r['deposits']});
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _payFromWallet() async {
    final d = _d!;
    final card = await walletSendForChat(context, peerName: 'Hushavia Coins', locked: true, request: {
      'network': d['network'], 'symbol': d['symbol'], 'to': d['address'], 'contract': d['contract'], 'decimals': d['decimals'],
    });
    if (card != null && mounted) showInfo(context, 'Sent! Your coins come as soon as the network confirms it — about a minute.');
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? const Color(0xFF1A1E33) : Colors.white;
    return Scaffold(
      appBar: AppBar(title: const Text('Add coins')),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(22)),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Text('1 USDT = ', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      const CoinIcon(size: 20),
                      Text(' ${d['coins_per_usdt']} coins', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    ]),
                    const SizedBox(height: 4),
                    Text('Send USDT on ${d['network_name']} only', style: const TextStyle(color: Brand.muted, fontSize: 13)),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                      child: QrImageView(data: '${d['address']}', size: 190, padding: EdgeInsets.zero),
                    ),
                    const SizedBox(height: 12),
                    SelectableText('${d['address']}', textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'monospace', fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: '${d['address']}'));
                            HapticFeedback.selectionClick();
                            showInfo(context, 'Address copied');
                          },
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          label: const Text('Copy'),
                        ),
                      ),
                      if (context.read<AuthState>().feature('wallet')) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _payFromWallet,
                            icon: const Icon(Icons.account_balance_wallet_rounded, size: 18),
                            label: const Text('From my wallet'),
                          ),
                        ),
                      ],
                    ]),
                  ]),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Brand.amber.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Row(children: [
                      Icon(Icons.info_rounded, color: Brand.amber, size: 20),
                      SizedBox(width: 8),
                      Text('Before you send', style: TextStyle(fontWeight: FontWeight.w800)),
                    ]),
                    const SizedBox(height: 6),
                    Text('• This is your own address — any amount sent here becomes coins.\n'
                        '• Only USDT on ${d['network_name']}. Other coins or networks are lost.\n'
                        '• Smallest deposit: ${d['min_usd']} USDT. Less gives no coins.\n'
                        '• From an exchange (Binance, etc.) choose the network “BSC / BEP-20”.',
                        style: const TextStyle(fontSize: 13.5, height: 1.45)),
                  ]),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: _checking ? null : _check,
                  icon: _checking ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh_rounded),
                  label: const Text('I’ve sent it — check now'),
                ),
                if ((d['deposits'] as List? ?? const []).isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Text('Deposits', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  const SizedBox(height: 8),
                  Material(
                    color: card,
                    borderRadius: BorderRadius.circular(18),
                    clipBehavior: Clip.antiAlias,
                    child: Column(children: [
                      for (final raw in d['deposits'] as List)
                        Builder(builder: (_) {
                          final x = raw as Map;
                          final ok = x['status'] == 'credited';
                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 18,
                              backgroundColor: (ok ? Brand.green : Brand.amber).withValues(alpha: 0.14),
                              child: Icon(ok ? Icons.check_rounded : Icons.error_outline_rounded, color: ok ? Brand.green : Brand.amber, size: 19),
                            ),
                            title: Text('${x['usdt']} USDT', style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text(ok ? '+${fmtCoins((x['coins'] as num).toInt())} coins' : 'Below the minimum — no coins'),
                            trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                            onTap: () => launchUrl(Uri.parse('${x['tx_url']}'), mode: LaunchMode.externalApplication),
                          );
                        }),
                    ]),
                  ),
                ],
              ]),
            ),
    );
  }
}
