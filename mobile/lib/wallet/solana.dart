import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'tron_api.dart' show WalletException, WalletTx;
import 'tron_crypto.dart';

/// Solana: ed25519 keys (SLIP-0010, m/44'/501'/0' like Trust Wallet), addresses are the Base58 public key.
class Sol {
  Sol._();

  static const decimals = 9; // lamports
  static const explorer = 'https://solscan.io';
  static const rpcs = ['https://solana-rpc.publicnode.com', 'https://api.mainnet-beta.solana.com'];
  static const _system = '11111111111111111111111111111111';
  static const rentMin = 890880; // lamports an empty account must hold

  /// 32-byte ed25519 seed (the private key).
  static Uint8List privateKey(String phrase) {
    final seed = TronCrypto.seedOf(phrase);
    var i = Uint8List.fromList(c.Hmac(c.sha512, utf8.encode('ed25519 seed')).convert(seed).bytes);
    var k = i.sublist(0, 32), chain = i.sublist(32);
    for (final idx in const [44, 501, 0]) {
      final data = [0, ...k, ...[(idx | 0x80000000) >> 24 & 0xff, idx >> 16 & 0xff, idx >> 8 & 0xff, idx & 0xff]];
      i = Uint8List.fromList(c.Hmac(c.sha512, chain).convert(data).bytes);
      k = i.sublist(0, 32);
      chain = i.sublist(32);
    }
    return k;
  }

  static final _ed = Ed25519();

  static Future<SimpleKeyPair> _pair(Uint8List priv) => _ed.newKeyPairFromSeed(priv);

  static Future<String> addressOf(Uint8List priv) async {
    final pub = await (await _pair(priv)).extractPublicKey();
    return TronCrypto.base58encode(Uint8List.fromList(pub.bytes));
  }

  /// A Solana address: Base58 of exactly 32 bytes.
  static bool isValidAddress(String a) {
    final s = a.trim();
    if (!RegExp(r'^[1-9A-HJ-NP-Za-km-z]{32,44}$').hasMatch(s)) return false;
    final b = TronCrypto.base58decode(s);
    return b != null && b.length == 32;
  }

  static List<int> _compact(int n) {
    final out = <int>[];
    var v = n;
    while (true) {
      final b = v & 0x7f;
      v >>= 7;
      if (v == 0) {
        out.add(b);
        return out;
      }
      out.add(b | 0x80);
    }
  }

  static List<int> _u64(int v) => (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();

  /// The message of a plain SOL transfer (System Program, instruction 2).
  static Uint8List transferMessage(String from, String to, int lamports, String blockhash) {
    final keys = [TronCrypto.base58decode(from)!, TronCrypto.base58decode(to)!, TronCrypto.base58decode(_system)!];
    final data = [2, 0, 0, 0, ..._u64(lamports)];
    return Uint8List.fromList([
      1, 0, 1, // 1 signer, 0 read-only signers, 1 read-only account (the System Program)
      ..._compact(3), for (final k in keys) ...k,
      ...TronCrypto.base58decode(blockhash)!,
      ..._compact(1), 2, ..._compact(2), 0, 1, ..._compact(data.length), ...data,
    ]);
  }

  static Future<Uint8List> signTransaction(Uint8List message, Uint8List priv) async {
    final sig = await _ed.sign(message, keyPair: await _pair(priv));
    return Uint8List.fromList([..._compact(1), ...sig.bytes, ...message]);
  }

  static Future<bool> verify(Uint8List message, List<int> sig, String address) =>
      _ed.verify(message, signature: Signature(sig, publicKey: SimplePublicKey(TronCrypto.base58decode(address)!, type: KeyPairType.ed25519)));
}

class SolPrepared {
  SolPrepared({required this.from, required this.to, required this.lamports, required this.fee, required this.blockhash});
  final String from;
  final String to;
  final int lamports;
  final int fee;
  final String blockhash;
}

class SolApi {
  int _id = 0;

  Future<dynamic> _rpc(String method, List<Object?> params) async {
    Object? last;
    for (final url in Sol.rpcs) {
      try {
        final r = await http
            .post(Uri.parse(url), headers: {'content-type': 'application/json'}, body: jsonEncode({'jsonrpc': '2.0', 'id': ++_id, 'method': method, 'params': params}))
            .timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) {
          last = WalletException(r.statusCode == 429 ? 'Solana is busy. Try again in a moment.' : 'Network error (${r.statusCode})');
          continue;
        }
        final j = jsonDecode(r.body) as Map;
        if (j['error'] != null) {
          final msg = '${(j['error'] as Map)['message']}';
          if (RegExp('rate|limit|too many', caseSensitive: false).hasMatch(msg)) {
            last = WalletException('Solana is busy. Try again in a moment.');
            continue;
          }
          throw WalletException(_friendly(msg));
        }
        return j['result'];
      } on WalletException {
        rethrow;
      } catch (e) {
        last = e;
      }
    }
    throw last is WalletException ? last : WalletException('Can’t reach Solana. Try again.');
  }

