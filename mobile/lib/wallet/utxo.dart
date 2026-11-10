import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/digests/ripemd160.dart';

import 'tron_api.dart' show WalletException, WalletTx;
import 'tron_crypto.dart';

/// Bitcoin-family networks: coins live in "unspent outputs" (UTXOs) instead of an account balance.
class UtxoChain {
  const UtxoChain({
    required this.id,
    required this.name,
    required this.symbol,
    required this.gecko,
    required this.coin,
    required this.purpose,
    required this.hrp,
    required this.p2pkh,
    required this.p2sh,
    required this.apis,
    required this.blockcypher,
    required this.explorer,
    required this.color,
    required this.glyph,
    required this.dust,
    required this.maxFee,
    required this.minFeePerKb,
  });
  final String id; // 'btc' | 'ltc' | 'doge'
  final String name;
  final String symbol;
  final String gecko;
  final int coin; // BIP-44 coin type
  final int purpose; // 84 = native SegWit (bc1…), 44 = legacy (D…)
  final String? hrp; // bech32 prefix, null when the network has no SegWit
  final List<int> p2pkh; // Base58 version bytes
  final List<int> p2sh;
  final List<String> apis; // mempool-style APIs
  final bool blockcypher; // DOGE: BlockCypher API instead
  final String explorer;
  final int color;
  final String glyph;
  final int dust; // smallest change worth keeping (smallest unit)
  final int maxFee; // refuse fees above this (smallest unit)
  final int minFeePerKb; // network minimum (smallest unit per 1000 bytes)

  bool get segwit => hrp != null;
  String txUrl(String id) => '$explorer/tx/$id';
  String addressUrl(String a) => '$explorer/address/$a';

  static const btc = UtxoChain(
    id: 'btc', name: 'Bitcoin', symbol: 'BTC', gecko: 'bitcoin', coin: 0, purpose: 84, hrp: 'bc', p2pkh: [0x00], p2sh: [0x05],
    apis: ['https://mempool.space/api', 'https://blockstream.info/api'], blockcypher: false,
    explorer: 'https://mempool.space', color: 0xFFF7931A, glyph: '₿', dust: 546, maxFee: 300000, minFeePerKb: 1000,
  );
  static const ltc = UtxoChain(
    id: 'ltc', name: 'Litecoin', symbol: 'LTC', gecko: 'litecoin', coin: 2, purpose: 84, hrp: 'ltc', p2pkh: [0x30], p2sh: [0x32, 0x05],
    apis: ['https://litecoinspace.org/api'], blockcypher: false,
    explorer: 'https://litecoinspace.org', color: 0xFF345D9D, glyph: 'Ł', dust: 1000, maxFee: 5000000, minFeePerKb: 1000,
  );
  static const doge = UtxoChain(
    id: 'doge', name: 'Dogecoin', symbol: 'DOGE', gecko: 'dogecoin', coin: 3, purpose: 44, hrp: null, p2pkh: [0x1e], p2sh: [0x16],
    apis: ['https://api.blockcypher.com/v1/doge/main'], blockcypher: true,
    explorer: 'https://blockchair.com/dogecoin', color: 0xFFC2A633, glyph: 'Ð', dust: 1000000, maxFee: 1000000000, minFeePerKb: 1000000,
  );

  static const all = [btc, ltc, doge];
  static UtxoChain? byId(String id) => all.where((c) => c.id == id).firstOrNull;
}

// ======================================================================== keys, addresses, scripts
class UtxoCrypto {
  UtxoCrypto._();

  /// m/84'/0'/0'/0/0 (BTC), m/84'/2'/0'/0/0 (LTC), m/44'/3'/0'/0/0 (DOGE) — what Trust Wallet uses.
  static Uint8List privateKey(String phrase, UtxoChain c, {int index = 0}) =>
      TronCrypto.derive(TronCrypto.seedOf(phrase), [0x80000000 + c.purpose, 0x80000000 + c.coin, 0x80000000, 0, index]);

