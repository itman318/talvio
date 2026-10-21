import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';

import '../config.dart';

class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic> extra;

  ApiException(this.status, this.code, this.message, [this.extra = const {}]);

  bool get isNetwork => status == 0;

  @override
  String toString() => message;
}

/// Codes that mean this device is no longer logged in.
const _sessionEndingCodes = {
  'session_revoked',
  'account_deleted',
  'account_banned',
  'invalid_refresh_token',
};

/// REST client with automatic access-token refresh.
class ApiClient {
  ApiClient();

  static const _storage = FlutterSecureStorage();
  final http.Client _http = http.Client();

  String? accessToken;
  String? refreshToken;
  Future<void>? _refreshing;
  Timer? _refreshTimer;

  /// Called when the server says this session is over (logout everywhere, ban, deletion).
  void Function(ApiException reason)? onSessionEnded;

  /// Called whenever a new access token is issued (socket reconnects with it).
  void Function(String accessToken)? onTokenRefreshed;

  bool get isLoggedIn => refreshToken != null;

  // ------------------------------------------------------------------ token storage
  Future<void> loadTokens() async {
    accessToken = await _storage.read(key: 'access_token');
    refreshToken = await _storage.read(key: 'refresh_token');
  }

  Future<void> setTokens(String access, String refresh, int expiresInSec) async {
    accessToken = access;
    refreshToken = refresh;
    await _storage.write(key: 'access_token', value: access);
    await _storage.write(key: 'refresh_token', value: refresh);
    _refreshTimer?.cancel();
    final wait = Duration(seconds: (expiresInSec - 60).clamp(30, 86400));
    _refreshTimer = Timer(wait, () => refreshTokens().catchError((_) {}));
    onTokenRefreshed?.call(access);
  }

  Future<void> clearTokens() async {
    _refreshTimer?.cancel();
    accessToken = null;
    refreshToken = null;
    await _storage.delete(key: 'access_token');
    await _storage.delete(key: 'refresh_token');
  }

  /// Single-flight refresh: concurrent callers share one request
  /// (the server rotates refresh tokens, so two parallel refreshes would log us out).
  Future<void> refreshTokens() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _doRefresh() async {
    final rt = refreshToken;
    if (rt == null) throw ApiException(401, 'invalid_refresh_token', 'Please log in again');
    final data = await _send('POST', '/auth/refresh', body: {'refresh_token': rt}, auth: false, retry: false);
    await setTokens(data['access_token'] as String, data['refresh_token'] as String, (data['expires_in'] as num).toInt());
  }

  // ------------------------------------------------------------------ requests
  Uri uri(String path, [Map<String, String>? query]) {
    final u = Uri.parse('${AppConfig.apiBase}$path');
    return query == null ? u : u.replace(queryParameters: {...u.queryParameters, ...query});
  }

  Map<String, String> get authHeaders => accessToken == null ? {} : {'Authorization': 'Bearer $accessToken'};

  Future<dynamic> get(String path, {Map<String, String>? query}) => _send('GET', path, query: query);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body: body ?? {});
  Future<dynamic> put(String path, [Object? body]) => _send('PUT', path, body: body ?? {});
  Future<dynamic> patch(String path, [Object? body]) => _send('PATCH', path, body: body ?? {});
  Future<dynamic> delete(String path, [Object? body]) => _send('DELETE', path, body: body);

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
    bool retry = true,
  }) async {
    final req = http.Request(method, uri(path, query));
    req.headers['Content-Type'] = 'application/json';
    req.headers['Accept'] = 'application/json';
    if (auth) req.headers.addAll(authHeaders);
    if (body != null) req.body = jsonEncode(body);

    final res = await _execute(() => _http.send(req));
    if (res.statusCode == 401 && auth && retry && refreshToken != null) {
      await refreshTokens();
      return _send(method, path, body: body, query: query, auth: auth, retry: false);
    }
    return _decode(res);
  }

  Future<http.Response> _execute(Future<http.StreamedResponse> Function() send, {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      return await http.Response.fromStream(await send().timeout(timeout));
    } on SocketException {
      throw ApiException(0, 'network', 'No internet connection');
    } on TimeoutException {
      throw ApiException(0, 'network', 'The server is taking too long to respond');
    } on http.ClientException {
      throw ApiException(0, 'network', 'Could not reach the server');
    }
  }

  dynamic _decode(http.Response res) {
    dynamic data;
    if (res.bodyBytes.isNotEmpty) {
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        data = null;
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return data;
    final err = (data is Map && data['error'] is Map) ? Map<String, dynamic>.from(data['error'] as Map) : <String, dynamic>{};
    final ex = ApiException(
      res.statusCode,
      (err['code'] ?? 'error') as String,
      (err['message'] ?? 'Something went wrong (${res.statusCode})') as String,
      err,
    );
    if (_sessionEndingCodes.contains(ex.code)) onSessionEnded?.call(ex);
    throw ex;
  }

  // ------------------------------------------------------------------ files
  /// Uploads a file. kind: image | video | voice | file | avatar. Returns the media JSON.
  Future<Map<String, dynamic>> upload(
    String filePath, {
    required String kind,
    String? mime,
    Map<String, String> fields = const {},
    bool retry = true,
  }) async {
    final req = http.MultipartRequest('POST', uri('/media'));
    req.headers.addAll(authHeaders);
    req.fields['kind'] = kind;
    req.fields.addAll(fields);
    final type = mime ?? lookupMimeType(filePath) ?? 'application/octet-stream';
    req.files.add(await http.MultipartFile.fromPath('file', filePath, contentType: MediaType.parse(type)));
    final res = await _execute(() => _http.send(req), timeout: const Duration(minutes: 10));
    if (res.statusCode == 401 && retry && refreshToken != null) {
      await refreshTokens();
      return upload(filePath, kind: kind, mime: mime, fields: fields, retry: false);
    }
    return Map<String, dynamic>.from(_decode(res) as Map);
  }

  /// Downloads a protected file (e.g. /api/media/12) to [target].
  Future<File> download(String apiUrl, File target, {bool retry = true}) async {
    final req = http.Request('GET', Uri.parse(AppConfig.absolute(apiUrl)));
    req.headers.addAll(authHeaders);
    final streamed = await _http.send(req).timeout(const Duration(minutes: 10));
    if (streamed.statusCode == 401 && retry && refreshToken != null) {
      await streamed.stream.drain<void>();
      await refreshTokens();
      return download(apiUrl, target, retry: false);
    }
    if (streamed.statusCode != 200) {
      await streamed.stream.drain<void>();
      throw ApiException(streamed.statusCode, 'download_failed', 'Could not download the file');
    }
    final tmp = File('${target.path}.part');
    final sink = tmp.openWrite();
    await streamed.stream.pipe(sink);
    return tmp.rename(target.path);
  }
}
