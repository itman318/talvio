import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';
import '../core/api_client.dart';
import '../core/prefs.dart';
import '../core/services.dart';
import '../models/models.dart';
import 'chat_store.dart';

enum AuthStatus { loading, loggedOut, needsProfile, loggedIn, maintenance, updateRequired }

class AuthState extends ChangeNotifier {
  AuthState(this.services, this.chats);

  final AppServices services;
  final ChatStore chats;
  static const _storage = FlutterSecureStorage();

  AuthStatus status = AuthStatus.loading;
  AppUser? me;
  Map<String, dynamic> appConfig = {};
  String? logoutReason;

  /// Device prefs; drafts and app lock are cleared on logout.
  AppPrefs? prefs;

  ApiClient get api => services.api;

  Future<void> init() async {
    api.onSessionEnded = (e) => _forceLogout(e.code == 'account_banned' ? _banText(e) : e.message);
    chats.onSessionRevoked = () => _forceLogout('You were logged out from this device.');
    await services.push.init();

    try {
      appConfig = Map<String, dynamic>.from(await api.get('/app-config') as Map);
      if (appConfig['maintenance_mode'] == true) {
        status = AuthStatus.maintenance;
        notifyListeners();
        return;
      }
      if (_isOlder(AppConfig.appVersion, '${appConfig['min_app_version'] ?? '0'}')) {
        status = AuthStatus.updateRequired;
        notifyListeners();
        return;
      }
    } on ApiException catch (e) {
      if (e.code == 'maintenance') {
        appConfig['maintenance_message'] = e.message;
        status = AuthStatus.maintenance;
        notifyListeners();
        return;
      }
      // offline: carry on with cached session
    }

    await api.loadTokens();
    if (!api.isLoggedIn) {
      status = AuthStatus.loggedOut;
      notifyListeners();
      return;
    }
    final cached = await _storage.read(key: 'me');
    if (cached != null) me = AppUser.fromJson(Map<String, dynamic>.from(jsonDecode(cached) as Map));
    try {
      await api.refreshTokens();
      await _loadMe();
    } on ApiException catch (e) {
      if (!e.isNetwork) {
        await _clearLocal();
        status = AuthStatus.loggedOut;
        notifyListeners();
        return;
      }
      if (me == null) {
        status = AuthStatus.loggedOut;
        notifyListeners();
        return;
      }
    }
    _enter();
  }

  Future<void> _loadMe() async {
    me = AppUser.fromJson(Map<String, dynamic>.from(await api.get('/me') as Map));
    await _storage.write(key: 'me', value: jsonEncode(_meJson(me!)));
  }

  void _enter() {
    if (me == null) return;
    status = me!.firstName.isEmpty ? AuthStatus.needsProfile : AuthStatus.loggedIn;
    if (status == AuthStatus.loggedIn) _startSession();
    notifyListeners();
  }

  void _startSession() {
    services.socket.connect();
    chats.start(me!.id);
    services.push.registerDevice();
  }

  // ------------------------------------------------------------------ login
  Future<Map<String, dynamic>> requestOtp(String phone) async {
    return Map<String, dynamic>.from(await api.post('/auth/otp/request', {'phone': phone}) as Map);
  }

  Future<void> verifyOtp(String phone, String code) async {
    final data = Map<String, dynamic>.from(await api.post('/auth/otp/verify', {
      'phone': phone,
      'code': code,
      'device': {
        'name': _deviceName(),
        'platform': Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'other'),
        'app_version': AppConfig.appVersion,
      },
    }) as Map);
    await api.setTokens(data['access_token'] as String, data['refresh_token'] as String, (data['expires_in'] as num).toInt());
    me = AppUser.fromJson(Map<String, dynamic>.from(data['user'] as Map));
    await _storage.write(key: 'me', value: jsonEncode(_meJson(me!)));
    logoutReason = null;
    _enter();
  }

  /// Completes sign-up (first name is required).
  Future<void> saveProfile({required String firstName, String lastName = '', String? avatarPath}) async {
    if (avatarPath != null) {
      final m = await api.upload(avatarPath, kind: 'avatar');
      await api.put('/me/avatar', {'media_id': m['id']});
    }
    final u = await api.patch('/me', {'first_name': firstName, 'last_name': lastName});
    setMe(AppUser.fromJson(Map<String, dynamic>.from(u as Map)));
    if (status == AuthStatus.needsProfile) {
      status = AuthStatus.loggedIn;
      _startSession();
      notifyListeners();
    }
  }

  void setMe(AppUser u) {
    me = u;
    _storage.write(key: 'me', value: jsonEncode(_meJson(u)));
    notifyListeners();
  }

  Future<void> refreshMe() async {
    try {
      await _loadMe();
      notifyListeners();
    } catch (_) {}
  }

  // ------------------------------------------------------------------ logout
  Future<void> logout() async {
    try {
      await api.post('/auth/logout');
    } catch (_) {}
    await _clearLocal();
    status = AuthStatus.loggedOut;
    notifyListeners();
  }

  Future<void> deleteAccount() async {
    await api.delete('/me', {'confirm': 'DELETE'});
    await _clearLocal();
    status = AuthStatus.loggedOut;
    notifyListeners();
  }

  Future<void> _forceLogout(String reason) async {
    if (status == AuthStatus.loggedOut) return;
    logoutReason = reason;
    await _clearLocal();
    status = AuthStatus.loggedOut;
    notifyListeners();
  }

  Future<void> _clearLocal() async {
    services.socket.disconnect();
    await services.push.unregister();
    chats.stop();
    me = null;
    await api.clearTokens();
    await _storage.delete(key: 'me');
    await prefs?.clearAccountData();
  }

  // ------------------------------------------------------------------ helpers
  String _banText(ApiException e) {
    final reason = e.extra['reason'];
    final until = e.extra['until'];
    var text = 'Your account has been banned';
    if (until != null) text += ' until ${DateTime.parse(until as String).toLocal().toString().substring(0, 16)}';
    if (reason != null) text += '.\nReason: $reason';
    return text;
  }

  static String _deviceName() {
    final s = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    return s.length > 100 ? s.substring(0, 100) : s;
  }

  static Map<String, dynamic> _meJson(AppUser u) => {
        'id': u.id,
        'first_name': u.firstName,
        'last_name': u.lastName,
        'username': u.username,
        'bio': u.bio,
        'avatar_url': u.avatarUrl,
        'phone': u.phone,
        'is_verified': u.isVerified,
        'privacy': u.privacy,
      };

  /// true if version a < b (dotted numeric versions).
  static bool _isOlder(String a, String b) {
    final pa = a.split('.').map((x) => int.tryParse(x) ?? 0).toList();
    final pb = b.split('.').map((x) => int.tryParse(x) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x < y;
    }
    return false;
  }

  /// Admin feature switches (default on when the server doesn't say).
  bool feature(String key) => (appConfig['features'] as Map?)?[key] != false;

  bool get updateAvailable => _isOlder(AppConfig.appVersion, '${appConfig['latest_app_version'] ?? '0'}');
}