  static Uint8List compressedPub(Uint8List priv) {
    final p = TronCrypto.publicKey(priv); // 04‖x‖y
    return Uint8List.fromList([(p[64] & 1) == 1 ? 3 : 2, ...p.sublist(1, 33)]);
  }

  static Uint8List hash160(List<int> b) => RIPEMD160Digest().process(TronCrypto.sha256(b));

  static String addressOf(Uint8List priv, UtxoChain c) {
    final h = hash160(compressedPub(priv));
    return c.segwit ? Bech32.encode(c.hrp!, 0, h) : TronCrypto.base58check(Uint8List.fromList([...c.p2pkh.take(1), ...h]));
  }

  /// The output script that pays [address], or null when it isn't an address of this network.
  static List<int>? scriptFor(String address, UtxoChain c) {
    final a = address.trim();
    if (c.segwit && a.toLowerCase().startsWith('${c.hrp}1')) {
      final d = Bech32.decode(a, c.hrp!);
      if (d == null) return null;
      final (ver, prog) = d;
      if (ver == 0 && (prog.length == 20 || prog.length == 32)) return [0x00, prog.length, ...prog];
      if (ver == 1 && prog.length == 32) return [0x51, 0x20, ...prog]; // Taproot
      return null;
    }
    final raw = TronCrypto.base58decode(a);
    if (raw == null || raw.length != 25) return null;
    final sum = TronCrypto.sha256(TronCrypto.sha256(raw.sublist(0, 21))).sublist(0, 4);
    for (var i = 0; i < 4; i += 1) {
      if (sum[i] != raw[21 + i]) return null;
    }
    final h = raw.sublist(1, 21);
    if (c.p2pkh.contains(raw[0])) return [0x76, 0xa9, 0x14, ...h, 0x88, 0xac];
    if (c.p2sh.contains(raw[0])) return [0xa9, 0x14, ...h, 0x87];
    return null;
  }

  static bool isValidAddress(String a, UtxoChain c) => scriptFor(a, c) != null;

  static Uint8List dsha(List<int> b) => TronCrypto.sha256(TronCrypto.sha256(b));

  /// DER signature + sighash byte.
  static List<int> der(Uint8List sig65) {
    List<int> intBytes(List<int> b) {
      var x = b.toList();
      while (x.length > 1 && x[0] == 0 && x[1] < 0x80) {
        x = x.sublist(1);
      }
      if (x[0] >= 0x80) x = [0, ...x];
      return [0x02, x.length, ...x];
    }

    final r = intBytes(sig65.sublist(0, 32));
    final s = intBytes(sig65.sublist(32, 64));
    return [0x30, r.length + s.length, ...r, ...s, 0x01];
  }
}

