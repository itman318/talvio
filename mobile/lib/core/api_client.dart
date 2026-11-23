import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
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
  http.Client _http = _newClient();

  /// Short idle / connect limits: mobile networks silently drop idle connections, and
  /// re-using such a dead connection is what made requests hang until the timeout.
  static http.Client _newClient() => IOClient(HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 8));

  /// After a timeout: throw away pooled connections so the next request opens a fresh one.
  /// "US" from the phone's region setting (en_US), used for local prices.
  static final String? _deviceCountry = () {
    try {
      final m = RegExp(r'[_-]([A-Za-z]{2})').firstMatch(Platform.localeName);
      return m?.group(1)?.toUpperCase();
    } catch (_) {
      return null;
    }
  }();

  void resetConnections() => _resetConnections();

  void _resetConnections() {
    final old = _http;
    _http = _newClient();
    old.close();
  }

  String? accessToken;
  String? refreshToken;
  Future<void>? _refreshing;
  bool _quiet = false;
  Timer? _refreshTimer;

  /// When the access token runs out (read from the token itself).
  DateTime? _expiresAt;

  static DateTime? _expOf(String? jwt) {
    try {
      final parts = (jwt ?? '').split('.');
      if (parts.length != 3) return null;
      final p = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
      final exp = (p['exp'] as num?)?.toInt();
      return exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp * 1000);
    } catch (_) {
      return null;
    }
  }

  /// The phone slept past the token's end (timers don't run then): get a new one first,
  /// instead of every request failing with 401 and retrying.
  Future<void> _freshen() async {
    final exp = _expiresAt;
    if (refreshToken == null || exp == null || _quiet) return;
    if (DateTime.now().isBefore(exp.subtract(const Duration(seconds: 20)))) return;
    try {
      await refreshTokens();
    } catch (_) {} // the request itself will tell what's wrong
  }

  /// Called when the server says this session is over (logout everywhere, ban, deletion).
  void Function(ApiException reason)? onSessionEnded;

  /// Called whenever a new access token is issued (socket reconnects with it).
  void Function(String accessToken)? onTokenRefreshed;

  bool get isLoggedIn => refreshToken != null;

  // ------------------------------------------------------------------ token storage
  Future<void> loadTokens() async {
    accessToken = await _storage.read(key: 'access_token');
    refreshToken = await _storage.read(key: 'refresh_token');
    _expiresAt = _expOf(accessToken);
    // the old offline demo is gone: forget its placeholder session
    if (refreshToken == 'demo-session') await clearTokens();
  }

  Future<void> setTokens(String access, String refresh, int expiresInSec) async {
    accessToken = access;
    refreshToken = refresh;
    _expiresAt = _expOf(access) ?? DateTime.now().add(Duration(seconds: expiresInSec));
    await _storage.write(key: 'access_token', value: access);
    await _storage.write(key: 'refresh_token', value: refresh);
    _refreshTimer?.cancel();
    final wait = Duration(seconds: (expiresInSec - 60).clamp(30, 86400));
    _refreshTimer = Timer(wait, () => refreshTokens().catchError((_) {}));
    onTokenRefreshed?.call(access);
  }

  Future<void> clearTokens() async {
    _refreshTimer?.cancel();
    _expiresAt = null;
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
    dynamic data;
    try {
      _quiet = true; // don't end the session on the first "invalid" answer — check the saved token first
      data = await _send('POST', '/auth/refresh', body: {'refresh_token': rt}, auth: false, retry: false);
    } on ApiException catch (e) {
      _quiet = false;
      // another part of the app may have just saved a newer token: try that one before giving up
      final saved = await _storage.read(key: 'refresh_token');
      if (!_sessionEndingCodes.contains(e.code) || saved == null || saved == rt) {
        if (_sessionEndingCodes.contains(e.code)) onSessionEnded?.call(e);
        rethrow;
      }
      refreshToken = saved;
      data = await _send('POST', '/auth/refresh', body: {'refresh_token': saved}, auth: false, retry: false);
    } finally {
      _quiet = false;
    }
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
    if (auth) await _freshen();
    final req = http.Request(method, uri(path, query));
    req.headers['Content-Type'] = 'application/json';
    req.headers['Accept'] = 'application/json';
    final country = _deviceCountry;
    if (country != null) req.headers['X-Country'] = country; // prices in the user's currency
    if (auth) req.headers.addAll(authHeaders);
    if (body != null) req.body = jsonEncode(body);

    http.Response res;
    try {
      res = await _execute(() => _http.send(req), timeout: Duration(seconds: method == 'GET' ? 15 : 30));
    } on ApiException catch (e) {
      // a stuck connection: one more try on a fresh connection (reads only — never sends twice)
      if (e.code != 'network' || method != 'GET' || !retry) rethrow;
      final again = http.Request(method, req.url)..headers.addAll(req.headers);
      res = await _execute(() => _http.send(again), timeout: const Duration(seconds: 20));
    }
    if (res.statusCode == 401 && auth && retry && refreshToken != null) {
      await refreshTokens();
      return _send(method, path, body: body, query: query, auth: auth, retry: false);
    }
    return _decode(res);
  }

  Future<http.Response> _execute(Future<http.StreamedResponse> Function() send, {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      return await send().then(http.Response.fromStream).timeout(timeout);
    } on SocketException {
      _resetConnections();
      throw ApiException(0, 'network', 'No internet connection');
    } on TimeoutException {
      _resetConnections();
      throw ApiException(0, 'network', 'The connection is slow — please try again');
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
    if (_sessionEndingCodes.contains(ex.code) && !_quiet) onSessionEnded?.call(ex);
    throw ex;
  }

  // ------------------------------------------------------------------ files
  /// Uploads a file. kind: image | video | voice | file | avatar. Returns the media JSON.
  Future<Map<String, dynamic>> upload(
    String filePath, {
    required String kind,
    String? mime,
    String? filename,
    Map<String, String> fields = const {},
    bool retry = true,
  }) async {
    final file = File(filePath);
    final length = await file.length();
    if (length > 512 * 1024) {
      try {
        final session = await post('/media/uploads', {
          'size': length,
          'name': filename ?? file.uri.pathSegments.last,
          'mime': mime ?? lookupMimeType(filePath) ?? 'application/octet-stream',
          'fields': {'kind': kind, ...fields},
        }) as Map;
        return await _sendChunks(file, length, session['id'] as String);
      } on ApiException catch (e) {
        // Keep uploads compatible with servers running the previous API.
        if (e.status != 404) rethrow;
      }
    }
    final req = http.MultipartRequest('POST', uri('/media'));
    req.headers.addAll(authHeaders);
    req.fields['kind'] = kind;
    req.fields.addAll(fields);
    final type = mime ?? lookupMimeType(filePath) ?? 'application/octet-stream';
    req.files.add(await http.MultipartFile.fromPath('file', filePath, filename: filename, contentType: MediaType.parse(type)));
    final res = await _execute(() => _http.send(req), timeout: const Duration(minutes: 10));
    if (res.statusCode == 401 && retry && refreshToken != null) {
      await refreshTokens();
      return upload(filePath, kind: kind, mime: mime, filename: filename, fields: fields, retry: false);
    }
    return Map<String, dynamic>.from(_decode(res) as Map);
  }

  Future<Map<String, dynamic>> _sendChunks(File file, int length, String id) async {
    final input = await file.open();
    try {
      var offset = 0;
      while (offset < length) {
        await input.setPosition(offset);
        final remaining = length - offset;
        final bytes = await input.read(remaining < 524288 ? remaining : 524288);
        if (bytes.isEmpty) throw const FileSystemException('File changed during upload');
        for (var attempt = 0; ; attempt++) {
          try {
            await _freshen();
            final req = http.Request('PUT', uri('/media/uploads/$id', {'offset': '$offset'}));
            req.headers.addAll(authHeaders);
            req.headers['Content-Type'] = 'application/octet-stream';
            req.bodyBytes = bytes;
            final response = await _execute(() => _http.send(req), timeout: const Duration(minutes: 2));
            if (response.statusCode == 401 && attempt == 0 && refreshToken != null) {
              await refreshTokens();
              continue;
            }
            final body = _decode(response) as Map;
            if (body['media'] is Map) return Map<String, dynamic>.from(body['media'] as Map);
            final next = body['offset'];
            if (next is! int || next <= offset || next >= length) {
              throw ApiException(502, 'upload_offset', 'Unexpected upload position');
            }
            offset = next;
            break;
          } on ApiException catch (e) {
            if (attempt >= 4 || !(e.isNetwork || e.status == 409 || e.status == 503)) rethrow;
            await Future<void>.delayed(Duration(seconds: 1 << attempt));
          }
        }
      }
      throw ApiException(502, 'upload_incomplete', 'Upload could not be completed');
    } finally {
      await input.close();
    }
  }

  /// Downloads a protected file (e.g. /api/media/12) to [target].
  /// Downloads into [target]. Mobile data often drops a connection without closing it: if no bytes
  /// arrive for 20 s the download is dropped and tried again once on a fresh connection, instead of
  /// spinning for minutes. [onProgress] gets 0…1 while bytes come in (when the size is known).
  Future<File> download(String apiUrl, File target, {bool retry = true, void Function(double)? onProgress, http.Client? via}) async {
    await _freshen();
    final tmp = File('${target.path}.part');
    try {
      final req = http.Request('GET', Uri.parse(AppConfig.absolute(apiUrl)));
      req.headers.addAll(authHeaders);
      final streamed = await (via ?? _http).send(req).timeout(const Duration(seconds: 30));
      if (streamed.statusCode == 401 && retry && refreshToken != null) {
        await streamed.stream.drain<void>();
        await refreshTokens();
        return await download(apiUrl, target, retry: false, onProgress: onProgress, via: via);
      }
      if (streamed.statusCode != 200) {
        await streamed.stream.drain<void>();
        throw ApiException(streamed.statusCode, 'download_failed', 'Could not download the file');
      }
      final total = streamed.contentLength ?? 0;
      var got = 0;
      final sink = tmp.openWrite();
      try {
        await for (final chunk in streamed.stream.timeout(const Duration(seconds: 20))) {
          sink.add(chunk);
          got += chunk.length;
          if (onProgress != null && total > 0) onProgress((got / total).clamp(0.0, 1.0));
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && got < total) throw const SocketException('Download cut off');
      return await tmp.rename(target.path);
    } on ApiException {
      rethrow;
    } catch (_) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      if (!retry) rethrow;
      // the connection may be dead: try once more on a connection of its own. Resetting the shared one
      // would cut every other photo and request that is loading right now.
      final fresh = _newClient();
      try {
        return await download(apiUrl, target, retry: false, onProgress: onProgress, via: fresh);
      } finally {
        fresh.close();
      }
    }
  }

}
