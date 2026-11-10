import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/wallet/evm.dart';
import 'package:chatapp/wallet/tron_api.dart';
import 'package:chatapp/wallet/tron_crypto.dart';
import 'package:chatapp/wallet/utxo.dart';

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

  test('EVM: phrase → address (m/44\'/60\'/0\'/0/i, EIP-55) — same as MetaMask / Trust Wallet', () {
    expect(EvmCrypto.addressOf(EvmCrypto.privateKey(phrase)), '0x9858EfFD232B4033E47d90003D41EC34EcaEda94');
    expect(EvmCrypto.addressOf(EvmCrypto.privateKey(phrase, index: 1)), '0x6Fac4D18c912343BF86fa7049364Dd4E424Ab9C0');
    expect(EvmCrypto.isValidAddress('0x9858EfFD232B4033E47d90003D41EC34EcaEda94'), true);
    expect(EvmCrypto.isValidAddress('0x9858effd232b4033e47d90003d41ec34ecaeda94'), true, reason: 'all lower case has no checksum');
    expect(EvmCrypto.isValidAddress('0x9858EfFD232B4033E47d90003D41EC34EcaEda95'), false, reason: 'typo caught by EIP-55');
    expect(EvmCrypto.isValidAddress('TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH'), false);
  });

  test('EVM: EIP-155 example transaction (from the EIP itself)', () {
    final key = TronCrypto.fromHex('46' * 32);
    expect(EvmCrypto.addressOf(key), '0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F');
    final unsigned = EvmCrypto.rlp([BigInt.from(9), BigInt.from(20000000000), BigInt.from(21000), TronCrypto.fromHex('35' * 20), BigInt.parse('1000000000000000000'), <int>[], 1, 0, 0]);
    expect(TronCrypto.hex(unsigned), 'ec098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a764000080018080');
    expect(TronCrypto.hex(TronCrypto.keccak256(unsigned)), 'daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53');
    final raw = EvmCrypto.signLegacy(
      chainId: 1, nonce: BigInt.from(9), gasPrice: BigInt.from(20000000000), gas: BigInt.from(21000),
      to: TronCrypto.fromHex('35' * 20), value: BigInt.parse('1000000000000000000'), data: const [], priv: key,
    );
    expect(TronCrypto.hex(raw),
        'f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83');
  });

  test('EVM: token transfer data', () {
    final d = EvmCrypto.transferData('0x9858EfFD232B4033E47d90003D41EC34EcaEda94', BigInt.from(1500000));
    expect(TronCrypto.hex(d), 'a9059cbb0000000000000000000000009858effd232b4033e47d90003d41ec34ecaeda94000000000000000000000000000000000000000000000000000000000016e360');
    expect(Units.format(BigInt.parse('1234500000000000000'), decimals: 18), '1.2345');
    expect(Units.parse('0.5', decimals: 18), BigInt.parse('500000000000000000'));
  });

  test('Bitcoin family: phrase → addresses (BIP-84 / BIP-44) — same as Trust Wallet', () {
    expect(UtxoCrypto.addressOf(UtxoCrypto.privateKey(phrase, UtxoChain.btc), UtxoChain.btc), 'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu');
    expect(UtxoCrypto.addressOf(UtxoCrypto.privateKey(phrase, UtxoChain.btc, index: 1), UtxoChain.btc), 'bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g');
    expect(UtxoCrypto.addressOf(UtxoCrypto.privateKey(phrase, UtxoChain.ltc), UtxoChain.ltc), 'ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh');
    expect(UtxoCrypto.addressOf(UtxoCrypto.privateKey(phrase, UtxoChain.doge), UtxoChain.doge), 'DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC');
  });

  test('Bitcoin family: every kind of address someone may give you', () {
    const btc = UtxoChain.btc;
    expect(TronCrypto.hex(UtxoCrypto.scriptFor('bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu', btc)!), startsWith('0014'));
    expect(TronCrypto.hex(UtxoCrypto.scriptFor('bc1p5d7rjq7g6rdk2yhzks9smlaqtedr4dekq08ge8ztwac72sfr9rusxg3297', btc)!), startsWith('5120'), reason: 'Taproot');
    expect(TronCrypto.hex(UtxoCrypto.scriptFor('1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2', btc)!), '76a914${'7680adec8eabcabac676be9e83854ade0bd22cdb'}88ac');
    expect(TronCrypto.hex(UtxoCrypto.scriptFor('3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy', btc)!), startsWith('a914'));
    expect(UtxoCrypto.isValidAddress('bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyv', btc), false, reason: 'checksum');
    expect(UtxoCrypto.isValidAddress('ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh', btc), false, reason: 'Litecoin address on Bitcoin');
    expect(UtxoCrypto.isValidAddress('DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC', btc), false);
    expect(UtxoCrypto.isValidAddress('DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC', UtxoChain.doge), true);
    expect(UtxoCrypto.isValidAddress('TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH', UtxoChain.doge), false);
  });

  test('Bitcoin family: BIP-143 signature hash (the example from the BIP itself)', () {
    final txin0 = [...TronCrypto.fromHex('fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f'), 0, 0, 0, 0];
    final txin1 = [...TronCrypto.fromHex('ef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a'), 1, 0, 0, 0];
    final outs = TronCrypto.fromHex('202cb206000000001976a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac9093510d000000001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac');
    final priv = TronCrypto.fromHex('619c335025c7f4012e556c2a58b2506e30b8511b53ade95ea316fd8c3286feb9');
    final pkh = UtxoCrypto.hash160(UtxoCrypto.compressedPub(priv));
    expect(TronCrypto.hex(pkh), '1d0f172a0ecb48aee1be1f2687d2963ae33f71a1');
    final h = UtxoTx.bip143(
      version: 1, hashPrevouts: UtxoCrypto.dsha([...txin0, ...txin1]), hashSequence: UtxoCrypto.dsha(TronCrypto.fromHex('eeffffffffffffff')),
      outpoint: txin1, scriptCode: [0x76, 0xa9, 0x14, ...pkh, 0x88, 0xac], value: 600000000, sequence: const [0xff, 0xff, 0xff, 0xff],
      hashOutputs: UtxoCrypto.dsha(outs), locktime: 0x11,
    );
    expect(TronCrypto.hex(h), 'c37af31116d1b27caf68aae9e3ac82f1477929014d5b917657d0eb49478cb670');
  });

  test('Bitcoin family: DER signatures verify; a built transaction has the right shape and id', () {
    final priv = UtxoCrypto.privateKey(phrase, UtxoChain.btc);
    final h = UtxoCrypto.dsha('hushavia'.codeUnits);
    final sig = TronCrypto.sign(h, priv);
    final der = UtxoCrypto.der(sig);
    expect(der.first, 0x30);
    expect(der.last, 0x01, reason: 'SIGHASH_ALL');
    expect(der.length, der[1] + 3);
    final me = UtxoCrypto.addressOf(priv, UtxoChain.btc);
    final p = UtxoPrepared(
      chain: UtxoChain.btc, from: me, to: '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2', amount: BigInt.from(50000), fee: BigInt.from(1000),
      change: BigInt.from(49000), inputs: [Utxo('aa' * 32, 1, 100000)],
    );
    final raw = UtxoTx.sign(p, priv);
    expect(TronCrypto.hex(raw.sublist(0, 6)), '020000000001', reason: 'version 2 + SegWit marker');
    expect(UtxoTx.txid(raw, UtxoChain.btc).length, 64);
    // Dogecoin (legacy): the id is simply the hash of the whole transaction
    final dp = UtxoCrypto.privateKey(phrase, UtxoChain.doge);
    final d = UtxoPrepared(
      chain: UtxoChain.doge, from: UtxoCrypto.addressOf(dp, UtxoChain.doge), to: 'DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC', amount: BigInt.from(500000000),
      fee: BigInt.from(1000000), change: BigInt.zero, inputs: [Utxo('bb' * 32, 0, 501000000)],
    );
    final draw = UtxoTx.sign(d, dp);
    expect(UtxoTx.txid(draw, UtxoChain.doge), TronCrypto.hex(UtxoCrypto.dsha(draw).reversed.toList()));
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
