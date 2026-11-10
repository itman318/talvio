import 'dart:convert';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart';

/// Everything that touches the secret key lives here, on the phone, and never leaves it:
/// the 12-word recovery phrase (BIP-39), the TRON key derived from it (BIP-44 m/44'/195'/0'/0/0),
/// addresses (Base58Check, 0x41) and signatures (secp256k1, RFC 6979, low-s, v = 27 + recovery id).
class TronCrypto {
  TronCrypto._();

  static final _params = ECDomainParameters('secp256k1');
  static BigInt get _n => _params.n;

  // ------------------------------------------------------------------ recovery phrase
  static String newPhrase() => bip39.generateMnemonic(strength: 128); // 12 words

  static String normalize(String phrase) => phrase.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

  static bool isValidPhrase(String phrase) {
    final p = normalize(phrase);
    final n = p.split(' ').length;
    return (n == 12 || n == 24) && bip39.validateMnemonic(p);
  }

  /// The word list, for suggestions while typing a phrase.
  static bool isWord(String w) => _words.contains(w);
  static final Set<String> _words = _loadWords();
  static Set<String> _loadWords() {
    // bip39 keeps the English list private; rebuild it from its entropy↔words mapping (2048 words)
    final out = <String>{};
    for (var i = 0; i < 2048; i += 1) {
      // 11 bits per word: put word i at the start of an otherwise-zero 128-bit entropy
      final bits = i.toRadixString(2).padLeft(11, '0') + '0' * 117;
      final bytes = <int>[for (var j = 0; j < 128; j += 8) int.parse(bits.substring(j, j + 8), radix: 2)];
      out.add(bip39.entropyToMnemonic(_hex(bytes)).split(' ').first);
    }
    return out;
  }

  static List<String> suggest(String prefix) {
    if (prefix.isEmpty) return const [];
    return _words.where((w) => w.startsWith(prefix)).take(4).toList();
  }

  // ------------------------------------------------------------------ keys
  /// The private key (32 bytes) for account [index] of a phrase.
  static Uint8List privateKey(String phrase, {int index = 0}) {
    final seed = bip39.mnemonicToSeed(normalize(phrase));
    return derive(seed, [0x80000000 + 44, 0x80000000 + 195, 0x80000000, 0, index]);
  }

  /// BIP-32 private-key derivation.
  static Uint8List derive(Uint8List seed, List<int> path) {
    var i = _hmac512(utf8.encode('Bitcoin seed'), seed);
    var k = _toBig(i.sublist(0, 32));
    var chain = i.sublist(32);
    for (final idx in path) {
      final data = BytesBuilder();
      if (idx >= 0x80000000) {
        data.addByte(0);
        data.add(_fromBig(k));
      } else {
        data.add((_params.G * k)!.getEncoded(true));
      }
      data.add([(idx >> 24) & 0xff, (idx >> 16) & 0xff, (idx >> 8) & 0xff, idx & 0xff]);
      i = _hmac512(chain, data.toBytes());
      final il = _toBig(i.sublist(0, 32));
      if (il >= _n) throw StateError('invalid child key');
      k = (il + k) % _n;
      if (k == BigInt.zero) throw StateError('invalid child key');
      chain = i.sublist(32);
    }
    return _fromBig(k);
  }

  static Uint8List publicKey(Uint8List priv) => (_params.G * _toBig(priv))!.getEncoded(false); // 65 bytes, 04‖x‖y

  // ------------------------------------------------------------------ addresses
  static String addressOf(Uint8List priv) => addressFromPublic(publicKey(priv));

  static String addressFromPublic(Uint8List pub65) {
    final h = keccak256(pub65.sublist(1));
    return base58check(Uint8List.fromList([0x41, ...h.sublist(12)]));
  }

  static bool isValidAddress(String a) {
    final b = decodeAddress(a);
    return b != null;
  }

  /// 21 bytes (0x41 + 20) or null when it is not a TRON address.
  static Uint8List? decodeAddress(String a) {
    final s = a.trim();
    if (!RegExp(r'^T[1-9A-HJ-NP-Za-km-z]{33}$').hasMatch(s)) return null;
    final raw = base58decode(s);
    if (raw == null || raw.length != 25 || raw[0] != 0x41) return null;
    final body = raw.sublist(0, 21);
    final sum = _sha256(_sha256(body)).sublist(0, 4);
    for (var i = 0; i < 4; i += 1) {
      if (sum[i] != raw[21 + i]) return null;
    }
    return body;
  }

  static String addressFromHex(String hex) {
    var h = hex.toLowerCase();
    if (h.startsWith('0x')) h = '41${h.substring(2)}';
    if (h.length == 40) h = '41$h';
    return base58check(fromHex(h));
  }

  // ------------------------------------------------------------------ signatures
  /// 65-byte TRON signature of a 32-byte hash (the transaction id).
  static Uint8List sign(Uint8List hash32, Uint8List priv) {
    final signer = ECDSASigner(null, HMac(SHA256Digest(), 64)) // deterministic k (RFC 6979)
      ..init(true, PrivateKeyParameter(ECPrivateKey(_toBig(priv), _params)));
    var sig = signer.generateSignature(hash32) as ECSignature;
    if (sig.s > _n >> 1) sig = ECSignature(sig.r, _n - sig.s); // low-s
    final pub = publicKey(priv);
    for (var rec = 0; rec < 2; rec += 1) {
      final q = recover(hash32, sig.r, sig.s, rec);
      if (q != null && _eq(q, pub)) {
        return Uint8List.fromList([..._fromBig(sig.r), ..._fromBig(sig.s), 27 + rec]);
      }
    }
    throw StateError('could not sign');
  }