/// Bech32 (BIP-173) / Bech32m (BIP-350) for SegWit addresses.
class Bech32 {
  Bech32._();
  static const _cs = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  static const _gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];

  static int _polymod(List<int> v) {
    var c = 1;
    for (final x in v) {
      final b = c >> 25;
      c = ((c & 0x1ffffff) << 5) ^ x;
      for (var i = 0; i < 5; i += 1) {
        if ((b >> i) & 1 == 1) c ^= _gen[i];
      }
    }
    return c;
  }

  static List<int> _hrp(String h) => [...h.codeUnits.map((x) => x >> 5), 0, ...h.codeUnits.map((x) => x & 31)];

  static List<int>? _conv(List<int> data, int from, int to, bool pad) {
    var acc = 0, bits = 0;
    final out = <int>[];
    final max = (1 << to) - 1;
    for (final v in data) {
      if (v < 0 || v >> from != 0) return null;
      acc = (acc << from) | v;
      bits += from;
      while (bits >= to) {
        bits -= to;
        out.add((acc >> bits) & max);
      }
    }
    if (pad) {
      if (bits > 0) out.add((acc << (to - bits)) & max);
    } else if (bits >= from || ((acc << (to - bits)) & max) != 0) {
      return null;
    }
    return out;
  }

  static String encode(String hrp, int version, List<int> program) {
    final data = [version, ..._conv(program, 8, 5, true)!];
    final k = version == 0 ? 1 : 0x2bc830a3;
    final p = _polymod([..._hrp(hrp), ...data, 0, 0, 0, 0, 0, 0]) ^ k;
    final check = [for (var i = 0; i < 6; i += 1) (p >> (5 * (5 - i))) & 31];
    return '${hrp}1${[...data, ...check].map((x) => _cs[x]).join()}';
  }

  /// (witness version, program) or null.
  static (int, List<int>)? decode(String addr, String hrp) {
    if (addr.toLowerCase() != addr && addr.toUpperCase() != addr) return null;
    final a = addr.toLowerCase();
    final pos = a.lastIndexOf('1');
    if (pos < 1 || pos + 7 > a.length || a.length > 90 || a.substring(0, pos) != hrp) return null;
    final data = <int>[];
    for (final ch in a.substring(pos + 1).split('')) {
      final v = _cs.indexOf(ch);
      if (v < 0) return null;
      data.add(v);
    }
    final chk = _polymod([..._hrp(hrp), ...data]);
    final ver = data[0];
    if (!((ver == 0 && chk == 1) || (ver > 0 && chk == 0x2bc830a3))) return null;
    final prog = _conv(data.sublist(1, data.length - 6), 5, 8, false);
    if (prog == null || prog.length < 2 || prog.length > 40 || ver > 16) return null;
    return (ver, prog);
  }
}

// ======================================================================== transactions
class Utxo {
  Utxo(this.txid, this.vout, this.value);
  final String txid;
  final int vout;
  final int value;
}

class UtxoPrepared {
  UtxoPrepared({required this.chain, required this.to, required this.amount, required this.fee, required this.inputs, required this.change, required this.from});
  final UtxoChain chain;
  final String to;
  final String from;
  final BigInt amount; // what the receiver gets
  final BigInt fee;
  final List<Utxo> inputs;
  final BigInt change;
}

class UtxoTx {
  UtxoTx._();

