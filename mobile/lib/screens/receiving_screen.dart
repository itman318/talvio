import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../wallet/evm.dart';
import '../wallet/tron_api.dart' show WalletException;
import '../wallet/tron_crypto.dart';
import '../wallet/wallet_store.dart';

const _h = 0x80000000;
const _path = [44 + _h, 60 + _h, 0 + _h, 0]; // m/44'/60'/0'/0 — address i is …/i

String _xpubOf(String phrase) => TronCrypto.xpubOf(TronCrypto.seedOf(phrase), _path);

/// For the person who RECEIVES Hushavia coin payments: the receiving key (xpub) for the admin
/// panel, and collecting the USDT that members deposited into one address (e.g. SafePal).
class ReceivingScreen extends StatefulWidget {
  const ReceivingScreen({super.key});

  @override
  State<ReceivingScreen> createState() => _ReceivingScreenState();
}

class _ReceivingScreenState extends State<ReceivingScreen> {
  String? _xpub;
  final _dest = TextEditingController();
  bool _busy = false;
  final List<String> _log = [];

  WalletStore get _w => context.read<WalletStore>();
  String get _destKey => 'wallet_collect_to_${_w.userId}';
  EvmToken get _usdt => EvmToken.builtIn.firstWhere((t) => t.chain == 'bsc' && t.symbol == 'USDT');

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) _dest.text = p.getString(_destKey) ?? '';
    });
  }

  Future<void> _showKey() async {
    final phrase = await _w.readPhrase(context, 'Show the receiving key');
    if (phrase == null || !mounted) return;
    setState(() => _busy = true);
    final x = await compute(_xpubOf, phrase);
    if (mounted) setState(() {
      _xpub = x;
      _busy = false;
    });
  }

  void _say(String s) {
    if (mounted) setState(() => _log.add(s));
  }

  Future<void> _wait(EvmApi api, String hash) async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      final r = await api.call('eth_getTransactionReceipt', [hash]);
      if (r is Map && r['blockNumber'] != null) {
        if (r['status'] != '0x1') throw WalletException('A transaction failed on the network');
        return;
      }
    }
    throw WalletException('The network is slow. Try again in a few minutes.');
  }

  Future<void> _collect() async {
    final dest = _dest.text.trim();
    if (!EvmCrypto.isValidAddress(dest)) {
      showInfo(context, 'Enter your BNB Smart Chain address (0x…) to collect into');
      return;
    }
    (await SharedPreferences.getInstance()).setString(_destKey, dest);
    if (!mounted) return;
    final phrase = await _w.readPhrase(context, 'Collect coin deposits');
    if (phrase == null || !mounted) return;
    setState(() {
      _busy = true;
      _log.clear();
    });
    final api = EvmApi(EvmChain.bsc);
    try {
      final xpub = await compute(_xpubOf, phrase);
      final list = Map<String, dynamic>.from(await context.read<AppServices>().api.post('/coins/sweep-list', {'xpub': xpub}) as Map);
      final addrs = [for (final a in list['addresses'] as List) Map<String, dynamic>.from(a as Map)];
      _say('${addrs.length} member address${addrs.length == 1 ? '' : 'es'} have received deposits');
      final seed = await compute(TronCrypto.seedOf, phrase);
      Uint8List keyAt(int i) => TronCrypto.derive(seed, [..._path, i]);
      final mainKey = keyAt(0);
      final main = EvmCrypto.addressOf(mainKey);
      var total = BigInt.zero;
      for (final a in addrs) {
        final i = (a['index'] as num).toInt();
        final key = keyAt(i);
        final from = EvmCrypto.addressOf(key);
        if (from.toLowerCase() != '${a['address']}'.toLowerCase()) throw WalletException('This wallet is not the one whose key is set in Hushavia');
        final bal = await api.tokenBalance(_usdt.address, from);
        if (bal == BigInt.zero) continue;
        final p = await api.prepare(from: from, to: dest, amount: bal, token: _usdt);
        final gas = await api.balance(from);
        if (gas < p.fee) {
          // the member's address has no BNB: send it just enough for the fee from address 0
          final need = (p.fee - gas) * BigInt.from(12) ~/ BigInt.from(10);
          final mainBal = await api.balance(main);
          final top = await api.prepare(from: main, to: from, amount: need, have: mainBal);
          if (mainBal < need + top.fee) throw WalletException('Not enough BNB for fees in $main — send a little BNB (about \$1) there and try again.');
          _say('#$i: sending fee money…');
          final h = await api.send(top, mainKey);
          await _wait(api, h);
        }
        final again = await api.prepare(from: from, to: dest, amount: bal, token: _usdt);
        final h = await api.send(again, key);
        key.fillRange(0, key.length, 0);
        total += bal;
        _say('#$i: ${Units.format(bal, decimals: 18, maxFraction: 2)} USDT sent');
      }
      mainKey.fillRange(0, mainKey.length, 0);
      _say(total == BigInt.zero ? 'Nothing to collect right now.' : 'Done — ${Units.format(total, decimals: 18, maxFraction: 2)} USDT on its way to your address.');
      if (total > BigInt.zero) HapticFeedback.heavyImpact();
    } catch (e) {
      _say('Stopped: ${e is WalletException ? e.message : e}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = context.watch<WalletStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Receive coin payments')),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 6, 18, 28), children: [
        const Text('For the Hushavia team only. Use a wallet made just for receiving — not your personal one.', style: TextStyle(color: Brand.muted, height: 1.35)),
        const SizedBox(height: 18),
        const Text('1. Receiving key', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 4),
        const Text('Paste it in the admin panel → Settings → “Receiving key for coin deposits”. It makes every member’s deposit address but can’t move any money. Still, keep it private.',
            style: TextStyle(color: Brand.muted, fontSize: 13, height: 1.35)),
        const SizedBox(height: 10),
        if (_xpub == null)
          OutlinedButton.icon(onPressed: _busy ? null : _showKey, icon: const Icon(Icons.vpn_key_rounded), label: const Text('Show receiving key'))
        else
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Brand.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SelectableText(_xpub!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _xpub!));
                  showInfo(context, 'Receiving key copied');
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy'),
              ),
            ]),
          ),
        const SizedBox(height: 24),
        const Text('2. Collect deposits', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 4),
        Text('Moves the USDT from members’ deposit addresses to your address. Fees are paid in BNB from this wallet’s BNB Smart Chain address: ${w.evmAddress ?? ''} — keep about \$1 of BNB there.',
            style: const TextStyle(color: Brand.muted, fontSize: 13, height: 1.35)),
        const SizedBox(height: 10),
        TextField(
          controller: _dest,
          autocorrect: false,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13.5),
          decoration: const InputDecoration(labelText: 'Collect into (your BNB Smart Chain address, e.g. SafePal)', hintText: '0x…'),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          onPressed: _busy ? null : _collect,
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.move_down_rounded),
          label: const Text('Collect now'),
        ),
        const SizedBox(height: 14),
        for (final l in _log) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('• $l', style: const TextStyle(fontSize: 13.5))),
      ]),
    );
  }
}
