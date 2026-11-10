@Tags(['network'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/wallet/evm.dart';
import 'package:chatapp/wallet/tron_api.dart';
import 'package:chatapp/wallet/tron_crypto.dart';
import 'package:chatapp/wallet/verify.dart';
import 'package:chatapp/wallet/utxo.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

// Talks to the real TRON networks — READ ONLY: transactions are prepared and checked, never signed or sent.
void main() {
  const me = 'TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH';
  const to = 'TSeJkUh4Qv67VNFwY8LaAxERygNdy6NQZK';

  for (final net in [TronNet.main, TronNet.nile]) {
    test('${net.name}: balance, history, prepared USDT + TRX transfers pass the checks', () async {
      final api = TronApi(net);
      final b = await api.balance(me);
      expect(b.trx >= BigInt.zero, true, reason: 'balance');
      // ignore: avoid_print
      print('${net.name} balance: ${b.trx} sun, ${b.usdt} usdt, active ${b.activated}');
      await api.history(me);
      try {
        final p = await api.prepareUsdt(me, to, BigInt.from(1000000));
        expect(p.id.length, 32);
        // ignore: avoid_print
        print('${net.name} fee raw: ${p.feeSun}');
        expect(p.feeSun >= BigInt.zero, true, reason: 'fee'); // 0 is real for accounts with staked energy
        // ignore: avoid_print
        print('${net.name} USDT fee estimate: ${Units.format(p.feeSun)} TRX');
      } on WalletException catch (e) {
        // an empty test account may be refused by the node; the check itself must not be what failed
        expect(e.message.contains('didn’t match') || e.message.contains('Bad'), false, reason: e.message);
        // ignore: avoid_print
        print('${net.name} USDT: node said "${e.message}"');
      }
      try {
        final p = await api.prepareTrx(me, to, BigInt.from(1000000));
        expect(TronCrypto.hex(p.id).length, 64);
      } on WalletException catch (e) {
        expect(e.message.contains('didn’t match') || e.message.contains('Bad'), false, reason: e.message);
        // ignore: avoid_print
        print('${net.name} TRX: node said "${e.message}"');
      }
      final px = await Prices.current();
      // ignore: avoid_print
      print('prices: $px');
    }, timeout: const Timeout(Duration(seconds: 90)));
  }

  for (final c in EvmChain.all) {
    test('${c.name}: right network, and every built-in token is what we say (symbol + decimals)', () async {
      final api = EvmApi(c);
      final b = await api.balance('0x9858EfFD232B4033E47d90003D41EC34EcaEda94');
      expect(b >= BigInt.zero, true);
      for (final t in EvmToken.builtIn.where((t) => t.chain == c.id)) {
        final info = await api.tokenInfo(t.address);
        // ignore: avoid_print
        print('${c.name} ${t.symbol}: on chain ${info.symbol} / ${info.decimals} decimals');
        expect(info.decimals, t.decimals, reason: '${c.name} ${t.symbol} decimals');
        expect(info.symbol.toUpperCase().replaceAll('₮', 'T').contains(t.symbol), true, reason: '${c.name} ${t.symbol} symbol is ${info.symbol}');
      }
      // a real transfer can be prepared (read only: not signed, not sent)
      try {
        final p = await api.prepare(from: '0x9858EfFD232B4033E47d90003D41EC34EcaEda94', to: '0x6Fac4D18c912343BF86fa7049364Dd4E424Ab9C0', amount: BigInt.one);
        // ignore: avoid_print
        print('${c.name} fee for a plain transfer: ${Units.format(p.fee, decimals: 18, maxFraction: 8)} ${c.symbol}');
      } on WalletException catch (e) {
        // ignore: avoid_print
        print('${c.name} prepare: ${e.message}');
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  }

  test('chat cards: a real TRON USDT transfer is confirmed, a faked amount is not', () async {
    final r = await http.get(Uri.parse('https://api.trongrid.io/v1/accounts/$me/transactions/trc20?limit=5&contract_address=${TronNet.main.usdt}'));
    final list = (jsonDecode(r.body)['data'] as List?) ?? const [];
    if (list.isEmpty) return; // network busy: nothing to check against
    final t = list.first as Map;
    final card = {'kind': 'sent', 'network': 'tron', 'symbol': 'USDT', 'amount': '${t['value']}', 'decimals': 6, 'to': '${t['to']}', 'contract': TronNet.main.usdt, 'tx': '${t['transaction_id']}'};
    final ok = await CryptoVerify.check(card);
    // ignore: avoid_print
    print('TRON real transfer → $ok');
    expect(ok == CardCheck.confirmed || ok == CardCheck.pending, true, reason: '$ok');
    final bad = await CryptoVerify.check({...card, 'amount': '${BigInt.parse('${t['value']}') + BigInt.one}'});
    // ignore: avoid_print
    print('TRON faked amount → $bad');
    // the free TRON server may say "busy" right after the first lookup → pending; what matters: NEVER confirmed
    expect(bad == CardCheck.mismatch || bad == CardCheck.pending, true, reason: '$bad');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('chat cards: a real BNB Chain USDT transfer is confirmed, a faked receiver is not', () async {
    final api = EvmApi(EvmChain.bsc);
    final head = EvmApi.q(await api.call('eth_blockNumber', const []));
    final logs = (await api.call('eth_getLogs', [
      {
        'fromBlock': '0x${(head - BigInt.from(3)).toRadixString(16)}',
        'toBlock': '0x${head.toRadixString(16)}',
        'address': '0x55d398326f99059fF775485246999027B3197955',
        'topics': ['0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'],
      }
    ]) as List?) ?? const [];
    if (logs.isEmpty) return;
    final l = logs.first as Map;
    final to = '0x${'${(l['topics'] as List)[2]}'.substring(26)}';
    final card = {'kind': 'sent', 'network': 'bsc', 'symbol': 'USDT', 'amount': '${EvmApi.q(l['data'])}', 'decimals': 18, 'to': to,
      'contract': '0x55d398326f99059fF775485246999027B3197955', 'tx': '${l['transactionHash']}'};
    final ok = await CryptoVerify.check(card);
    // ignore: avoid_print
    print('BSC real transfer → $ok');
    expect(ok == CardCheck.confirmed || ok == CardCheck.pending, true, reason: '$ok');
    final bad = await CryptoVerify.check({...card, 'to': '0x9858EfFD232B4033E47d90003D41EC34EcaEda94'});
    // ignore: avoid_print
    print('BSC faked receiver → $bad');
    expect(bad, CardCheck.mismatch);
  }, timeout: const Timeout(Duration(seconds: 90)));

  for (final c in UtxoChain.all) {
    test('${c.name}: balance, history, fee rate; our transaction id matches the network\'s', () async {
      final api = UtxoApi(c);
      final addr = {'btc': 'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu', 'ltc': 'ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh', 'doge': 'DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC'}[c.id]!;
      final b = await api.balance(addr);
      final h = await api.history(addr);
      final rate = await api.feeRate();
      // ignore: avoid_print
      print('${c.name}: balance ${Units.format(b, decimals: 8)} ${c.symbol}, ${h.length} transfers, fee ${rate.toStringAsFixed(2)}/vB');
      if (!c.blockcypher && h.isNotEmpty) {
        // a real transaction from the network: our id function must give the same id
        final r = await http.get(Uri.parse('${c.apis.first}/tx/${h.first.id}/hex'));
        if (r.statusCode == 200) {
          expect(UtxoTx.txid(TronCrypto.fromHex(r.body.trim()), c), h.first.id);
          // a card for a real incoming transfer must check out; the same card with 1 unit more must not
          final incoming = h.where((t) => t.to == addr).toList();
          if (incoming.isNotEmpty) {
            final t = incoming.first;
            final ok = await api.checkPayment(t.id, addr, t.amount);
            final fake = await api.checkPayment(t.id, addr, t.amount + BigInt.one);
            // ignore: avoid_print
            print('${c.name}: card check real → $ok, faked → $fake');
            if (ok != null) expect(ok.$1, true, reason: 'real payment');
            if (fake != null) expect(fake.$1, false, reason: 'faked amount');
          }
        }
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  }
}