  static List<int> _u32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];
  static List<int> _u64(int v) {
    final b = ByteData(8)..setUint64(0, v, Endian.little);
    return b.buffer.asUint8List();
  }

  static List<int> _varint(int n) {
    if (n < 0xfd) return [n];
    if (n <= 0xffff) return [0xfd, n & 0xff, n >> 8];
    return [0xfe, ..._u32(n)];
  }

  static List<int> _txidLE(String txid) => TronCrypto.fromHex(txid).reversed.toList();

  /// Size estimate in virtual bytes (SegWit) or bytes (legacy).
  static int vsize(UtxoChain c, int inputs, List<int> outScriptLens) {
    final outs = outScriptLens.fold(0, (s, l) => s + 9 + l);
    return c.segwit ? 11 + inputs * 68 + outs : 10 + inputs * 148 + outs;
  }

  /// BIP-143 signature hash of one SegWit input (SIGHASH_ALL).
  static Uint8List bip143({
    required int version,
    required List<int> hashPrevouts,
    required List<int> hashSequence,
    required List<int> outpoint,
    required List<int> scriptCode,
    required int value,
    required List<int> sequence,
    required List<int> hashOutputs,
    required int locktime,
  }) =>
      UtxoCrypto.dsha([
        ..._u32(version), ...hashPrevouts, ...hashSequence, ...outpoint,
        ..._varint(scriptCode.length), ...scriptCode, ..._u64(value), ...sequence, ...hashOutputs, ..._u32(locktime), ..._u32(1),
      ]);

  /// Signs every input (all are our own P2WPKH / P2PKH outputs) and returns the raw transaction.
  static Uint8List sign(UtxoPrepared p, Uint8List priv) {
    final c = p.chain;
    final pub = UtxoCrypto.compressedPub(priv);
    final pkh = UtxoCrypto.hash160(pub);
    final myScript = [0x76, 0xa9, 0x14, ...pkh, 0x88, 0xac]; // P2PKH, and the BIP-143 scriptCode for P2WPKH
    final outputs = <List<int>>[
      [..._u64(p.amount.toInt()), ..._varint(UtxoCrypto.scriptFor(p.to, c)!.length), ...UtxoCrypto.scriptFor(p.to, c)!],
      if (p.change > BigInt.zero) [..._u64(p.change.toInt()), ..._varint(UtxoCrypto.scriptFor(p.from, c)!.length), ...UtxoCrypto.scriptFor(p.from, c)!],
    ];
    final outBytes = [..._varint(outputs.length), for (final o in outputs) ...o];
    const seq = [0xfd, 0xff, 0xff, 0xff]; // replace-by-fee allowed
    const version = 2;
    if (c.segwit) {
      final prevouts = [for (final i in p.inputs) ..._txidLE(i.txid), ..._u32(i.vout)];
      final hashPrevouts = UtxoCrypto.dsha(prevouts);
      final hashSequence = UtxoCrypto.dsha([for (final _ in p.inputs) ...seq]);
      final hashOutputs = UtxoCrypto.dsha([for (final o in outputs) ...o]);
      final witnesses = <List<int>>[];
      for (final i in p.inputs) {
        final hash = bip143(
          version: version, hashPrevouts: hashPrevouts, hashSequence: hashSequence, outpoint: [..._txidLE(i.txid), ..._u32(i.vout)],
          scriptCode: myScript, value: i.value, sequence: seq, hashOutputs: hashOutputs, locktime: 0,
        );
        final sig = UtxoCrypto.der(TronCrypto.sign(hash, priv));
        witnesses.add([0x02, sig.length, ...sig, pub.length, ...pub]);
      }
      return Uint8List.fromList([
        ..._u32(version), 0x00, 0x01,
        ..._varint(p.inputs.length), for (final i in p.inputs) ...[..._txidLE(i.txid), ..._u32(i.vout), 0x00, ...seq],
        ...outBytes,
        for (final w in witnesses) ...w,
        ..._u32(0),
      ]);
    }
    // legacy (Dogecoin): each input signs a copy where only it carries our script
    final scriptSigs = <List<int>>[];
    for (var k = 0; k < p.inputs.length; k += 1) {
      final copy = [
        ..._u32(version),
        ..._varint(p.inputs.length),
        for (var j = 0; j < p.inputs.length; j += 1) ...[
          ..._txidLE(p.inputs[j].txid), ..._u32(p.inputs[j].vout),
          if (j == k) ...[..._varint(myScript.length), ...myScript] else 0x00,
          ...seq,
        ],
        ...outBytes, ..._u32(0), ..._u32(1),
      ];
      final sig = UtxoCrypto.der(TronCrypto.sign(UtxoCrypto.dsha(copy), priv));
      scriptSigs.add([sig.length, ...sig, pub.length, ...pub]);
    }
    return Uint8List.fromList([
      ..._u32(version),
      ..._varint(p.inputs.length),
      for (var j = 0; j < p.inputs.length; j += 1) ...[..._txidLE(p.inputs[j].txid), ..._u32(p.inputs[j].vout), ..._varint(scriptSigs[j].length), ...scriptSigs[j], ...seq],
      ...outBytes, ..._u32(0),
    ]);
  }

  /// Transaction id (double SHA-256 of the transaction WITHOUT witness data, reversed).
  static String txid(Uint8List raw, UtxoChain c) {
    if (!c.segwit) return TronCrypto.hex(UtxoCrypto.dsha(raw).reversed.toList());
    // strip marker/flag and witnesses: rebuild from the parts we know
    var i = 4 + 2;
    int readVar() {
      final b = raw[i++];
      if (b < 0xfd) return b;
      if (b == 0xfd) {
        final v = raw[i] | (raw[i + 1] << 8);
        i += 2;
        return v;
      }
      final v = raw[i] | (raw[i + 1] << 8) | (raw[i + 2] << 16) | (raw[i + 3] << 24);
      i += 4;
      return v;
    }

    final startIns = i;
    final nIn = readVar();
    for (var k = 0; k < nIn; k += 1) {
      i += 36;
      final l = readVar();
      i += l + 4;
    }
    final nOut = readVar();
    for (var k = 0; k < nOut; k += 1) {
      i += 8;
      final l = readVar();
      i += l;
    }
    final body = [...raw.sublist(0, 4), ...raw.sublist(startIns, i), ...raw.sublist(raw.length - 4)];
    return TronCrypto.hex(UtxoCrypto.dsha(body).reversed.toList());
  }
}

