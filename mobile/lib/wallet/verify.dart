import 'evm.dart';
import 'tron_api.dart';
import 'tron_crypto.dart';
import 'utxo.dart';

enum CardCheck { checking, confirmed, pending, failed, mismatch }

/// A "Sent 5 USDT" card in a chat is only what the sender's phone CLAIMS. This looks the transaction
/// up on the network and says whether it really moved that amount of that coin to that address.
class CryptoVerify {
  CryptoVerify._();
  static final Map<String, (CardCheck, DateTime)> _cache = {};

  static Future<CardCheck> check(Map<String, dynamic> c) async {
    final tx = '${c['tx'] ?? ''}';
    if (tx.isEmpty) return CardCheck.mismatch;
    // the answer belongs to the WHOLE card: the same real transaction id with another amount or
    // receiver is a different (fake) card and is checked on its own
    final key = '${c['network']}|$tx|${c['to']}|${c['amount']}|${c['contract'] ?? ''}'.toLowerCase();
    final hit = _cache[key];
    // final answers are kept; "pending" is asked again after 20 seconds
    if (hit != null && (hit.$1 != CardCheck.pending || DateTime.now().difference(hit.$2) < const Duration(seconds: 20))) return hit.$1;
    CardCheck r;
    try {
      final u = UtxoChain.byId('${c['network']}');
      r = '${c['network']}' == 'tron'
          ? await _tron(c, tx)
          : u != null
              ? await _utxo(u, c, tx)
              : await _evm(c, tx);
    } catch (_) {
      r = CardCheck.pending; // network not reachable right now
    }
    _cache[key] = (r, DateTime.now());
    return r;
  }

  static BigInt _amount(Map c) => BigInt.tryParse('${c['amount']}') ?? BigInt.zero;

  static Future<CardCheck> _tron(Map<String, dynamic> c, String tx) async {
    for (final net in [TronNet.main, TronNet.nile]) {
      final api = TronApi(net);
      final t = await api.txById(tx);
      if (t == null) continue;
      final contract = ((t['raw_data'] as Map?)?['contract'] as List?)?.firstOrNull as Map?;
      if (contract == null) return CardCheck.mismatch;
      final v = Map<String, dynamic>.from((contract['parameter'] as Map)['value'] as Map);
      final ret = '${((t['ret'] as List?)?.firstOrNull as Map?)?['contractRet'] ?? ''}';
      if (contract['type'] == 'TransferContract') {
        if (c['contract'] != null) return CardCheck.mismatch;
        if ('${v['to_address']}' != '${c['to']}' || BigInt.from((v['amount'] as num?) ?? 0) != _amount(c)) return CardCheck.mismatch;
        return ret == 'SUCCESS' ? CardCheck.confirmed : (ret.isEmpty ? CardCheck.pending : CardCheck.failed);
      }
      if (contract['type'] == 'TriggerSmartContract') {
        final data = '${v['data'] ?? ''}'.toLowerCase();
        if (c['contract'] == null || '${v['contract_address']}' != '${c['contract']}') return CardCheck.mismatch;
        if (!data.startsWith('a9059cbb') || data.length < 136) return CardCheck.mismatch;
        final to = TronCrypto.addressFromHex(data.substring(32, 72));
        final amt = BigInt.parse(data.substring(72, 136), radix: 16);
        if (to != '${c['to']}' || amt != _amount(c)) return CardCheck.mismatch;
        final info = await api.txInfo(tx);
        final res = '${(info['receipt'] as Map?)?['result'] ?? ''}';
        if (info.isEmpty) return CardCheck.pending;
        return res == 'SUCCESS' ? CardCheck.confirmed : CardCheck.failed;
      }
      return CardCheck.mismatch;
    }
    return CardCheck.pending;
  }

  static Future<CardCheck> _utxo(UtxoChain chain, Map<String, dynamic> c, String tx) async {
    final r = await UtxoApi(chain).checkPayment(tx, '${c['to']}', _amount(c));
    if (r == null) return CardCheck.pending;
    final (paid, confirmed) = r;
    if (!paid) return CardCheck.mismatch;
    return confirmed ? CardCheck.confirmed : CardCheck.pending;
  }

  static const _transferTopic = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';

  static Future<CardCheck> _evm(Map<String, dynamic> c, String tx) async {
    final chain = EvmChain.byId('${c['network']}');
    if (chain == null) return CardCheck.mismatch;
    final api = EvmApi(chain);
    final t = await api.call('eth_getTransactionByHash', [tx]);
    if (t == null) return CardCheck.pending;
    final rc = await api.call('eth_getTransactionReceipt', [tx]);
    final to = '${c['to']}'.toLowerCase();
    if (c['contract'] == null) {
      if ('${(t as Map)['to']}'.toLowerCase() != to || EvmApi.q(t['value']) != _amount(c)) return CardCheck.mismatch;
    } else if (rc != null) {
      // the token's own Transfer event must say: to this address, this amount
      final logs = ((rc as Map)['logs'] as List?) ?? const [];
      final ok = logs.any((l) {
        final m = l as Map;
        final topics = (m['topics'] as List?) ?? const [];
        return '${m['address']}'.toLowerCase() == '${c['contract']}'.toLowerCase() &&
            topics.length == 3 &&
            '${topics[0]}'.toLowerCase() == _transferTopic &&
            '0x${'${topics[2]}'.substring(26)}'.toLowerCase() == to &&
            EvmApi.q(m['data']) == _amount(c);
      });
      if (!ok && EvmApi.q(rc['status']) == BigInt.one) return CardCheck.mismatch;
    }
    if (rc == null) return CardCheck.pending;
    return EvmApi.q((rc as Map)['status']) == BigInt.one ? CardCheck.confirmed : CardCheck.failed;
  }
}
