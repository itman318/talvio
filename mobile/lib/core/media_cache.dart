import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'api_client.dart';

/// Downloads protected media once and keeps it in the app cache directory.
class MediaCache {
  MediaCache(this.api);

  final ApiClient api;
  final Map<int, Future<File>> _inflight = {};
  Directory? _dir;

  Future<Directory> _cacheDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationCacheDirectory();
    _dir = Directory('${base.path}/media');
    await _dir!.create(recursive: true);
    return _dir!;
  }

  String _safeName(MediaInfo m) {
    final name = m.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '${m.id}_${name.isEmpty ? 'file' : name}';
  }

  /// Returns the local file if it is already cached.
  Future<File?> cached(MediaInfo m) async {
    final f = File('${(await _cacheDir()).path}/${_safeName(m)}');
    return await f.exists() ? f : null;
  }

  Future<File> get(MediaInfo m) {
    // Block body on purpose: returning the removed Future from whenComplete would make it wait on itself.
    return _inflight[m.id] ??= _load(m).whenComplete(() {
      _inflight.remove(m.id);
    });
  }

  Future<File> _load(MediaInfo m) async {
    final existing = await cached(m);
    if (existing != null) return existing;
    final target = File('${(await _cacheDir()).path}/${_safeName(m)}');
    return api.download(m.url, target);
  }

  /// Puts a file we just uploaded into the cache so we don't download it again.
  Future<void> putLocal(MediaInfo m, String localPath) async {
    try {
      final target = File('${(await _cacheDir()).path}/${_safeName(m)}');
      if (!await target.exists()) await File(localPath).copy(target.path);
    } catch (_) {
      // cache is best-effort
    }
  }
}
