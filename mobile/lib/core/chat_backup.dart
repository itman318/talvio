import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';

import '../config.dart';
import '../models/models.dart';
import 'services.dart';

/// Full account backup: every cloud chat (messages, optionally photos/files) in one file the user
/// saves anywhere — Google Drive, Downloads, a computer. Optionally locked with a password (AES-256-GCM).
/// Vault chats are never included: their keys must not leave this phone.
class ChatBackup {
  ChatBackup(this.services);
  final AppServices services;

  static const _magic = 'TLVB1';
  static const maxFileBytes = 25 * 1024 * 1024;
  static const maxMediaBytes = 300 * 1024 * 1024;
  static const maxMessagesPerChat = 20000;

  /// Builds the backup. [progress] gets (done, total, label).
  Future<Uint8List> create({
    required bool withMedia,
    String? password,
    void Function(int done, int total, String label)? progress,
  }) async {
    final api = services.api;
    final me = await api.get('/me');
    final chats = (await api.get('/chats') as List).cast<Map>().toList();
    try {
      chats.addAll((await api.get('/chats', query: {'archived': 'true'}) as List).cast<Map>());
    } catch (_) {}
    final archive = Archive();
    final index = <Map<String, dynamic>>[];
    var mediaBytes = 0;
    var skippedMedia = 0;
    for (var i = 0; i < chats.length; i++) {
      final c = Map<String, dynamic>.from(chats[i]);
      final chatId = (c['id'] as num).toInt();
      final title = '${c['title'] ?? ''}'.isNotEmpty ? '${c['title']}' : Chat.fromJson(c).title;
      progress?.call(i, chats.length, title);
      final msgs = <Map<String, dynamic>>[];
      int? before;
      while (msgs.length < maxMessagesPerChat) {
        final data = Map<String, dynamic>.from(await api.get('/chats/$chatId/messages', query: {
          'limit': '100',
          if (before != null) 'before': '$before',
        }) as Map);
        final batch = (data['messages'] as List).map((j) => Map<String, dynamic>.from(j as Map)).toList();
        if (batch.isEmpty) break;
        msgs.addAll(batch);
        before = batch.map((m) => (m['id'] as num).toInt()).reduce((a, b) => a < b ? a : b);
        if (data['has_more'] != true) break;
      }
      msgs.sort((a, b) => (a['id'] as num).compareTo(b['id'] as num));
      if (withMedia) {
        for (final m in msgs) {
          final media = m['media'];
          if (media is! Map || media['url'] == null) continue;
          final size = (media['size'] as num?)?.toInt() ?? 0;
          if (size > maxFileBytes || mediaBytes + size > maxMediaBytes) {
            skippedMedia++;
            continue;
          }
          try {
            final tmp = File('${Directory.systemTemp.path}/tlvb_${media['id']}');
            await api.download('${media['url']}', tmp);
            final bytes = await tmp.readAsBytes();
            await tmp.delete();
            final name = 'media/${media['id']}_${_safe('${media['name'] ?? 'file'}')}';
            archive.addFile(ArchiveFile(name, bytes.length, bytes));
            m['backup_file'] = name;
            mediaBytes += bytes.length;
          } catch (_) {
            skippedMedia++;
          }
        }
      }
      final file = 'chats/$chatId.json';
      final json = utf8.encode(jsonEncode({'chat': c, 'messages': msgs}));
      archive.addFile(ArchiveFile(file, json.length, json));
      index.add({'id': chatId, 'title': title, 'type': c['type'], 'messages': msgs.length, 'file': file});
    }
    progress?.call(chats.length, chats.length, 'Packing');
    final manifest = utf8.encode(jsonEncode({
      'app': AppConfig.appName,
      'version': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'account': me,
      'chats': index,
      'media_bytes': mediaBytes,
      'skipped_media': skippedMedia,
    }));
    archive.addFile(ArchiveFile('backup.json', manifest.length, manifest));
    final zip = Uint8List.fromList(ZipEncoder().encode(archive));
    if (password == null || password.isEmpty) return zip;
    return _encrypt(zip, password);
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[^\w\-. ]+'), '_');

  static Future<SecretKey> _key(String password, List<int> salt) => Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 120000, bits: 256)
      .deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  static Future<Uint8List> _encrypt(Uint8List plain, String password) async {
    final aes = AesGcm.with256bits();
    final salt = SecretKeyData.random(length: 16).bytes;
    final nonce = aes.newNonce();
    final box = await aes.encrypt(plain, secretKey: await _key(password, salt), nonce: nonce);
    return Uint8List.fromList([...utf8.encode(_magic), ...salt, ...nonce, ...box.mac.bytes, ...box.cipherText]);
  }

  static bool isEncrypted(Uint8List data) => data.length > 5 && utf8.decode(data.sublist(0, 5), allowMalformed: true) == _magic;

  /// Opens a backup file (asks for the password when it is locked).
  static Future<BackupContents> open(Uint8List data, {String? password}) async {
    var zip = data;
    if (isEncrypted(data)) {
      if (password == null || password.isEmpty) throw const BackupException('This backup is locked with a password');
      final salt = data.sublist(5, 21);
      final nonce = data.sublist(21, 33);
      final mac = data.sublist(33, 49);
      final cipher = data.sublist(49);
      try {
        zip = Uint8List.fromList(await AesGcm.with256bits().decrypt(SecretBox(cipher, nonce: nonce, mac: Mac(mac)), secretKey: await _key(password, salt)));
      } catch (_) {
        throw const BackupException('Wrong password');
      }
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zip);
    } catch (_) {
      throw const BackupException('This is not a Talvio backup');
    }
    final m = archive.findFile('backup.json');
    if (m == null) throw const BackupException('This is not a Talvio backup');
    return BackupContents(archive, Map<String, dynamic>.from(jsonDecode(utf8.decode(m.content as List<int>)) as Map));
  }
}

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BackupContents {
  BackupContents(this._archive, this.manifest);
  final Archive _archive;
  final Map<String, dynamic> manifest;

  List<Map<String, dynamic>> get chats => (manifest['chats'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  DateTime get createdAt => DateTime.parse('${manifest['created_at']}').toLocal();

  /// Messages of one chat, oldest first, each with its saved file (if the backup has one).
  List<(Message, String?)> messages(String file) {
    final f = _archive.findFile(file);
    if (f == null) return const [];
    final j = jsonDecode(utf8.decode(f.content as List<int>)) as Map;
    return (j['messages'] as List).map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      final local = m['backup_file'];
      return (Message.fromJson(m), local is String ? local : null);
    }).toList();
  }

  Uint8List? fileBytes(String name) {
    final f = _archive.findFile(name);
    return f == null ? null : Uint8List.fromList(f.content as List<int>);
  }
}
