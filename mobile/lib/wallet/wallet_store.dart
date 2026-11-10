import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  String? address;
  TronNet net = TronNet.main;
  bool loaded = false;

  bool get exists => address != null;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    net = TronNet.byId(p.getString(_netKey));
    address = p.getString(_addrKey);
    if (address == null && await _secure.containsKey(key: _phraseKey)) {
      // address cache was cleared: rebuild it (the address is public, the phrase stays locked)
      final phrase = await _secure.read(key: _phraseKey);
      if (phrase != null) {
        address = TronCrypto.addressOf(TronCrypto.privateKey(phrase));
        await p.setString(_addrKey, address!);
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
    await _secure.write(key: _phraseKey, value: p);
    (await SharedPreferences.getInstance()).setString(_addrKey, addr);
    address = addr;
    notifyListeners();
  }

  /// Removes the wallet from this phone (the money stays on the network; the phrase brings it back).
  Future<void> remove() async {
    await _secure.delete(key: _phraseKey);
    (await SharedPreferences.getInstance()).remove(_addrKey);
    address = null;
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
