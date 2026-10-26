import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';
import '../core/accounts.dart';
import '../core/api_client.dart';
import '../core/passkeys.dart';
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
  /// Talvio Plus can be bought (admin opened sales); otherwise the app shows it as coming soon.
  bool get plusAvailable => appConfig['plus_available'] == true;
  String? logoutReason;

  /// Device prefs; drafts and app lock are cleared on logout.
  AppPrefs? prefs;

  /// Called when this device logs out (ends any call in progress).
  void Function()? onSessionCleared;

  /// Called when switching to another account on this phone (end calls, park secret chats).
  void Function()? onAccountSwitch;

  /// Accounts saved on this phone (multiple accounts).
  final accounts = AccountStore();

  /// True while the user is adding a second account (login screen shows "Back").
  bool addingAccount = false;
  bool _setupDone = false;

  int get maxAccounts => ((appConfig['max_accounts'] as num?)?.toInt() ?? 3) + ((me?.limits?['extra_accounts'] as num?)?.toInt() ?? 0);
  List<StoredAccount> get otherAccounts => accounts.others(me?.id);

  ApiClient get api => services.api;

  /// Startup: never leaves the app stuck on the splash screen, even if a plugin throws.
  Future<void> init() async {
    try {
      await _init();
    } catch (e, st) {
      debugPrint('Auth init failed: $e\n$st');
      if (status == AuthStatus.loading) {
        status = AuthStatus.loggedOut;
        notifyListeners();
      }
    }
  }

  Future<void> _init() async {
    if (!_setupDone) {
      _setupDone = true;
      api.onSessionEnded = (e) => _forceLogout(e.code == 'account_banned' ? _banText(e) : e.message);
      chats.onSessionRevoked = () => _forceLogout('You were logged out from this device.');
      // Firebase starts in the background — never holds the splash screen
      unawaited(services.push.init().catchError((Object e) => debugPrint('Push init skipped: $e')));
      await accounts.load();
    }


    try {
      // short timeout: an unreachable server must not keep the splash screen up
      appConfig = Map<String, dynamic>.from(await api.get('/app-config').timeout(const Duration(seconds: 4)) as Map);
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
    } on TimeoutException {
      // offline / server down: carry on with the cached session
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
      if (me != null) {
        // we know who this is: open the app now and refresh in the background
        _enter();
        unawaited(() async {
          try {
            await api.refreshTokens();
            await _loadMe();
            notifyListeners();
          } catch (_) {
            // a dead session is reported through api.onSessionEnded → logout
          }
        }());
        return;
      }
      await api.refreshTokens().timeout(const Duration(seconds: 10));
      await _loadMe();
    } on TimeoutException {
      status = AuthStatus.loggedOut;
      notifyListeners();
      return;
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
    await _rememberActive();
  }

  /// Records the active account in the account list (its tokens stay in ApiClient).
  Future<void> _rememberActive() async {
    final u = me;
    if (u == null) return;
    await accounts.upsert(StoredAccount(id: u.id, name: u.name, phone: u.phone ?? u.email, avatarUrl: u.avatarUrl));
    addingAccount = false;
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

  Future<void> verifyOtp(String phone, String code) =>
      _verify('/auth/otp/verify', {'phone': phone, 'code': code});

  /// Login code by email (free) — the account is identified by the email address.
  Future<Map<String, dynamic>> requestEmailCode(String email) async {
    return Map<String, dynamic>.from(await api.post('/auth/email/request', {'email': email}) as Map);
  }

  Future<void> verifyEmailCode(String email, String code) =>
      _verify('/auth/email/verify', {'email': email, 'code': code});

  /// Which login methods the server allows (admin → Settings → General).
  bool get emailLoginEnabled => (appConfig['login_methods'] as Map?)?['email'] != false;
  bool get phoneLoginEnabled => (appConfig['login_methods'] as Map?)?['phone'] != false;

  Map<String, dynamic> get _device => {
        'name': _deviceName(),
        'platform': Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'other'),
        'app_version': AppConfig.appVersion,
      };

  /// Set when the account has two-step verification: the login waits for the password.
  Map<String, dynamic>? passwordChallenge;

  Future<void> _verify(String path, Map<String, dynamic> body) async {
    passwordChallenge = null;
    final data = Map<String, dynamic>.from(await api.post(path, {...body, 'device': _device}) as Map);
    if (data['needs_password'] == true) {
      passwordChallenge = data;
      notifyListeners();
      return;
    }
    await _completeLogin(data);
  }

  /// Second login step (two-step verification).
  Future<void> verifyPassword(String password) async {
    final ch = passwordChallenge;
    if (ch == null) throw ApiException(400, 'login_expired', 'Start the login again');
    final data = Map<String, dynamic>.from(await api.post('/auth/password/verify', {
      'login_token': ch['login_token'],
      'password': password,
      'device': _device,
    }) as Map);
    passwordChallenge = null;
    await _completeLogin(data);
  }

  /// Passkey login (fingerprint / face). Returns false when the user cancelled the check.
  Future<bool> loginWithPasskey(LocalPasskey p) async {
    passwordChallenge = null;
    final data = await Passkeys.login(api, p, _device);
    if (data == null) return false;
    await _completeLogin(data);
    return true;
  }

  /// "Forgot password": the password is removed after 7 days. Returns when.
  Future<DateTime?> requestPasswordReset() async {
    final ch = passwordChallenge;
    if (ch == null) return null;
    final r = Map<String, dynamic>.from(await api.post('/auth/password/reset', {'login_token': ch['login_token']}) as Map);
    final until = r['reset_pending_until'] as String?;
    passwordChallenge = {...ch, 'reset_pending_until': until};
    notifyListeners();
    return until == null ? null : DateTime.parse(until).toLocal();
  }

  Future<void> _completeLogin(Map<String, dynamic> data) async {
    final user = AppUser.fromJson(Map<String, dynamic>.from(data['user'] as Map));
    await api.setTokens(data['access_token'] as String, data['refresh_token'] as String, (data['expires_in'] as num).toInt());
    me = user;
    await _storage.write(key: 'me', value: jsonEncode(_meJson(me!)));
    await _rememberActive();
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

  // ------------------------------------------------------------------ multiple accounts
  /// Saves the active account's tokens in the list and signs out locally (the server session stays).
  Future<void> _parkActive() async {
    final u = me;
    if (u != null && api.refreshToken != null) {
      await accounts.upsert(StoredAccount(id: u.id, name: u.name, phone: u.phone ?? u.email, avatarUrl: u.avatarUrl, access: api.accessToken, refresh: api.refreshToken));
    }
    onAccountSwitch?.call();
    services.socket.disconnect();
    chats.stop();
    me = null;
    await api.clearTokens();
    await _storage.delete(key: 'me');
  }

  /// "Add account": keeps the current one logged in and shows the login screen.
  Future<void> addAccount() async {
    if (accounts.list.length >= maxAccounts) {
      throw ApiException(400, 'too_many_accounts', 'You can have up to $maxAccounts accounts on this phone');
    }
    await _parkActive();
    addingAccount = true;
    logoutReason = null;
    status = AuthStatus.loggedOut;
    notifyListeners();
  }

  Future<void> switchTo(int userId) async {
    final target = accounts.byId(userId);
    if (target == null || target.refresh == null || target.id == me?.id) return;
    await _parkActive();
    await api.setTokens(target.access ?? '', target.refresh!, 30);
    await accounts.upsert(target.copyWith(clearTokens: true));
    addingAccount = false;
    status = AuthStatus.loading;
    notifyListeners();
    await init();
  }

  /// Leaving the login screen while adding an account → back to the last one.
  Future<void> cancelAddAccount() async {
    final others = accounts.others(null);
    if (others.isEmpty) return;
    await switchTo(others.last.id);
  }

  /// After logging out of the active account, continue with another saved one.
  Future<bool> _continueWithAnother(int? removedId) async {
    if (removedId != null) await accounts.remove(removedId);
    final others = accounts.others(null);
    if (others.isEmpty) return false;
    final t = others.first;
    await api.setTokens(t.access ?? '', t.refresh!, 30);
    await accounts.upsert(t.copyWith(clearTokens: true));
    status = AuthStatus.loading;
    notifyListeners();
    await init();
    return true;
  }

  // ------------------------------------------------------------------ logout
  /// True while we end the session ourselves (the server's "session revoked" echo must not log out a new session).
  bool _endingSession = false;

  Future<void> logout() async {
    final id = me?.id;
    _endingSession = true;
    try {
      // stop listening first: the server tells this socket "session revoked" when we log out
      services.socket.disconnect();
      try {
        await api.post('/auth/logout');
      } catch (_) {}
      await _clearLocal();
      if (await _continueWithAnother(id)) return;
      status = AuthStatus.loggedOut;
      notifyListeners();
    } finally {
      _endingSession = false;
    }
  }

  Future<void> deleteAccount() async {
    final id = me?.id;
    _endingSession = true;
    try {
      await api.delete('/me', {'confirm': 'DELETE'});
      services.socket.disconnect();
      await _clearLocal();
      if (await _continueWithAnother(id)) return;
      status = AuthStatus.loggedOut;
      notifyListeners();
    } finally {
      _endingSession = false;
    }
  }

  Future<void> _forceLogout(String reason) async {
    if (status == AuthStatus.loggedOut || _endingSession) return;
    final id = me?.id;
    logoutReason = reason;
    await _clearLocal();
    if (await _continueWithAnother(id)) return;
    status = AuthStatus.loggedOut;
    notifyListeners();
  }

  Future<void> _clearLocal() async {
    onSessionCleared?.call();
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
        'email': u.email,
        'is_verified': u.isVerified,
        'is_premium': u.isPremium,
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
