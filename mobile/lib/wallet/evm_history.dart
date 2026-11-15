import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'evm.dart';
import 'tron_api.dart' show WalletTx;

/// Token transfers (USDT, USDC… in AND out) of my 0x address on the EVM networks.
///
/// Public nodes have no "history of an address" call, so the transfers are read from the network's
/// Transfer events, a stretch of blocks at a time. What was found is kept on this phone, and the next
/// look starts where the last one stopped — so the history only grows and stays fast.
class EvmHistory {
  EvmHistory(this.userId);
  final int userId;

  static const _transfer = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
  static const _span = 2000; // blocks per question (what public nodes accept)
  static const _firstLook = 30; // spans looked back the first time
  static const _perRound = 40; // spans read at most per refresh (the rest comes next time)

  String _key(String chain) => 'wallet_evm_hist_v1_${userId}_$chain';

  Future<(int, List<WalletTx>)> _load(String chain) async {
    final raw = (await SharedPreferences.getInstance()).getString(_key(chain));
    if (raw == null) return (0, <WalletTx>[]);
    try {
      final j = jsonDecode(raw) as Map;
      return (
        (j['last'] as num).toInt(),
        [
          for (final t in j['txs'] as List)
            WalletTx(
              id: '${t['id']}', token: '${t['token']}', from: '${t['from']}', to: '${t['to']}', amount: BigInt.parse('${t['amount']}'),
              time: DateTime.fromMillisecondsSinceEpoch((t['time'] as num).toInt()), ok: true, network: chain, decimals: (t['decimals'] as num).toInt(),
            ),
        ],
      );
    } catch (_) {
      return (0, <WalletTx>[]);
    }
  }

  Future<void> _save(String chain, int last, List<WalletTx> txs) async {
    final keep = txs.take(200).toList();
    await (await SharedPreferences.getInstance()).setString(
      _key(chain),
      jsonEncode({
        'last': last,
        'txs': [
          for (final t in keep)
            {'id': t.id, 'token': t.token, 'from': t.from, 'to': t.to, 'amount': '${t.amount}', 'time': t.time.millisecondsSinceEpoch, 'decimals': t.decimals},
        ],
      }),
    );
  }

  static String _topic(String address) => '0x${address.substring(2).toLowerCase().padLeft(64, '0')}';
  static String _addrOf(String topic) => '0x${topic.substring(topic.length - 40)}';
  static int _int(dynamic hex) => EvmApi.q(hex).toInt();

  /// What is known for this network (from the phone), after reading the new blocks.
  Future<List<WalletTx>> load(EvmChain chain, String me, List<EvmToken> tokens) async {
    var (last, txs) = await _load(chain.id);
    if (tokens.isEmpty) return txs;
    final api = EvmApi(chain);
    try {
      final head = _int(await api.call('eth_blockNumber', const []));
      // times: worked out from the block number (one look at two blocks is enough for this)
      final h = await api.call('eth_getBlockByNumber', ['0x${head.toRadixString(16)}', false]) as Map;
      final back = head - 5000;
      final b = await api.call('eth_getBlockByNumber', ['0x${back.toRadixString(16)}', false]) as Map;
      final headTs = _int(h['timestamp']);
      final perBlock = (headTs - _int(b['timestamp'])) / 5000;
      DateTime timeOf(int block) => DateTime.fromMillisecondsSinceEpoch(((headTs - (head - block) * perBlock) * 1000).round());

      var from = last > 0 ? last + 1 : head - _span * _firstLook;
      if (head - from > _span * 400) from = head - _span * 400; // away for weeks: the recent part
      final contracts = [for (final t in tokens) t.address];
      final byContract = {for (final t in tokens) t.address.toLowerCase(): t};
      final seen = txs.map((t) => t.id.toLowerCase()).toSet();
      var rounds = 0;
      while (from <= head && rounds < _perRound) {
        final to = (from + _span - 1).clamp(from, head);
        final range = {'fromBlock': '0x${from.toRadixString(16)}', 'toBlock': '0x${to.toRadixString(16)}', 'address': contracts};
        final logs = [
          ...(await api.call('eth_getLogs', [{...range, 'topics': [_transfer, null, _topic(me)]}]) as List? ?? const []),
          ...(await api.call('eth_getLogs', [{...range, 'topics': [_transfer, _topic(me)]}]) as List? ?? const []),
        ];
        for (final raw in logs) {
          final l = Map<String, dynamic>.from(raw as Map);
          final topics = (l['topics'] as List).map((x) => '$x').toList();
          final token = byContract['${l['address']}'.toLowerCase()];
          if (token == null || topics.length < 3 || l['removed'] == true) continue;
          final id = '${l['transactionHash']}'.toLowerCase();
          if (!seen.add('$id:${l['logIndex']}') || !seen.add(id)) continue;
          txs.add(WalletTx(
            id: id,
            token: token.symbol,
            from: _addrOf(topics[1]),
            to: _addrOf(topics[2]),
            amount: EvmApi.q(l['data']),
            time: timeOf(_int(l['blockNumber'])),
            ok: true,
            network: chain.id,
            decimals: token.decimals,
          ));
        }
        last = to;
        from = to + 1;
        rounds++;
      }
      txs.sort((a, b) => b.time.compareTo(a.time));
      await _save(chain.id, last, txs);
    } catch (_) {
      // the network didn't answer: show what we have, the next refresh goes on from where it stopped
    }
    return txs;
  }
}
