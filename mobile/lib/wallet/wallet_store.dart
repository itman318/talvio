import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

import 'evm.dart';
import 'solana.dart';
import 'utxo.dart';
import 'tron_api.dart';
import 'tron_crypto.dart';

/// The wallet on THIS phone, for one Hushavia account. The recovery phrase is kept only in the
/// phone's secure storage (Android Keystore) and is read only after the fingerprint / screen lock.
/// It is never sent to Hushavia, never logged, never backed up by us.
class WalletStore extends ChangeNotifier {
  WalletStore(this.userId);
  final int userId;

  // the SAME storage options as the rest of the app (other options make Android move the app's
  // whole secure storage — that logged people out; see core/secure_repair.dart)
  static const _secure = FlutterSecureStorage();
  String get _phraseKey => 'wallet_phrase_v1_$userId';
  String get _addrKey => 'wallet_addr_v1_$userId';
  String get _netKey => 'wallet_net_v1_$userId';
  String get _evmKey => 'wallet_evm_v1_$userId';
  String get _tokensKey => 'wallet_tokens_v1_$userId';
  String get _hideKey => 'wallet_hide0_v1_$userId';
  String get _utxoKey => 'wallet_utxo_v1_$userId';
  String get _solKey => 'wallet_sol_v1_$userId';
  String get _shownKey => 'wallet_shown_v1_$userId';

  String? address; // TRON
  String? evmAddress; // the same 0x address on every EVM network
  Map<String, String> utxoAddr = {}; // 'btc' | 'ltc' | 'doge' → address
  String? solAddress;
  /// Coins on the main list, in this order (the rest: Manage coins). Coins with a balance always show.
  List<String> shown = defaultShown;
  static const defaultShown = [
    'btc:native', 'eth:native', 'ltc:native', 'bsc:native', 'tron:TRX', 'sol:native', 'tron:USDT', 'eth:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
  ];
  List<EvmToken> customTokens = [];
  bool hideZero = true;
  TronNet net = TronNet.main;
  bool loaded = false;

