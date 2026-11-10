import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'tron_crypto.dart';

/// One TRON network (main or the Nile test network).
class TronNet {
  const TronNet._(this.id, this.name, this.api, this.usdt, this.explorer);
  final String id;
  final String name;
  final String api;
  final String usdt; // USDT (TRC-20) contract
  final String explorer;

  static const main = TronNet._('main', 'TRON', 'https://api.trongrid.io', 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t', 'https://tronscan.org/#/transaction/');
  static const nile = TronNet._('nile', 'Nile testnet', 'https://nile.trongrid.io', 'TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf', 'https://nile.tronscan.org/#/transaction/');
  static TronNet byId(String? id) => id == 'nile' ? nile : main;
  bool get isTest => id != 'main';
}

class WalletBalance {
  WalletBalance({required this.trx, required this.usdt, required this.activated});
  final BigInt trx; // sun
  final BigInt usdt; // 6 decimals
  final bool activated;
}

class WalletTx {
  WalletTx({required this.id, required this.token, required this.from, required this.to, required this.amount, required this.time, required this.ok,
      this.network = 'tron', this.decimals = 6});
  final String id;
  final String token; // symbol: 'USDT' | 'TRX' | 'ETH' …
  final String from;
  final String to;
  final BigInt amount;
  final DateTime time;
  final bool ok;
  final String network; // 'tron' | evm chain id
  final int decimals;
}

/// A transaction ready to sign, with what it will cost.
class PreparedTx {
  PreparedTx({required this.json, required this.id, required this.feeSun, required this.token, required this.to, required this.amount});
  final Map<String, dynamic> json;
  final Uint8List id; // sha256(raw_data) — what gets signed
  final BigInt feeSun; // estimate, burnt from TRX
  final String token;
  final String to;
  final BigInt amount;
}

class WalletException implements Exception {
  WalletException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Talks to the public TRON network directly over https. Nothing here ever sees the key:
/// transactions come back unsigned, are CHECKED field by field, and are signed on the phone.
class TronApi {
  TronApi(this.net, {http.Client? client}) : _http = client ?? http.Client();
  final TronNet net;
  final http.Client _http;

  static const feeLimitSun = 50000000; // never burn more than 50 TRX on one USDT transfer