  static String _friendly(String m) {
    final l = m.toLowerCase();
    if (l.contains('insufficient') || l.contains('0x1')) return 'Not enough SOL for this and the network fee';
    if (l.contains('rent')) return 'The receiver’s account needs at least 0.00089 SOL — send a bit more';
    return m.length > 140 ? '${m.substring(0, 140)}…' : m;
  }

  Future<BigInt> balance(String address) async {
    final r = await _rpc('getBalance', [address, {'commitment': 'confirmed'}]) as Map;
    return BigInt.from((r['value'] as num?) ?? 0);
  }

  Future<SolPrepared> prepare({required String from, required String to, required BigInt amount, required BigInt have}) async {
    if (!Sol.isValidAddress(to)) throw WalletException('This is not a Solana address');
    final bh = await _rpc('getLatestBlockhash', [{'commitment': 'finalized'}]) as Map;
    final blockhash = '${(bh['value'] as Map)['blockhash']}';
    var fee = 5000;
    try {
      final msg = Sol.transferMessage(from, to, amount.toInt(), blockhash);
      final f = await _rpc('getFeeForMessage', [base64Encode(msg), {'commitment': 'processed'}]) as Map;
      fee = ((f['value'] as num?) ?? 5000).toInt();
    } catch (_) {}
    if (fee > 1000000) throw WalletException('The network fee looks too high right now. Try again later.');
    var lamports = amount.toInt();
    // "send all": the fee comes out of the amount
    if (amount >= have) lamports = have.toInt() - fee;
    if (lamports <= 0) throw WalletException('Not enough SOL for the network fee');
    // a new (empty) receiver must get at least the rent minimum, or the network refuses
    final dest = await balance(to);
    if (dest == BigInt.zero && lamports < Sol.rentMin) {
      throw WalletException('This address is new: send at least 0.00089 SOL to it (a Solana rule)');
    }
    // leaving a little dust behind (below the rent minimum) is refused too
    final left = have.toInt() - lamports - fee;
    if (left > 0 && left < Sol.rentMin) throw WalletException('Leave at least 0.00089 SOL, or send everything (Max)');
    return SolPrepared(from: from, to: to, lamports: lamports, fee: fee, blockhash: blockhash);
  }

  Future<String> send(SolPrepared p, Uint8List priv) async {
    if (await Sol.addressOf(priv) != p.from) throw WalletException('Wrong key for this wallet');
    final msg = Sol.transferMessage(p.from, p.to, p.lamports, p.blockhash);
    final tx = await Sol.signTransaction(msg, priv);
    final sig = await _rpc('sendTransaction', [base64Encode(tx), {'encoding': 'base64', 'preflightCommitment': 'confirmed'}]);
    return '$sig';
  }

  Future<List<WalletTx>> history(String address) async {
    final sigs = (await _rpc('getSignaturesForAddress', [address, {'limit': 10}]) as List?) ?? const [];
    final out = <WalletTx>[];
    for (final s in sigs) {
      final m = s as Map;
      try {
        final t = await _rpc('getTransaction', ['${m['signature']}', {'encoding': 'jsonParsed', 'maxSupportedTransactionVersion': 0}]) as Map?;
        if (t == null) continue;
        for (final ins in (((t['transaction'] as Map)['message'] as Map)['instructions'] as List? ?? const [])) {
          final p = (ins as Map)['parsed'];
          if (p is! Map || p['type'] != 'transfer' || ins['program'] != 'system') continue;
          final info = p['info'] as Map;
          if (info['source'] != address && info['destination'] != address) continue;
          out.add(WalletTx(
            id: '${m['signature']}', token: 'SOL', network: 'sol', decimals: Sol.decimals,
            from: '${info['source']}', to: '${info['destination']}', amount: BigInt.from((info['lamports'] as num?) ?? 0),
            time: DateTime.fromMillisecondsSinceEpoch(((m['blockTime'] as num?) ?? 0).toInt() * 1000),
            ok: (t['meta'] as Map?)?['err'] == null,
          ));
        }
      } catch (_) {}
    }
    return out;
  }

  /// For chat cards: (paid exactly, confirmed) or null while unknown.
  Future<(bool, bool)?> checkPayment(String sig, String to, BigInt amount) async {
    final t = await _rpc('getTransaction', [sig, {'encoding': 'jsonParsed', 'maxSupportedTransactionVersion': 0, 'commitment': 'confirmed'}]) as Map?;
    if (t == null) return null;
    if ((t['meta'] as Map?)?['err'] != null) return (false, true);
    final paid = (((t['transaction'] as Map)['message'] as Map)['instructions'] as List? ?? const []).any((ins) {
      final p = (ins as Map)['parsed'];
      return ins['program'] == 'system' && p is Map && p['type'] == 'transfer' && (p['info'] as Map)['destination'] == to &&
          BigInt.from(((p['info'] as Map)['lamports'] as num?) ?? -1) == amount;
    });
    return (paid, true);
  }
}