// ======================================================================== network
class UtxoApi {
  UtxoApi(this.chain);
  final UtxoChain chain;

  Future<http.Response> _get(String path) async {
    Object? last;
    for (final base in chain.apis) {
      try {
        final r = await http.get(Uri.parse('$base$path')).timeout(const Duration(seconds: 15));
        if (r.statusCode == 200) return r;
        last = WalletException(r.statusCode == 429 ? '${chain.name} is busy. Try again in a moment.' : 'Network error (${r.statusCode})');
      } catch (e) {
        last = e;
      }
    }
    throw last is WalletException ? last : WalletException('Can’t reach ${chain.name}. Try again.');
  }

  dynamic _json(http.Response r) => jsonDecode(r.body);

  Future<BigInt> balance(String address) async {
    if (chain.blockcypher) {
      final j = _json(await _get('/addrs/$address/balance')) as Map;
      return BigInt.from((j['final_balance'] as num?) ?? 0);
    }
    final j = _json(await _get('/address/$address')) as Map;
    int n(Map? m, String k) => ((m?[k] as num?) ?? 0).toInt();
    final c = j['chain_stats'] as Map?;
    final m = j['mempool_stats'] as Map?;
    return BigInt.from(n(c, 'funded_txo_sum') - n(c, 'spent_txo_sum') + n(m, 'funded_txo_sum') - n(m, 'spent_txo_sum'));
  }

  Future<List<Utxo>> utxos(String address) async {
    if (chain.blockcypher) {
      final j = _json(await _get('/addrs/$address?unspentOnly=true&limit=200')) as Map;
      return [
        for (final t in [...(j['txrefs'] as List? ?? const []), ...(j['unconfirmed_txrefs'] as List? ?? const [])])
          if ((t as Map)['tx_output_n'] is num && (t['tx_output_n'] as num) >= 0) Utxo('${t['tx_hash']}', (t['tx_output_n'] as num).toInt(), (t['value'] as num).toInt()),
      ];
    }
    final l = _json(await _get('/address/$address/utxo')) as List;
    return [for (final u in l) Utxo('${(u as Map)['txid']}', (u['vout'] as num).toInt(), (u['value'] as num).toInt())];
  }

  /// Smallest units per virtual byte, for confirmation in ~30 minutes.
  Future<double> feeRate() async {
    if (chain.blockcypher) {
      final j = _json(await _get('')) as Map;
      final perKb = ((j['medium_fee_per_kb'] as num?) ?? chain.minFeePerKb).toDouble();
      return (perKb < chain.minFeePerKb ? chain.minFeePerKb : perKb) / 1000;
    }
    try {
      final j = _json(await _get('/v1/fees/recommended')) as Map;
      final r = ((j['halfHourFee'] as num?) ?? 2).toDouble();
      return r < 1 ? 1 : r;
    } catch (_) {
      return 3;
    }
  }

