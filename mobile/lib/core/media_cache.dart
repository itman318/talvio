import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'api_client.dart';

/// Downloads protected media once and keeps it in the app cache directory.
class MediaCache {
  MediaCache(this.api);

  final ApiClient api;
  final Map<int, Future<File>> _inflight = {};
  final Map<int, Future<File>> _previewInflight = {};
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

  File _previewFile(Directory dir, MediaInfo m) => File('${dir.path}/p${m.id}.webp');

  /// The bubble-size version of a photo, if it is already on the phone.
  Future<File?> cachedPreview(MediaInfo m) async {
    if (!m.hasPreview) return null;
    final f = _previewFile(await _cacheDir(), m);
    return await f.exists() ? f : null;
  }

  /// The best copy already on the phone (full photo, else its preview) — no network.
  Future<File?> best(MediaInfo m) async => await cached(m) ?? await cachedPreview(m);

  /// Bubble-size photo (a few dozen KB): the full photo when it is already here, else the preview.
  Future<File> preview(MediaInfo m) async {
    if (!m.hasPreview) return get(m);
    final full = await cached(m);
    if (full != null) return full;
    return _previewInflight[m.id] ??= () async {
      final target = _previewFile(await _cacheDir(), m);
      if (await target.exists()) return target;
      return api.download(m.previewUrl, target);
    }()
        .whenComplete(() {
      _previewInflight.remove(m.id);
    });
  }

  Future<int> sizeBytes() async {
    final dir = await _cacheDir();
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  Future<void> clear() async {
    final dir = await _cacheDir();
    if (await dir.exists()) await dir.delete(recursive: true);
    _dir = null;
  }

  /// Puts a file we just uploaded into the cache so we don't download it again.
  /// Deletes one cached file (view-once media after it was opened).
  Future<void> remove(MediaInfo m) async {
    try {
      final dir = await _cacheDir();
      for (final f in [File('${dir.path}/${_safeName(m)}'), _previewFile(dir, m)]) {
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }

  Future<void> putLocal(MediaInfo m, String localPath) async {
    try {
      final target = File('${(await _cacheDir()).path}/${_safeName(m)}');
      if (!await target.exists()) await File(localPath).copy(target.path);
    } catch (_) {
      // cache is best-effort
    }
  }
}