  Future<dynamic> _get(String path, {int tries = 3}) async {
    final r = await _http.get(Uri.parse('${net.api}$path'), headers: {'accept': 'application/json'}).timeout(const Duration(seconds: 15));
    if (r.statusCode == 429 && tries > 1) {
      await Future<void>.delayed(Duration(milliseconds: 700 * (4 - tries)));
      return _get(path, tries: tries - 1);
    }
    if (r.statusCode == 429) throw WalletException('The network is busy. Try again in a moment.');
    if (r.statusCode != 200) throw WalletException('Network error (${r.statusCode})');
    return jsonDecode(r.body);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, {int tries = 3}) async {
    final r = await _http
        .post(Uri.parse('${net.api}$path'), headers: {'content-type': 'application/json', 'accept': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 429 && tries > 1) {
      await Future<void>.delayed(Duration(milliseconds: 700 * (4 - tries)));
      return _post(path, body, tries: tries - 1);
    }
    if (r.statusCode == 429) throw WalletException('The network is busy. Try again in a moment.');
    if (r.statusCode != 200) throw WalletException('Network error (${r.statusCode})');
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  // ------------------------------------------------------------------ reading
  Future<WalletBalance> balance(String address) async {
    final j = await _get('/v1/accounts/$address') as Map;
    final data = (j['data'] as List?) ?? const [];
    if (data.isEmpty) return WalletBalance(trx: BigInt.zero, usdt: BigInt.zero, activated: false);
    final a = Map<String, dynamic>.from(data.first as Map);
    var usdt = BigInt.zero;
    for (final t in (a['trc20'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(t as Map);
      if (m.containsKey(net.usdt)) usdt = BigInt.parse('${m[net.usdt]}');
    }
    return WalletBalance(trx: BigInt.from((a['balance'] as num?) ?? 0), usdt: usdt, activated: true);
  }

  Future<List<WalletTx>> history(String address) async {
    final out = <WalletTx>[];
    final t20 = await _get('/v1/accounts/$address/transactions/trc20?limit=40&contract_address=${net.usdt}') as Map;
    for (final x in (t20['data'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(x as Map);
      out.add(WalletTx(
        id: '${m['transaction_id']}',
        token: 'USDT',
        from: '${m['from']}',
        to: '${m['to']}',
        amount: BigInt.tryParse('${m['value']}') ?? BigInt.zero,
        time: DateTime.fromMillisecondsSinceEpoch((m['block_timestamp'] as num?)?.toInt() ?? 0),
        ok: true,
      ));
    }
    final trx = await _get('/v1/accounts/$address/transactions?limit=40&only_confirmed=true') as Map;
    for (final x in (trx['data'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(x as Map);
      final contract = ((m['raw_data'] as Map?)?['contract'] as List?)?.firstOrNull as Map?;
      if (contract == null || contract['type'] != 'TransferContract') continue;
      final v = Map<String, dynamic>.from((contract['parameter'] as Map)['value'] as Map);
      final ret = (m['ret'] as List?)?.firstOrNull as Map?;
      out.add(WalletTx(
        id: '${m['txID']}',
        token: 'TRX',
        from: TronCrypto.addressFromHex('${v['owner_address']}'),
        to: TronCrypto.addressFromHex('${v['to_address']}'),
        amount: BigInt.from((v['amount'] as num?) ?? 0),
        time: DateTime.fromMillisecondsSinceEpoch((m['block_timestamp'] as num?)?.toInt() ?? 0),
        ok: ret == null || ret['contractRet'] == null || ret['contractRet'] == 'SUCCESS',
      ));
    }
    out.sort((a, b) => b.time.compareTo(a.time));
    return out;
  }

  // ------------------------------------------------------------------ sending
  Future<PreparedTx> prepareUsdt(String from, String to, BigInt amount) async {
    final toBytes = TronCrypto.decodeAddress(to);
    if (toBytes == null) throw WalletException('This is not a TRON address');
    final param = TronCrypto.hex(toBytes.sublist(1)).padLeft(64, '0') + amount.toRadixString(16).padLeft(64, '0');
    final body = {
      'owner_address': from,
      'contract_address': net.usdt,
      'function_selector': 'transfer(address,uint256)',
      'parameter': param,
      'fee_limit': feeLimitSun,
      'call_value': 0,
      'visible': true,
    };
    final r = await _post('/wallet/triggersmartcontract', body);
    if ((r['result'] as Map?)?['result'] != true || r['transaction'] == null) {
      throw WalletException(_why(r['result']) ?? 'Could not prepare the transfer');
    }
    final tx = Map<String, dynamic>.from(r['transaction'] as Map);
    final id = TxCheck.usdt(tx, from: from, to: to, amount: amount, usdt: net.usdt, maxFee: feeLimitSun);
    final fee = await _usdtFee(from, body);
    return PreparedTx(json: tx, id: id, feeSun: fee, token: 'USDT', to: to, amount: amount);
  }

  Future<PreparedTx> prepareTrx(String from, String to, BigInt amount) async {
    if (TronCrypto.decodeAddress(to) == null) throw WalletException('This is not a TRON address');
    final r = await _post('/wallet/createtransaction', {'owner_address': from, 'to_address': to, 'amount': amount.toInt(), 'visible': true});
    if (r['Error'] != null || r['raw_data_hex'] == null) throw WalletException(_why(r) ?? 'Could not prepare the transfer');
    final id = TxCheck.trx(r, from: from, to: to, amount: amount);
    final fee = await _bandwidthFee(from, 300);
    // sending to a new address activates it: the network charges 1 TRX for that
    final dest = await _get('/v1/accounts/$to') as Map;
    final newAccount = ((dest['data'] as List?) ?? const []).isEmpty;
    return PreparedTx(json: r, id: id, feeSun: fee + (newAccount ? BigInt.from(1000000) : BigInt.zero), token: 'TRX', to: to, amount: amount);
  }

  Future<BigInt> _usdtFee(String from, Map<String, dynamic> body) async {
    try {
      final est = await _post('/wallet/triggerconstantcontract', body);
      // an account without USDT can't simulate its own transfer (the estimate then says 0):
      // fall back to what a USDT transfer normally needs, more when the receiver never held USDT
      var energy = (est['energy_used'] as num?)?.toInt() ?? 0;
      if (energy <= 0) energy = 65000;
      final res = await _post('/wallet/getaccountresource', {'address': from, 'visible': true});
      final freeEnergy = (((res['EnergyLimit'] as num?) ?? 0) - ((res['EnergyUsed'] as num?) ?? 0)).toInt();
      final price = await _energyPrice();
      final burn = (energy - freeEnergy).clamp(0, 1 << 30) * price;
      return BigInt.from(burn) + await _bandwidthFee(from, 350, res: res);
    } catch (_) {
      return BigInt.from(30000000); // a safe guess (about 30 TRX) when the estimate isn't available
    }
  }

  Future<int> _energyPrice() async {
    final p = await _get('/wallet/getchainparameters') as Map;
    for (final x in (p['chainParameter'] as List?) ?? const []) {
      if ((x as Map)['key'] == 'getEnergyFee') return (x['value'] as num).toInt();
    }
    return 210;
  }

  Future<BigInt> _bandwidthFee(String from, int bytes, {Map<String, dynamic>? res}) async {
    final r = res ?? await _post('/wallet/getaccountresource', {'address': from, 'visible': true});
    final free = (((r['freeNetLimit'] as num?) ?? 0) - ((r['freeNetUsed'] as num?) ?? 0)) + (((r['NetLimit'] as num?) ?? 0) - ((r['NetUsed'] as num?) ?? 0));
    return free >= bytes ? BigInt.zero : BigInt.from(bytes * 1000);
  }

  /// Signs on the phone and sends. Returns the transaction id.
  Future<String> broadcast(PreparedTx p, Uint8List privateKey) async {
    final sig = TronCrypto.sign(p.id, privateKey);
    // send exactly the bytes that were checked and signed: Transaction { raw_data = 1, signature = 2 }
    final raw = TronCrypto.fromHex('${p.json['raw_data_hex']}');
    if (TronCrypto.hex(TronCrypto.sha256(raw)) != TronCrypto.hex(p.id)) throw WalletException('Bad transaction');
    final tx = <int>[0x0a, ..._varint(raw.length), ...raw, 0x12, ..._varint(sig.length), ...sig];
    final r = await _post('/wallet/broadcasthex', {'transaction': TronCrypto.hex(tx)});
    if (r['result'] != true) throw WalletException(_why(r) ?? 'The network did not accept the transfer');
    return TronCrypto.hex(p.id);
  }

  static List<int> _varint(int v) {
    final out = <int>[];
    var x = v;
    while (x >= 0x80) {
      out.add((x & 0x7f) | 0x80);
      x >>= 7;
    }
    out.add(x);
    return out;
  }

  static String? _why(dynamic r) {
    if (r is! Map) return null;
    final raw = '${r['message'] ?? r['Error'] ?? r['code'] ?? ''}';
    if (raw.isEmpty) return null;
    var msg = raw;
    if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(raw) && raw.length.isEven) {
      try {
        msg = utf8.decode(TronCrypto.fromHex(raw), allowMalformed: true);
      } catch (_) {}
    }
    if (msg.contains('balance is not sufficient') || msg.contains('Not enough') || msg.contains('insufficient')) return 'Not enough TRX for the network fee';
    if (msg.contains('does not exist')) return 'Your wallet isn’t active yet: receive some TRX first';
    return msg.length > 140 ? '${msg.substring(0, 140)}…' : msg;
  }
}

/// Reads an unsigned transaction's protobuf bytes and refuses to go on unless it does EXACTLY what
/// the person asked: right type, from me, to the right address, the right amount, a bounded fee.
/// (So a wrong or tampered answer from the network can never get signed.)
class TxCheck {
  TxCheck._();

  static Uint8List usdt(Map<String, dynamic> tx, {required String from, required String to, required BigInt amount, required String usdt, required int maxFee}) {
    final raw = _raw(tx);
    final f = _fields(raw);
    final fee = _int(f[18]);
    if (fee == null || fee > maxFee) throw WalletException('Unexpected network fee limit');
    final c = _contract(f, 31); // TriggerSmartContract
    final owner = c[1]?.first as List<int>?;
    final contract = c[2]?.first as List<int>?;
    final value = _int(c[3]) ?? 0;
    final data = c[4]?.first as List<int>?;
    final expect = <int>[0xa9, 0x05, 0x9c, 0xbb, ...List.filled(12, 0), ...TronCrypto.decodeAddress(to)!.sublist(1), ..._u256(amount)];
    if (!_same(owner, TronCrypto.decodeAddress(from)) || !_same(contract, TronCrypto.decodeAddress(usdt)) || value != 0 || !_same(data, expect)) {
      throw WalletException('The transfer from the network didn’t match what you asked for. Nothing was sent.');
    }
    return _id(tx, raw);
  }

  static Uint8List trx(Map<String, dynamic> tx, {required String from, required String to, required BigInt amount}) {
    final raw = _raw(tx);
    final f = _fields(raw);
    final c = _contract(f, 1); // TransferContract
    final owner = c[1]?.first as List<int>?;
    final dest = c[2]?.first as List<int>?;
    final value = _int(c[3]);
    if (!_same(owner, TronCrypto.decodeAddress(from)) || !_same(dest, TronCrypto.decodeAddress(to)) || value == null || BigInt.from(value) != amount) {
      throw WalletException('The transfer from the network didn’t match what you asked for. Nothing was sent.');
    }
    return _id(tx, raw);
  }

  static Uint8List _raw(Map<String, dynamic> tx) {
    final h = tx['raw_data_hex'];
    if (h is! String || h.isEmpty) throw WalletException('Bad answer from the network');
    return TronCrypto.fromHex(h);
  }

  static Uint8List _id(Map<String, dynamic> tx, Uint8List raw) {
    final id = TronCrypto.sha256(raw);
    if (TronCrypto.hex(id) != '${tx['txID']}'.toLowerCase()) throw WalletException('Bad answer from the network');
    // the readable copy must say the same as the bytes we checked (it is what gets broadcast)
    final expiration = (tx['raw_data'] as Map?)?['expiration'];
    final f = _fields(raw);
    if (expiration != null && _int(f[8]) != (expiration as num).toInt()) throw WalletException('Bad answer from the network');
    final exp = _int(f[8]) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (exp < now - 60000 || exp > now + 24 * 3600 * 1000) throw WalletException('Bad answer from the network');
    return id;
  }

  /// The one contract inside, which must have [type]; returns its fields.
  static Map<int, List<Object>> _contract(Map<int, List<Object>> f, int type) {
    final list = f[11];
    if (list == null || list.length != 1) throw WalletException('Unexpected transaction');
    final cf = _fields(Uint8List.fromList(list.first as List<int>));
    if (_int(cf[1]) != type) throw WalletException('Unexpected transaction');
    final any = _fields(Uint8List.fromList(cf[2]!.first as List<int>));
    return _fields(Uint8List.fromList(any[2]!.first as List<int>));
  }

  static List<int> _u256(BigInt v) {
    final h = v.toRadixString(16).padLeft(64, '0');
    return TronCrypto.fromHex(h);
  }

  static int? _int(List<Object>? v) => v == null || v.isEmpty || v.first is! int ? null : v.first as int;

  static bool _same(List<int>? a, List<int>? b) {
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Minimal protobuf reader: field number → values (int for varints, bytes for length-delimited).
  static Map<int, List<Object>> _fields(Uint8List b) {
    final out = <int, List<Object>>{};
    var i = 0;
    int varint() {
      var shift = 0;
      var result = 0;
      while (true) {
        if (i >= b.length) throw WalletException('Bad transaction');
        final byte = b[i++];
        result |= (byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
        if (shift > 63) throw WalletException('Bad transaction');
      }
    }

    while (i < b.length) {
      final key = varint();
      final field = key >> 3;
      switch (key & 7) {
        case 0:
          (out[field] ??= []).add(varint());
        case 2:
          final len = varint();
          if (len < 0 || i + len > b.length) throw WalletException('Bad transaction');
          (out[field] ??= []).add(b.sublist(i, i + len));
          i += len;
        case 1:
          i += 8;
        case 5:
          i += 4;
        default:
          throw WalletException('Bad transaction');
      }
    }
    return out;
  }
}

// ------------------------------------------------------------------ prices (in US dollars)
class PricePoint {
  PricePoint(this.time, this.usd);
  final DateTime time;
  final double usd;
}

class Prices {
  Prices._();
  static final Map<String, (double, double, DateTime)> _now = {}; // id → (usd, change24h %, fetched)
  static final Map<String, (List<PricePoint>, DateTime)> _charts = {};

  static Future<Map<String, (double, double)>> current() => byIds(const ['tron', 'tether']);

  /// Dollar price and 24 h change (%) by CoinGecko id; cached for 2 minutes.
  static Future<Map<String, (double, double)>> byIds(Iterable<String> ids) async {
    final want = ids.toSet();
    final stale = want.where((id) => _now[id] == null || DateTime.now().difference(_now[id]!.$3) > const Duration(minutes: 2)).toList();
    if (stale.isNotEmpty) {
      try {
        final r = await http
            .get(Uri.parse('https://api.coingecko.com/api/v3/simple/price?ids=${stale.join(',')}&vs_currencies=usd&include_24hr_change=true'))
            .timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) {
          final j = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
          for (final id in stale) {
            final m = j[id] as Map?;
            if (m != null && m['usd'] != null) _now[id] = ((m['usd'] as num).toDouble(), ((m['usd_24h_change'] as num?) ?? 0).toDouble(), DateTime.now());
          }
        }
      } catch (_) {}
    }
    return {for (final id in want) if (_now[id] != null) id: (_now[id]!.$1, _now[id]!.$2)};
  }

  /// Prices of tokens added by address (key = lower-case address).
  static Future<Map<String, (double, double)>> tokens(String platform, List<String> addresses) async {
    if (addresses.isEmpty) return const {};
    final key = (String a) => '$platform:${a.toLowerCase()}';
    final stale = addresses.where((a) => _now[key(a)] == null || DateTime.now().difference(_now[key(a)]!.$3) > const Duration(minutes: 5)).toList();
    if (stale.isNotEmpty) {
      try {
        final r = await http
            .get(Uri.parse('https://api.coingecko.com/api/v3/simple/token_price/$platform?contract_addresses=${stale.join(',')}&vs_currencies=usd&include_24hr_change=true'))
            .timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) {
          final j = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
          for (final e in j.entries) {
            final m = e.value as Map;
            if (m['usd'] != null) _now[key(e.key)] = ((m['usd'] as num).toDouble(), ((m['usd_24h_change'] as num?) ?? 0).toDouble(), DateTime.now());
          }
        }
      } catch (_) {}
    }
    return {for (final a in addresses) if (_now[key(a)] != null) a.toLowerCase(): (_now[key(a)]!.$1, _now[key(a)]!.$2)};
  }

  static Future<List<PricePoint>> chart(String coin, int days) async {
    final key = '$coin:$days';
    final c = _charts[key];
    if (c != null && DateTime.now().difference(c.$2) < const Duration(minutes: 10)) return c.$1;
    final r = await http
        .get(Uri.parse('https://api.coingecko.com/api/v3/coins/$coin/market_chart?vs_currency=usd&days=$days'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw WalletException('Prices are not available right now');
    final j = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    final pts = [
      for (final p in (j['prices'] as List? ?? const []))
        PricePoint(DateTime.fromMillisecondsSinceEpoch(((p as List)[0] as num).toInt()), (p[1] as num).toDouble()),
    ];
    _charts[key] = (pts, DateTime.now());
    return pts;
  }
}