  Future<UtxoPrepared> prepare({required String from, required String to, required BigInt amount, required bool sweep}) async {
    final toScript = UtxoCrypto.scriptFor(to, chain);
    if (toScript == null) throw WalletException('This is not a ${chain.name} address');
    final all = (await utxos(from))..sort((a, b) => b.value.compareTo(a.value));
    if (all.isEmpty) throw WalletException('No ${chain.symbol} to send yet (or it’s still arriving)');
    final rate = await feeRate();
    final myLen = UtxoCrypto.scriptFor(from, chain)!.length;
    int feeFor(int n, bool withChange) {
      final v = UtxoTx.vsize(chain, n, [toScript.length, if (withChange) myLen]);
      final f = (v * rate).ceil();
      final min = (v * chain.minFeePerKb / 1000).ceil();
      return f < min ? min : f;
    }

    UtxoPrepared done(List<Utxo> ins, int amt, int fee, int change) {
      if (fee > chain.maxFee) throw WalletException('The network fee looks too high right now. Try again later.');
      if (amt < chain.dust) throw WalletException('The amount is too small to send on ${chain.name}');
      return UtxoPrepared(chain: chain, to: to, from: from, amount: BigInt.from(amt), fee: BigInt.from(fee), inputs: ins, change: BigInt.from(change));
    }

    final total = all.fold(0, (s, u) => s + u.value);
    if (sweep) {
      final ins = all.take(200).toList();
      final sum = ins.fold(0, (s, u) => s + u.value);
      final fee = feeFor(ins.length, false);
      return done(ins, sum - fee, fee, 0);
    }
    final want = amount.toInt();
    final ins = <Utxo>[];
    var sum = 0;
    for (final u in all.take(200)) {
      ins.add(u);
      sum += u.value;
      final fee = feeFor(ins.length, true);
      if (sum >= want + fee) {
        final change = sum - want - fee;
        if (change < chain.dust) {
          // too little change to keep: it goes to the fee
          return done(ins, want, sum - want, 0);
        }
        return done(ins, want, fee, change);
      }
    }
    final fee = feeFor(all.length.clamp(1, 200), false);
    throw WalletException(total - fee > 0
        ? 'Not enough ${chain.symbol}: you can send at most ${Units.format(BigInt.from(total - fee), decimals: 8)} after the network fee'
        : 'Not enough ${chain.symbol} for the network fee');
  }

  Future<String> send(UtxoPrepared p, Uint8List priv) async {
    if (UtxoCrypto.addressOf(priv, chain) != p.from) throw WalletException('Wrong key for this wallet');
    final raw = UtxoTx.sign(p, priv);
    final id = UtxoTx.txid(raw, chain);
    final hex = TronCrypto.hex(raw);
    Object? last;
    for (final base in chain.apis) {
      try {
        final http.Response r = chain.blockcypher
            ? await http.post(Uri.parse('$base/txs/push'), headers: {'content-type': 'application/json'}, body: jsonEncode({'tx': hex})).timeout(const Duration(seconds: 20))
            : await http.post(Uri.parse('$base/tx'), body: hex).timeout(const Duration(seconds: 20));
        if (r.statusCode == 200 || r.statusCode == 201) return id;
        last = WalletException(_why(r.body));
        if (r.statusCode == 400) break; // the network refused this transaction: another server will too
      } catch (e) {
        last = e;
      }
    }
    throw last is WalletException ? last : WalletException('Sending failed. Nothing was taken.');
  }

  static String _why(String body) {
    final l = body.toLowerCase();
    if (l.contains('insufficient') || l.contains('min relay fee')) return 'The network fee was too low. Try again.';
    if (l.contains('missing') || l.contains('spent')) return 'Some coins were just spent. Pull to refresh and try again.';
    return body.length > 140 ? '${body.substring(0, 140)}…' : (body.isEmpty ? 'Sending failed' : body);
  }

