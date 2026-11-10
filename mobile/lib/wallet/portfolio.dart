import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'evm.dart';
import 'tron_api.dart';
import 'tron_crypto.dart';
import 'solana.dart';
import 'utxo.dart';

/// One coin or token the wallet shows, on one network.
class WalletAsset {
  WalletAsset({
    required this.key,
    required this.network,
    required this.networkName,
    required this.symbol,
    required this.name,
    required this.decimals,
    required this.color,
    required this.glyph,
    this.contract,
    this.gecko,
    this.evm,
    this.evmToken,
    this.utxo,
    this.custom = false,
  });

  final String key; // 'tron:TRX', 'tron:USDT', 'bsc:native', 'bsc:0x55…'
  final String network; // 'tron' | evm chain id
  final String networkName;
  final String symbol;
  final String name;
  final int decimals;
  final Color color;
  final String glyph;
  final String? contract;
  final String? gecko;
  final EvmChain? evm;
  final EvmToken? evmToken;
  final UtxoChain? utxo;
  final bool custom;

  BigInt? balance;
  double? price;
  double? change;

  bool get isTron => network == 'tron';
  bool get isUtxo => utxo != null;
  bool get isSol => network == 'sol';
  bool get isEvm => evm != null;
  bool get isNative => contract == null;
  double get value => balance == null || price == null ? 0 : Units.toDouble(balance!, decimals: decimals) * price!;
  /// What pays the network fee for this asset.
  String get feeSymbol => isTron ? 'TRX' : (isSol ? 'SOL' : (isUtxo ? utxo!.symbol : evm!.symbol));
}

class Portfolio {
  Portfolio._();

  static const _usdtColor = Color(0xFF26A17B);
  static const _usdcColor = Color(0xFF2775CA);

  static List<WalletAsset> build({required TronNet tron, required List<EvmToken> custom}) {
    final out = <WalletAsset>[
      WalletAsset(key: 'tron:USDT', network: 'tron', networkName: 'TRON', symbol: 'USDT', name: 'Tether', decimals: 6, color: _usdtColor, glyph: '₮', contract: tron.usdt, gecko: 'tether'),
      WalletAsset(key: 'tron:TRX', network: 'tron', networkName: 'TRON', symbol: 'TRX', name: 'TRON', decimals: 6, color: const Color(0xFFEB0029), glyph: 'T', gecko: 'tron'),
    ];
    out.add(WalletAsset(
      key: 'sol:native', network: 'sol', networkName: 'Solana', symbol: 'SOL', name: 'Solana', decimals: Sol.decimals,
      color: const Color(0xFF9945FF), glyph: '◎', gecko: 'solana',
    ));
    for (final c in UtxoChain.all) {
      out.add(WalletAsset(
        key: '${c.id}:native', network: c.id, networkName: c.name, symbol: c.symbol, name: c.name, decimals: 8,
        color: Color(c.color), glyph: c.glyph, gecko: c.gecko, utxo: c,
      ));
    }
    for (final c in EvmChain.all) {
      out.add(WalletAsset(
        key: '${c.id}:native', network: c.id, networkName: c.name, symbol: c.symbol, name: c.coinName, decimals: 18,
        color: Color(c.color), glyph: c.symbol.substring(0, 1), gecko: c.gecko, evm: c,
      ));
      for (final t in [...EvmToken.builtIn, ...custom].where((t) => t.chain == c.id)) {
        out.add(WalletAsset(
          key: '${c.id}:${t.address.toLowerCase()}', network: c.id, networkName: c.name, symbol: t.symbol, name: t.name, decimals: t.decimals,
          color: t.symbol == 'USDT' ? _usdtColor : t.symbol == 'USDC' ? _usdcColor : Color(c.color),
          glyph: t.symbol == 'USDT' ? '₮' : t.symbol == 'USDC' ? r'$' : t.symbol.substring(0, 1),
          contract: t.address, gecko: t.gecko, evm: c, evmToken: t, custom: !EvmToken.builtIn.contains(t),
        ));
      }
    }
    return out;
  }

  /// Fills balances and prices. Each network loads on its own: one slow network never blocks the rest.
  static Future<void> load(List<WalletAsset> assets,
      {required String tronAddress, required String evmAddress, required TronNet tron, Map<String, String> utxoAddr = const {}, String? solAddress}) async {
    final jobs = <Future<void>>[];
    // TRON: one call for both
    jobs.add(() async {
      try {
        final b = await TronApi(tron).balance(tronAddress);
        for (final a in assets.where((a) => a.isTron)) {
          a.balance = a.symbol == 'TRX' ? b.trx : b.usdt;
        }
      } catch (_) {}
    }());
    if (solAddress != null) {
      for (final a in assets.where((a) => a.isSol)) {
        jobs.add(() async {
          try {
            a.balance = await SolApi().balance(solAddress);
          } catch (_) {}
        }());
      }
    }
    for (final c in UtxoChain.all) {
      final addr = utxoAddr[c.id];
      if (addr == null) continue;
      for (final a in assets.where((a) => a.network == c.id)) {
        jobs.add(() async {
          try {
            a.balance = await UtxoApi(c).balance(addr);
          } catch (_) {}
        }());
      }
    }
    for (final c in EvmChain.all) {
      final api = EvmApi(c);
      for (final a in assets.where((a) => a.network == c.id)) {
        jobs.add(() async {
          try {
            a.balance = a.isNative ? await api.balance(evmAddress) : await api.tokenBalance(a.contract!, evmAddress);
          } catch (_) {}
        }());
      }
    }
    // prices
    jobs.add(() async {
      final ids = assets.map((a) => a.gecko).whereType<String>().toSet();
      final px = await Prices.byIds(ids);
      for (final a in assets) {
        final p = a.gecko == null ? null : px[a.gecko];
        if (p != null) {
          a.price = p.$1;
          a.change = p.$2;
        }
      }
      for (final c in EvmChain.all) {
        final unknown = assets.where((a) => a.network == c.id && a.gecko == null && a.contract != null).toList();
        if (unknown.isEmpty) continue;
        final tp = await Prices.tokens(c.platform, unknown.map((a) => a.contract!).toList());
        for (final a in unknown) {
          final p = tp[a.contract!.toLowerCase()];
          if (p != null) {
            a.price = p.$1;
            a.change = p.$2;
          }
        }
      }
    }());
    await Future.wait(jobs);
  }
}

/// Transfers sent from this phone on EVM networks (public networks have no free history API;
/// incoming transfers show up in the balance and on the network's explorer).
class SentLog {
  SentLog(this.userId);
  final int userId;
  String get _key => 'wallet_sent_v1_$userId';

  Future<List<WalletTx>> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return [];
    try {
      return [
        for (final j in jsonDecode(raw) as List)
          WalletTx(
            id: '${j['id']}', token: '${j['token']}', from: '${j['from']}', to: '${j['to']}',
            amount: BigInt.parse('${j['amount']}'), time: DateTime.fromMillisecondsSinceEpoch((j['time'] as num).toInt()), ok: true,
            network: '${j['network']}', decimals: (j['decimals'] as num?)?.toInt() ?? 18,
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> add(WalletTx t) async {
    final list = await load();
    list.insert(0, t);
    final out = [
      for (final x in list.take(100))
        {'id': x.id, 'token': x.token, 'from': x.from, 'to': x.to, 'amount': '${x.amount}', 'time': x.time.millisecondsSinceEpoch, 'network': x.network, 'decimals': x.decimals},
    ];
    (await SharedPreferences.getInstance()).setString(_key, jsonEncode(out));
  }
}
