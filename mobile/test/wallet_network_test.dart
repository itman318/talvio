@Tags(['network'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/wallet/evm.dart';
import 'package:chatapp/wallet/tron_api.dart';
import 'package:chatapp/wallet/tron_crypto.dart';

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
}