  /// Recent transfers of [address] (in = received, out = sent), newest first.
  Future<List<WalletTx>> history(String address) async {
    final out = <WalletTx>[];
    if (chain.blockcypher) {
      final j = _json(await _get('/addrs/$address/full?limit=20')) as Map;
      for (final t in (j['txs'] as List? ?? const [])) {
        final m = t as Map;
        var inSum = 0, outSum = 0;
        String? other;
        for (final i in (m['inputs'] as List? ?? const [])) {
          final adr = ((i as Map)['addresses'] as List?)?.firstOrNull;
          if (adr == address) {
            inSum += ((i['output_value'] as num?) ?? 0).toInt();
          } else {
            other ??= adr as String?;
          }
        }
        String? dest;
        for (final o in (m['outputs'] as List? ?? const [])) {
          final adr = ((o as Map)['addresses'] as List?)?.firstOrNull;
          if (adr == address) {
            outSum += ((o['value'] as num?) ?? 0).toInt();
          } else {
            dest ??= adr as String?;
          }
        }
        final net = outSum - inSum;
        final time = DateTime.tryParse('${m['confirmed'] ?? m['received'] ?? ''}') ?? DateTime.now();
        out.add(_tx('${m['hash']}', address, net, other, dest, time));
      }
      return out;
    }
    final l = _json(await _get('/address/$address/txs')) as List;
    for (final t in l.take(25)) {
      final m = t as Map;
      var inSum = 0, outSum = 0;
      String? other, dest;
      for (final i in (m['vin'] as List? ?? const [])) {
        final p = (i as Map)['prevout'] as Map?;
        if (p?['scriptpubkey_address'] == address) {
          inSum += ((p?['value'] as num?) ?? 0).toInt();
        } else {
          other ??= p?['scriptpubkey_address'] as String?;
        }
      }
      for (final o in (m['vout'] as List? ?? const [])) {
        final adr = (o as Map)['scriptpubkey_address'];
        if (adr == address) {
          outSum += ((o['value'] as num?) ?? 0).toInt();
        } else {
          dest ??= adr as String?;
        }
      }
      final st = m['status'] as Map?;
      final time = st?['block_time'] is num ? DateTime.fromMillisecondsSinceEpoch((st!['block_time'] as num).toInt() * 1000) : DateTime.now();
      out.add(_tx('${m['txid']}', address, outSum - inSum, other, dest, time));
    }
    return out;
  }

  WalletTx _tx(String id, String me, int net, String? from, String? to, DateTime time) => WalletTx(
        id: id, token: chain.symbol, network: chain.id, decimals: 8, ok: true, time: time,
        amount: BigInt.from(net.abs()),
        from: net >= 0 ? (from ?? '?') : me,
        to: net >= 0 ? me : (to ?? '?'),
      );

  /// For chat cards: did [txid] pay exactly [amount] to [to]? (true/false), or null while unknown / unconfirmed.
  Future<(bool, bool)?> checkPayment(String txid, String to, BigInt amount) async {
    try {
      if (chain.blockcypher) {
        final m = _json(await _get('/txs/$txid')) as Map;
        final paid = (m['outputs'] as List? ?? const []).any((o) => ((o as Map)['addresses'] as List?)?.contains(to) == true && BigInt.from((o['value'] as num?) ?? -1) == amount);
        return (paid, ((m['confirmations'] as num?) ?? 0) > 0);
      }
      final m = _json(await _get('/tx/$txid')) as Map;
      final paid = (m['vout'] as List? ?? const []).any((o) => (o as Map)['scriptpubkey_address'] == to && BigInt.from((o['value'] as num?) ?? -1) == amount);
      return (paid, (m['status'] as Map?)?['confirmed'] == true);
    } on WalletException catch (e) {
      if (e.message.contains('(404)') || e.message.contains('(400)')) return (false, false);
      return null;
    }
  }
}
