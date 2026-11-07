import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import 'api_client.dart';

/// What the server said about a newer build.
class UpdateInfo {
  UpdateInfo(this.j);
  final Map<String, dynamic> j;
  bool get available => j['update'] == true;
  bool get force => j['force'] == true;
  int get build => (j['latest_build'] as num?)?.toInt() ?? 0;
  String get version => '${j['version'] ?? ''}';
  String get url => '${j['url'] ?? ''}';
  int get size => (j['size'] as num?)?.toInt() ?? 0;
  String? get sha256 => j['sha256'] as String?;
  String get notes => '${j['notes'] ?? ''}'.trim();
}

enum UpdateStage { idle, downloading, verifying, ready, failed }

/// In-app updates (no Play Store yet): asks our server for the newest build, downloads the APK
/// for this phone's CPU with progress, checks its size and checksum, then opens Android's installer.
class AppUpdater extends ChangeNotifier {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  UpdateInfo? info;
  UpdateStage stage = UpdateStage.idle;
  double progress = 0; // 0..1
  String? error;
  File? _apk;
  DateTime? _lastCheck;
  http.Client? _client;

  /// This app's build number (1.1.<N>); 0 for a developer build.
  static int get currentBuild {
    final parts = AppConfig.appVersion.split('.');
    return parts.length == 3 ? int.tryParse(parts[2]) ?? 0 : 0;
  }

  static Future<String> _abi() async {
    try {
      final a = await DeviceInfoPlugin().androidInfo;
      return a.supportedAbis.isNotEmpty ? a.supportedAbis.first : 'arm64-v8a';
    } catch (_) {
      return 'arm64-v8a';
    }
  }

  bool get hasUpdate => info?.available == true;

  /// Asks the server (at most every 3 hours unless [force]). Never throws.
  Future<UpdateInfo?> check(ApiClient api, {bool force = false}) async {
    if (!Platform.isAndroid || currentBuild == 0) return null;
    if (!force && _lastCheck != null && DateTime.now().difference(_lastCheck!) < const Duration(hours: 3)) return info;
    _lastCheck = DateTime.now();
    try {
      final r = await api.get('/app/update', query: {'build': '$currentBuild', 'abi': await _abi()});
      info = UpdateInfo(Map<String, dynamic>.from(r as Map));
      notifyListeners();
    } catch (_) {}
    return info;
  }

  Future<File> _target(UpdateInfo i) async {
    final dir = Directory('${(await getApplicationCacheDirectory()).path}/updates');
    await dir.create(recursive: true);
    // old downloads go
    await for (final e in dir.list()) {
      if (e is File && !e.path.endsWith('hushavia-${i.build}.apk')) await e.delete().catchError((_) => e);
    }
    return File('${dir.path}/hushavia-${i.build}.apk');
  }

  /// Downloads (or reuses an already-checked file) and opens the installer.
  Future<void> downloadAndInstall() async {
    final i = info;
    if (i == null || !i.available || stage == UpdateStage.downloading || stage == UpdateStage.verifying) return;
    error = null;
    try {
      final file = await _target(i);
      if (!(stage == UpdateStage.ready && _apk?.path == file.path && await file.exists())) {
        await _download(i, file);
        stage = UpdateStage.verifying;
        notifyListeners();
        await _verify(i, file);
        _apk = file;
      }
      stage = UpdateStage.ready;
      notifyListeners();
      await install();
    } catch (e) {
      stage = UpdateStage.failed;
      error = e is _UpdateError ? e.message : 'Download failed — check your internet and try again';
      notifyListeners();
    }
  }

  Future<void> _download(UpdateInfo i, File file) async {
    stage = UpdateStage.downloading;
    progress = 0;
    notifyListeners();
    final part = File('${file.path}.part');
    final client = _client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(i.url))).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw _UpdateError('The update isn’t available right now (${res.statusCode})');
      final total = res.contentLength ?? i.size;
      var got = 0;
      var lastShown = 0.0;
      final sink = part.openWrite();
      try {
        await for (final chunk in res.stream.timeout(const Duration(seconds: 45))) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            progress = (got / total).clamp(0.0, 1.0);
            if (progress - lastShown >= 0.01) {
              lastShown = progress;
              notifyListeners();
            }
          }
        }
      } finally {
        await sink.close();
      }
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
    } finally {
      client.close();
      _client = null;
    }
  }

  Future<void> _verify(UpdateInfo i, File file) async {
    final len = await file.length();
    if (i.size > 0 && len != i.size) {
      await file.delete();
      throw _UpdateError('The download was incomplete — please try again');
    }
    final want = i.sha256;
    if (want != null && want.isNotEmpty) {
      final got = await compute(_sha256Of, file.path);
      if (got != want.toLowerCase()) {
        await file.delete();
        throw _UpdateError('The download was damaged — please try again');
      }
    }
  }

  static Future<String> _sha256Of(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

  Future<void> install() async {
    final f = _apk;
    if (f == null) return;
    final r = await OpenFilex.open(f.path, type: 'application/vnd.android.package-archive');
    if (r.type == ResultType.permissionDenied) {
      error = 'Allow “Install unknown apps” for Hushavia, then tap Install again';
      notifyListeners();
    } else if (r.type != ResultType.done) {
      error = 'Couldn’t open the installer (${r.message})';
      notifyListeners();
    }
  }

  void cancel() {
    _client?.close();
  }
}

class _UpdateError implements Exception {
  _UpdateError(this.message);
  final String message;
}
