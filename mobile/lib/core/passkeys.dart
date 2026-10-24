import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../config.dart';
import 'api_client.dart';

/// A passkey kept on this phone: the private key never leaves secure storage
/// and is only used after the fingerprint / face / screen-lock check.
class LocalPasskey {
  LocalPasskey({required this.credentialId, required this.userId, required this.name, required this.server, required this.seed});
  final int credentialId;
  final int userId;
  final String name; // account name shown on the login screen
  final String server;
  final String seed; // base64 Ed25519 private key seed

  Map<String, dynamic> toJson() => {'cid': credentialId, 'uid': userId, 'name': name, 'server': server, 'seed': seed};
  static LocalPasskey fromJson(Map j) => LocalPasskey(
        credentialId: (j['cid'] as num).toInt(),
        userId: (j['uid'] as num).toInt(),
        name: '${j['name'] ?? ''}',
        server: '${j['server'] ?? ''}',
        seed: '${j['seed']}',
      );
}

class Passkeys {
  Passkeys._();

  static const _storage = FlutterSecureStorage();
  static const _key = 'passkeys_v1';
  static final _ed = Ed25519();

  static Future<List<LocalPasskey>> all() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List).map((e) => LocalPasskey.fromJson(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Passkeys for the server this app talks to.
  static Future<List<LocalPasskey>> forThisServer() async => (await all()).where((p) => p.server == AppConfig.apiBase).toList();

  static Future<void> _save(List<LocalPasskey> list) => _storage.write(key: _key, value: jsonEncode(list.map((p) => p.toJson()).toList()));

  static Future<void> forget(int credentialId) async => _save((await all()).where((p) => p.credentialId != credentialId).toList());

  static Future<bool> _confirm(String reason) async {
    final auth = LocalAuthentication();
    if (!await auth.isDeviceSupported()) {
      throw ApiException(400, 'no_lock', 'Set up a fingerprint, face unlock or screen lock on this phone first');
    }
    return auth.authenticate(localizedReason: reason);
  }

  static String _deviceName() {
    if (Platform.isAndroid) return 'Android phone';
    if (Platform.isIOS) return 'iPhone';
    return 'Device';
  }

  /// Creates a passkey for the logged-in account and registers its public key.
  static Future<void> create(ApiClient api, {required int userId, required String accountName}) async {
    if (!await _confirm('Confirm to create a passkey')) return;
    final pair = await _ed.newKeyPair();
    final seed = await pair.extractPrivateKeyBytes();
    final pub = (await pair.extractPublicKey()).bytes;
    final r = Map<String, dynamic>.from(await api.post('/me/passkeys', {'public_key': base64Encode(pub), 'name': _deviceName()}) as Map);
    final list = (await all()).where((p) => !(p.userId == userId && p.server == AppConfig.apiBase)).toList()
      ..add(LocalPasskey(credentialId: (r['id'] as num).toInt(), userId: userId, name: accountName, server: AppConfig.apiBase, seed: base64Encode(seed)));
    await _save(list);
  }

  /// Logs in with [p]: biometric check, then the signed challenge. Returns the login response.
  static Future<Map<String, dynamic>?> login(ApiClient api, LocalPasskey p, Map<String, dynamic> device) async {
    if (!await _confirm('Log in to ${AppConfig.appName}')) return null;
    final ch = Map<String, dynamic>.from(await api.post('/auth/passkey/challenge', {'credential_id': p.credentialId}) as Map);
    final challenge = '${ch['challenge']}';
    final pair = await _ed.newKeyPairFromSeed(base64Decode(p.seed));
    final sig = await _ed.sign(utf8.encode(challenge), keyPair: pair);
    try {
      return Map<String, dynamic>.from(await api.post('/auth/passkey/verify', {
        'credential_id': p.credentialId,
        'challenge': challenge,
        'signature': base64Encode(sig.bytes),
        'device': device,
      }) as Map);
    } on ApiException catch (e) {
      if (e.code == 'passkey_not_found' || e.code == 'account_deleted') await forget(p.credentialId);
      rethrow;
    }
  }
}
