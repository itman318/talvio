import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Builds 266–281 opened the wallet's secure storage with `encryptedSharedPreferences: true`.
/// On Android that MOVES everything the app keeps in secure storage (login tokens, accounts,
/// secret-chat keys, the wallet phrase) into a second store — so the login code could no longer
/// find its token and logged people out again and again.
///
/// This runs once, before anything reads secure storage: whatever sits in that second store is
/// copied back (values already in the normal store win, they are newer), then the second store is
/// emptied. Nothing is ever deleted before it has been written back.
class SecureRepair {
  SecureRepair._();

  static const _plain = FlutterSecureStorage();
  static const _encrypted = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  static Future<void> run() async {
    SharedPreferences? p;
    try {
      p = await SharedPreferences.getInstance();
      if (p.getBool('secure_repair_v1') == true) return;
      // only phones that ever opened the wallet store can have anything to move back
      final touched = p.getKeys().any((k) => k.startsWith('wallet_'));
      if (!touched) {
        await p.setBool('secure_repair_v1', true);
        return;
      }
      final current = await _plain.readAll(); // read FIRST: opening the other store may move these too
      final moved = await _encrypted.readAll();
      final merged = {...moved, ...current}; // the normal store's values are the newer ones
      final now = await _plain.readAll();
      var ok = true;
      for (final e in merged.entries) {
        if (now[e.key] == e.value) continue;
        try {
          await _plain.write(key: e.key, value: e.value);
          if (await _plain.read(key: e.key) != e.value) ok = false;
        } catch (_) {
          ok = false;
        }
      }
      if (ok) {
        await _encrypted.deleteAll();
        await p.setBool('secure_repair_v1', true);
      }
    } catch (_) {
      // never block the start; it is tried again next time
    }
  }
}