  /// Public key (65 bytes) that made a signature, or null.
  static Uint8List? recover(Uint8List hash32, BigInt r, BigInt s, int recId) {
    final curve = _params.curve;
    final x = _fromBig(r);
    final ECPoint? big;
    try {
      big = curve.decodePoint([recId & 1 == 1 ? 3 : 2, ...x]);
    } catch (_) {
      return null;
    }
    if (big == null || !(big * _n)!.isInfinity) return null;
    final e = _toBig(hash32) % _n;
    final rInv = r.modInverse(_n);
    final q = ((big * s)! + (_params.G * ((_n - e) % _n))!)! * rInv;
    return q?.getEncoded(false);
  }

  /// True when [sig65] is a valid signature of [hash32] by the owner of [pub65].
  static bool verify(Uint8List hash32, Uint8List sig65, Uint8List pub65) {
    if (sig65.length != 65) return false;
    final r = _toBig(sig65.sublist(0, 32));
    final s = _toBig(sig65.sublist(32, 64));
    final q = recover(hash32, r, s, sig65[64] >= 27 ? sig65[64] - 27 : sig65[64]);
    if (q == null || !_eq(q, pub65)) return false;
    final v = ECDSASigner(null)..init(false, PublicKeyParameter(ECPublicKey(_params.curve.decodePoint(pub65), _params)));
    return v.verifySignature(hash32, ECSignature(r, s));
  }

  // ------------------------------------------------------------------ hashes & encodings
  static Uint8List keccak256(List<int> data) {
    final d = KeccakDigest(256);
    return d.process(Uint8List.fromList(data));
  }

  static Uint8List sha256(List<int> data) => _sha256(data);
  static Uint8List _sha256(List<int> data) => Uint8List.fromList(c.sha256.convert(data).bytes);

  static Uint8List _hmac512(List<int> key, List<int> data) => Uint8List.fromList(c.Hmac(c.sha512, key).convert(data).bytes);

  static const _alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  static String base58check(Uint8List body) {
    final full = Uint8List.fromList([...body, ..._sha256(_sha256(body)).sublist(0, 4)]);
    var n = _toBig(full);
    final sb = StringBuffer();
    final b58 = BigInt.from(58);
    while (n > BigInt.zero) {
      sb.write(_alphabet[(n % b58).toInt()]);
      n = n ~/ b58;
    }
    for (final byte in full) {
      if (byte != 0) break;
      sb.write('1');
    }
    return sb.toString().split('').reversed.join();
  }

  static Uint8List? base58decode(String s) {
    var n = BigInt.zero;
    final b58 = BigInt.from(58);
    for (final ch in s.split('')) {
      final v = _alphabet.indexOf(ch);
      if (v < 0) return null;
      n = n * b58 + BigInt.from(v);
    }
    final body = n == BigInt.zero ? <int>[] : _fromBig(n, len: 0);
    final zeros = s.split('').takeWhile((ch) => ch == '1').length;
    return Uint8List.fromList([...List.filled(zeros, 0), ...body]);
  }

  static String hex(List<int> b) => _hex(b);
  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List fromHex(String h) {
    final s = h.length.isOdd ? '0$h' : h;
    return Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
  }

  static BigInt _toBig(List<int> b) => b.fold(BigInt.zero, (a, x) => (a << 8) | BigInt.from(x));

  /// Big-endian bytes; [len] 0 = as short as possible.
  static Uint8List _fromBig(BigInt v, {int len = 32}) {
    final out = <int>[];
    var x = v;
    while (x > BigInt.zero) {
      out.add((x & BigInt.from(0xff)).toInt());
      x = x >> 8;
    }
    while (out.length < len) {
      out.add(0);
    }
    return Uint8List.fromList(out.reversed.toList());
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i += 1) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }
}

// ------------------------------------------------------------------ amounts
/// Token amounts are whole numbers of the smallest unit (6 decimals for both TRX and USDT).
class Units {
  Units._();

  /// "12.5" → 12500000 (6 decimals). Null when it is not a valid positive amount.
  static BigInt? parse(String text, {int decimals = 6}) {
    final t = text.trim().replaceAll(',', '');
    final m = RegExp(r'^(\d*)(?:\.(\d*))?$').firstMatch(t);
    if (m == null || t.isEmpty || t == '.') return null;
    final whole = m.group(1)!.isEmpty ? '0' : m.group(1)!;
    final frac = m.group(2) ?? '';
    if (frac.length > decimals) return null;
    return BigInt.parse(whole) * BigInt.from(10).pow(decimals) + BigInt.parse(frac.padRight(decimals, '0').isEmpty ? '0' : frac.padRight(decimals, '0'));
  }

  static String format(BigInt units, {int decimals = 6, int maxFraction = 6}) {
    final neg = units.isNegative;
    final v = units.abs();
    final base = BigInt.from(10).pow(decimals);
    final whole = (v ~/ base).toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    var frac = (v % base).toString().padLeft(decimals, '0').substring(0, maxFraction.clamp(0, decimals));
    frac = frac.replaceAll(RegExp(r'0+$'), '');
    return '${neg ? '-' : ''}$whole${frac.isEmpty ? '' : '.$frac'}';
  }

  static double toDouble(BigInt units, {int decimals = 6}) => units.toDouble() / BigInt.from(10).pow(decimals).toDouble();
}
