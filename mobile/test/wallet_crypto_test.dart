import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/wallet/tron_api.dart';
import 'package:chatapp/wallet/tron_crypto.dart';

// Expected values were computed with an independent implementation (Python: PBKDF2, BIP-32, secp256k1,
// Keccak-256, Base58Check written from the specs) — not with this code.
const phrase = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

void main() {
  test('phrase → key → address (BIP-39 / BIP-44 m/44\'/195\'/0\'/0/i)', () {
    expect(TronCrypto.isValidPhrase(phrase), true);
    expect(TronCrypto.isValidPhrase('$phrase abandon'), false);
    expect(TronCrypto.isValidPhrase(phrase.replaceFirst('about', 'abandon')), false, reason: 'checksum');
    final k = TronCrypto.privateKey(phrase);
    expect(TronCrypto.hex(k), 'b5a4cea271ff424d7c31dc12a3e43e401df7a40d7412a15750f3f0b6b5449a28');
    expect(TronCrypto.addressOf(k), 'TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH');
    expect(TronCrypto.addressOf(TronCrypto.privateKey(phrase, index: 1)), 'TSeJkUh4Qv67VNFwY8LaAxERygNdy6NQZK');
    expect(TronCrypto.privateKey('  ABANDON ${phrase.substring(8)}  ').length, 32, reason: 'spaces & case');
  });

  test('new phrases are valid, 12 words, different every time', () {
    final a = TronCrypto.newPhrase();
    final b = TronCrypto.newPhrase();
    expect(a.split(' ').length, 12);
    expect(TronCrypto.isValidPhrase(a), true);
    expect(a == b, false);
    expect(TronCrypto.isWord('abandon') && TronCrypto.isWord('zoo') && !TronCrypto.isWord('hushavia'), true);
    expect(TronCrypto.suggest('aba'), contains('abandon'));
  });

  test('keccak, base58 addresses', () {
    expect(TronCrypto.hex(TronCrypto.keccak256(const [])), 'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470');
    expect(TronCrypto.isValidAddress('TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t'), true);
    expect(TronCrypto.isValidAddress('TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6u'), false, reason: 'checksum');
    expect(TronCrypto.isValidAddress('0x742d35Cc6634C0532925a3b844Bc454e4438f44e'), false);
    final b = TronCrypto.decodeAddress('TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH')!;
    expect(TronCrypto.addressFromHex(TronCrypto.hex(b)), 'TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH');
  });

  test('signatures verify, low-s, deterministic', () {
    final k = TronCrypto.privateKey(phrase);
    final h = TronCrypto.sha256('hushavia'.codeUnits);
    final s1 = TronCrypto.sign(h, k);
    final s2 = TronCrypto.sign(h, k);
    expect(s1.length, 65);
    expect(TronCrypto.hex(s1), TronCrypto.hex(s2));
    expect(s1[64] == 27 || s1[64] == 28, true);
    expect(TronCrypto.verify(h, s1, TronCrypto.publicKey(k)), true);
    final other = TronCrypto.privateKey(phrase, index: 1);
    expect(TronCrypto.verify(h, s1, TronCrypto.publicKey(other)), false);
    final bad = Uint8List.fromList(s1)..[10] ^= 1;
    expect(TronCrypto.verify(h, bad, TronCrypto.publicKey(k)), false);
    final sVal = BigInt.parse(TronCrypto.hex(s1.sublist(32, 64)), radix: 16);
    final n = BigInt.parse('FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141', radix: 16);
    expect(sVal <= n >> 1, true);
  });

  test('amounts', () {
    expect(Units.parse('12.5'), BigInt.from(12500000));
    expect(Units.parse('0.000001'), BigInt.one);
    expect(Units.parse('0.0000001'), null);
    expect(Units.parse('abc'), null);
    expect(Units.parse('.'), null);
    expect(Units.format(BigInt.from(1234567890)), '1,234.56789');
  });

  test('a transfer that does not match what was asked is refused', () {
    // hand-built TriggerSmartContract tx: USDT transfer of 5 USDT to TSeJ… from TUEZ…
    final me = 'TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH';
    final to = 'TSeJkUh4Qv67VNFwY8LaAxERygNdy6NQZK';
    const usdt = 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t';
    List<int> ld(int field, List<int> b) => [..._v(field << 3 | 2), ..._v(b.length), ...b];
    List<int> vi(int field, int v) => [..._v(field << 3), ..._v(v)];
    List<int> transferData(String dest, BigInt amt) => [
          0xa9, 0x05, 0x9c, 0xbb, ...List.filled(12, 0), ...TronCrypto.decodeAddress(dest)!.sublist(1),
          ...TronCrypto.fromHex(amt.toRadixString(16).padLeft(64, '0')),
        ];
    Map<String, dynamic> tx(String dest, BigInt amt, {int fee = 50000000}) {
      final trigger = [...ld(1, TronCrypto.decodeAddress(me)!), ...ld(2, TronCrypto.decodeAddress(usdt)!), ...ld(4, transferData(dest, amt))];
      final any = [...ld(1, 'type.googleapis.com/protocol.TriggerSmartContract'.codeUnits), ...ld(2, trigger)];
      final contract = [...vi(1, 31), ...ld(2, any)];
      final exp = DateTime.now().millisecondsSinceEpoch + 60000;
      final raw = [...ld(1, [1, 2]), ...ld(4, List.filled(8, 7)), ...vi(8, exp), ...ld(11, contract), ...vi(14, exp - 60000), ...vi(18, fee)];
      return {'raw_data_hex': TronCrypto.hex(raw), 'txID': TronCrypto.hex(TronCrypto.sha256(raw)), 'raw_data': {'expiration': exp}};
    }

    final five = BigInt.from(5000000);
    expect(TxCheck.usdt(tx(to, five), from: me, to: to, amount: five, usdt: usdt, maxFee: 50000000).length, 32);
    expect(() => TxCheck.usdt(tx(me, five), from: me, to: to, amount: five, usdt: usdt, maxFee: 50000000), throwsA(isA<WalletException>()), reason: 'other address');
    expect(() => TxCheck.usdt(tx(to, five * BigInt.two), from: me, to: to, amount: five, usdt: usdt, maxFee: 50000000), throwsA(isA<WalletException>()), reason: 'other amount');
    expect(() => TxCheck.usdt(tx(to, five, fee: 900000000), from: me, to: to, amount: five, usdt: usdt, maxFee: 50000000), throwsA(isA<WalletException>()), reason: 'huge fee');
    final forged = tx(to, five)..['txID'] = '00' * 32;
    expect(() => TxCheck.usdt(forged, from: me, to: to, amount: five, usdt: usdt, maxFee: 50000000), throwsA(isA<WalletException>()), reason: 'id must be the hash');
  });
}

List<int> _v(int v) {
  final out = <int>[];
  var x = v;
  while (x >= 0x80) {
    out.add((x & 0x7f) | 0x80);
    x >>= 7;
  }
  out.add(x);
  return out;
}