  bool get exists => address != null;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    net = TronNet.byId(p.getString(_netKey));
    address = p.getString(_addrKey);
    evmAddress = p.getString(_evmKey);
    hideZero = p.getBool(_hideKey) ?? true;
    lockOnOpen = p.getBool(_lockKey) ?? false;
    solAddress = p.getString(_solKey);
    shown = p.getStringList(_shownKey) ?? defaultShown;
    try {
      utxoAddr = Map<String, String>.from(jsonDecode(p.getString(_utxoKey) ?? '{}') as Map);
    } catch (_) {
      utxoAddr = {};
    }
    try {
      customTokens = [for (final j in jsonDecode(p.getString(_tokensKey) ?? '[]') as List) EvmToken.fromJson(j as Map)];
    } catch (_) {
      customTokens = [];
    }
    var hasPhrase = false;
    var storageBroken = false;
    try {
      hasPhrase = await _secure.containsKey(key: _phraseKey);
      recoveredPhrase = await _secure.read(key: _recoveredKey);
    } catch (_) {
      // secure storage can't be read right now. That is NOT the same as "no wallet": keep showing
      // the wallet (sending will ask again) instead of inviting the person to make a new one.
      storageBroken = true;
    }
    if (address != null && !hasPhrase && !storageBroken) {
      // the address is remembered but its key is really gone (e.g. a phone restored from a backup):
      // the 12 words bring it back
      address = null;
      evmAddress = null;
    }
    if ((address == null || evmAddress == null || solAddress == null || UtxoChain.all.any((c) => utxoAddr[c.id] == null)) && hasPhrase) {
      // address cache missing (or a wallet made before EVM support): rebuild it — addresses are public,
      // the phrase stays locked in secure storage
      final phrase = await _secure.read(key: _phraseKey);
      if (phrase != null) {
        final a = await compute(addressesOf, phrase);
        address = a['tron'];
        evmAddress = a['evm'];
        utxoAddr = {for (final c in UtxoChain.all) c.id: a[c.id]!};
        solAddress = a['sol'];
        await p.setString(_solKey, solAddress!);
        await p.setString(_addrKey, address!);
        await p.setString(_evmKey, evmAddress!);
        await p.setString(_utxoKey, jsonEncode(utxoAddr));
      }
    }
    loaded = true;
    notifyListeners();
  }

  TronApi get api => TronApi(net);

  Future<void> setNet(TronNet n) async {
    net = n;
    (await SharedPreferences.getInstance()).setString(_netKey, n.id);
    notifyListeners();
  }

  /// Saves a new or imported phrase on this phone.
  Future<void> save(String phrase) async {
    final p = TronCrypto.normalize(phrase);
    if (!TronCrypto.isValidPhrase(p)) throw WalletException('These words are not a valid recovery phrase');
    final a = await compute(addressesOf, p);
    final addr = a['tron']!;
    final evm = a['evm']!;
    final utxo = {for (final c in UtxoChain.all) c.id: a[c.id]!};
    final sol = a['sol']!;
    // NEVER silently replace a phrase that is already on this phone: keep the old one readable
    // (Wallet → "Earlier wallet found"), whatever led here
    try {
      final old = await _secure.read(key: _phraseKey);
      if (old != null && old != p) {
        await _secure.write(key: _recoveredKey, value: old);
        recoveredPhrase = old;
      }
    } catch (_) {}
    await _secure.write(key: _phraseKey, value: p);
    if (await _secure.read(key: _phraseKey) != p) throw WalletException('This phone could not save the wallet safely. Nothing was changed.');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_addrKey, addr);
    await prefs.setString(_evmKey, evm);
    await prefs.setString(_utxoKey, jsonEncode(utxo));
    await prefs.setString(_solKey, sol);
    utxoAddr = utxo;
    solAddress = sol;
    address = addr;
    evmAddress = evm;
    notifyListeners();
  }

  /// Removes the wallet from this phone (the money stays on the network; the phrase brings it back).
  Future<void> remove() async {
    await _secure.delete(key: _phraseKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_addrKey);
    await prefs.remove(_evmKey);
    await prefs.remove(_utxoKey);
    await prefs.remove(_solKey);
    solAddress = null;
    address = null;
    evmAddress = null;
    utxoAddr = {};
    notifyListeners();
  }

  /// Every public address of a phrase. The slow part (turning words into the seed) runs ONCE,
  /// and off the screen's thread, so nothing freezes.
  static Future<Map<String, String>> addressesOf(String phrase) async {
    final seed = TronCrypto.seedOf(phrase);
    Uint8List key(int purpose, int coin) => TronCrypto.derive(seed, [0x80000000 + purpose, 0x80000000 + coin, 0x80000000, 0, 0]);
    return {
      'tron': TronCrypto.addressOf(key(44, 195)),
      'evm': EvmCrypto.addressOf(key(44, 60)),
      for (final c in UtxoChain.all) c.id: UtxoCrypto.addressOf(key(c.purpose, c.coin), c),
      'sol': await Sol.addressOf(Sol.privateKeyFromSeed(seed)),
    };
  }

  /// A phrase that was on this phone before the current one (kept so it can never be lost by accident).
  String? recoveredPhrase;
  String get _recoveredKey => 'wallet_phrase_v1_${userId}_recovered';

  Future<void> forgetRecovered() async {
    await _secure.delete(key: _recoveredKey);
    recoveredPhrase = null;
    notifyListeners();
  }

  /// My address on a network ('tron', 'btc', … or any EVM chain id).
  String? addressFor(String network) {
    if (network == 'tron') return address;
    if (network == 'sol') return solAddress;
    if (UtxoChain.byId(network) != null) return utxoAddr[network];
    return evmAddress;
  }

  Future<void> addToken(EvmToken t) async {
    if (customTokens.any((x) => x.chain == t.chain && x.address.toLowerCase() == t.address.toLowerCase()) ||
        EvmToken.builtIn.any((x) => x.chain == t.chain && x.address.toLowerCase() == t.address.toLowerCase())) {
      throw WalletException('${t.symbol} is already in your wallet');
    }
    customTokens = [...customTokens, t];
    (await SharedPreferences.getInstance()).setString(_tokensKey, jsonEncode([for (final x in customTokens) x.toJson()]));
    notifyListeners();
  }

  Future<void> removeToken(EvmToken t) async {
    customTokens = customTokens.where((x) => !(x.chain == t.chain && x.address == t.address)).toList();
    (await SharedPreferences.getInstance()).setString(_tokensKey, jsonEncode([for (final x in customTokens) x.toJson()]));
    notifyListeners();
  }

  Future<void> setShown(List<String> keys) async {
    shown = keys;
    (await SharedPreferences.getInstance()).setStringList(_shownKey, keys);
    notifyListeners();
  }

  /// Ask for the fingerprint every time the wallet is opened (sending always asks anyway).
  bool lockOnOpen = false;
  String get _lockKey => 'wallet_lock_v1_$userId';

  Future<void> setLockOnOpen(bool v) async {
    lockOnOpen = v;
    (await SharedPreferences.getInstance()).setBool(_lockKey, v);
    notifyListeners();
  }

  Future<void> setHideZero(bool v) async {
    hideZero = v;
    (await SharedPreferences.getInstance()).setBool(_hideKey, v);
    notifyListeners();
  }

  /// Fingerprint / face / screen lock. True when it passed.
  static Future<bool> confirmOwner(BuildContext context, String reason) async {
    final auth = LocalAuthentication();
    try {
      if (!await auth.isDeviceSupported()) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Set up a fingerprint or screen lock on this phone to protect your wallet')));
        }
        return false;
      }
      return await auth.authenticate(localizedReason: reason);
    } catch (_) {
      return false;
    }
  }

  /// The phrase, after the owner check. Null when the check failed.
  Future<String?> readPhrase(BuildContext context, String reason) async {
    if (!await confirmOwner(context, reason)) return null;
    String? phrase;
    try {
      phrase = await _secure.read(key: _phraseKey);
    } catch (_) {
      phrase = null;
    }
    // say so instead of doing nothing: the button would otherwise seem dead
    if (phrase == null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('This phone couldn’t open the wallet’s key right now. Restart the app and try again — your recovery phrase always brings the wallet back.'),
      ));
    }
    return phrase;
  }

  static Future<bool> phoneIsLocked() async {
    try {
      return await LocalAuthentication().isDeviceSupported();
    } catch (_) {
      return false;
    }
  }
}
