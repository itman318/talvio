@Tags(['network'])
library;

import 'package:flutter_test/flutter_test.dart';
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
      expect(b.trx >= BigInt.zero, true);
      await api.history(me);
      try {
        final p = await api.prepareUsdt(me, to, BigInt.from(1000000));
        expect(p.id.length, 32);
        expect(p.feeSun > BigInt.zero, true);
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
}
