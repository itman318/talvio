import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

import 'evm.dart';
import 'utxo.dart';
import 'tron_api.dart';
import 'tron_crypto.dart';

/// The wallet on THIS phone, for one Hushavia account. The recovery phrase is kept only in the
/// phone's secure storage (Android Keystore) and is read only after the fingerprint / screen lock.
/// It is never sent to Hushavia, never logged, never backed up by us.
class WalletStore extends ChangeNotifier {
  WalletStore(this.userId);
  final int userId;

  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  String get _phraseKey => 'wallet_phrase_v1_$userId';
  String get _addrKey => 'wallet_addr_v1_$userId';
  String get _netKey => 'wallet_net_v1_$userId';
  String get _evmKey => 'wallet_evm_v1_$userId';
  String get _tokensKey => 'wallet_tokens_v1_$userId';
  String get _hideKey => 'wallet_hide0_v1_$userId';
  String get _utxoKey => 'wallet_utxo_v1_$userId';

  String? address; // TRON
  String? evmAddress; // the same 0x address on every EVM network
  Map<String, String> utxoAddr = {}; // 'btc' | 'ltc' | 'doge' → address
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
    try {
      hasPhrase = await _secure.containsKey(key: _phraseKey);
    } catch (_) {
      // secure storage can't be read (e.g. restored from a backup on a new phone): the 12 words bring it back
      hasPhrase = false;
    }
    if (address != null && !hasPhrase) {
      // the address is remembered but its key is gone: don't show a wallet that can't send
      address = null;
      evmAddress = null;
    }
    if ((address == null || evmAddress == null || UtxoChain.all.any((c) => utxoAddr[c.id] == null)) && hasPhrase) {
      // address cache missing (or a wallet made before EVM support): rebuild it — addresses are public,
      // the phrase stays locked in secure storage
      final phrase = await _secure.read(key: _phraseKey);
      if (phrase != null) {
        address = TronCrypto.addressOf(TronCrypto.privateKey(phrase));
        evmAddress = EvmCrypto.addressOf(EvmCrypto.privateKey(phrase));
        utxoAddr = _utxoOf(phrase);
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
    final addr = TronCrypto.addressOf(TronCrypto.privateKey(p));
    final evm = EvmCrypto.addressOf(EvmCrypto.privateKey(p));
    final utxo = _utxoOf(p);
    await _secure.write(key: _phraseKey, value: p);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_addrKey, addr);
    await prefs.setString(_evmKey, evm);
    await prefs.setString(_utxoKey, jsonEncode(utxo));
    utxoAddr = utxo;
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
    address = null;
    evmAddress = null;
    utxoAddr = {};
    notifyListeners();
  }

  static Map<String, String> _utxoOf(String phrase) => {for (final c in UtxoChain.all) c.id: UtxoCrypto.addressOf(UtxoCrypto.privateKey(phrase, c), c)};

  /// My address on a network ('tron', 'btc', … or any EVM chain id).
  String? addressFor(String network) {
    if (network == 'tron') return address;
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
    return _secure.read(key: _phraseKey);
  }

  static Future<bool> phoneIsLocked() async {
    try {
      return await LocalAuthentication().isDeviceSupported();
    } catch (_) {
      return false;
    }
  }
}
