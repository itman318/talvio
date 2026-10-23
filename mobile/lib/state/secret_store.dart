import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api_client.dart';
import '../core/e2e.dart';
import '../core/services.dart';
import '../core/socket_service.dart';
import '../models/models.dart';

/// Self-destruct timer choices (seconds). Must match the server's list.
const secretTtlValues = [0, 5, 10, 30, 60, 300, 3600, 86400, 604800];

String ttlLabel(int s) {
  if (s == 0) return 'Off';
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  if (s < 604800) return '${s ~/ 86400}d';
  return '1 week';
}

enum SecretSendState { sending, sent, delivered, read, failed }

class SecretMedia {
  int? mediaId;
  String kind; // image | file
  String name;
  String mime;
  int size;
  String key;
  String nonce;
  String? localPath; // decrypted copy on this phone

  SecretMedia({this.mediaId, required this.kind, required this.name, required this.mime, required this.size, required this.key, required this.nonce, this.localPath});

  Map<String, dynamic> wire() => {'kind': kind, 'name': name, 'mime': mime, 'size': size, 'key': key, 'nonce': nonce};
  Map<String, dynamic> toJson() => {...wire(), 'media_id': mediaId, 'path': localPath};
  factory SecretMedia.fromJson(Map<String, dynamic> j) => SecretMedia(
        mediaId: (j['media_id'] as num?)?.toInt(),
        kind: (j['kind'] ?? 'file') as String,
        name: (j['name'] ?? 'file') as String,
        mime: (j['mime'] ?? 'application/octet-stream') as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        key: j['key'] as String,
        nonce: j['nonce'] as String,
        localPath: j['path'] as String?,
      );
}

class SecretMessage {
  final String localId;
  int? serverId;
  final bool outgoing;
  final String kind; // text | media | service
  String text;
  SecretMedia? media;
  final int ttl;
  final DateTime sentAt;
  SecretSendState state;
  DateTime? expiresAt;
  String? ciphertext; // kept until the server confirms (for retries)

  SecretMessage({
    required this.localId,
    this.serverId,
    required this.outgoing,
    required this.kind,
    this.text = '',
    this.media,
    this.ttl = 0,
    required this.sentAt,
    this.state = SecretSendState.sent,
    this.expiresAt,
    this.ciphertext,
  });

  bool get isService => kind == 'service';

  String get preview {
    if (kind == 'media') return media?.kind == 'image' ? '📷 Photo' : '📎 ${media?.name ?? 'File'}';
    return text;
  }

  Map<String, dynamic> toJson() => {
        'lid': localId,
        'sid': serverId,
        'out': outgoing,
        'k': kind,
        't': text,
        'm': media?.toJson(),
        'ttl': ttl,
        'at': sentAt.toIso8601String(),
        'st': state.index,
        'exp': expiresAt?.toIso8601String(),
        'ct': ciphertext,
      };

  factory SecretMessage.fromJson(Map<String, dynamic> j) => SecretMessage(
        localId: j['lid'] as String,
        serverId: (j['sid'] as num?)?.toInt(),
        outgoing: j['out'] == true,
        kind: (j['k'] ?? 'text') as String,
        text: (j['t'] ?? '') as String,
        media: j['m'] == null ? null : SecretMedia.fromJson(Map<String, dynamic>.from(j['m'] as Map)),
        ttl: (j['ttl'] as num?)?.toInt() ?? 0,
        sentAt: DateTime.parse(j['at'] as String),
        state: SecretSendState.values[((j['st'] as num?)?.toInt() ?? 1).clamp(0, SecretSendState.values.length - 1)],
        expiresAt: j['exp'] == null ? null : DateTime.parse(j['exp'] as String),
        ciphertext: j['ct'] as String?,
      );
}

class SecretChat {
  final int id;
  String status; // requested | active | closed
  final bool isInitiator;
  final int peerId;
  AppUser? peer;
  int ttl;
  int unread;
  String? fingerprint;
  String? closeReason;
  DateTime lastActivity;

  SecretChat({
    required this.id,
    required this.status,
    required this.isInitiator,
    required this.peerId,
    this.peer,
    this.ttl = 0,
    this.unread = 0,
    this.fingerprint,
    this.closeReason,
    required this.lastActivity,
  });

  String get title => peer?.name ?? 'Vault chat';
  bool get isActive => status == 'active';

  Map<String, dynamic> toJson() => {
        'id': id,
        'status': status,
        'init': isInitiator,
        'peer_id': peerId,
        'peer': peer == null
            ? null
            : {'id': peer!.id, 'first_name': peer!.firstName, 'last_name': peer!.lastName, 'username': peer!.username, 'avatar_url': peer!.avatarUrl},
        'ttl': ttl,
        'unread': unread,
        'fp': fingerprint,
        'close': closeReason,
        'last': lastActivity.toIso8601String(),
      };

  factory SecretChat.fromJson(Map<String, dynamic> j) => SecretChat(
        id: (j['id'] as num).toInt(),
        status: (j['status'] ?? 'active') as String,
        isInitiator: j['init'] == true,
        peerId: (j['peer_id'] as num).toInt(),
        peer: j['peer'] == null ? null : AppUser.fromJson(Map<String, dynamic>.from(j['peer'] as Map)),
        ttl: (j['ttl'] as num?)?.toInt() ?? 0,
        unread: (j['unread'] as num?)?.toInt() ?? 0,
        fingerprint: j['fp'] as String?,
        closeReason: j['close'] as String?,
        lastActivity: DateTime.tryParse('${j['last']}') ?? DateTime.now(),
      );
}

/// Secret chats on this phone: keys in secure storage, history encrypted on disk, ciphertext over the wire.
class SecretStore extends ChangeNotifier {
  SecretStore(this.services);

  final AppServices services;
  static const _secure = FlutterSecureStorage();

  final Map<int, SecretChat> chats = {};
  final Map<int, List<SecretMessage>> messages = {}; // newest first
  final Map<int, RatchetState> _keys = {};
  final Map<int, DateTime> typingUntil = {};
  int? openChatId;

  StreamSubscription<SocketEvent>? _sub;
  StreamSubscription<bool>? _connSub;
  List<int>? _storeKey;
  Timer? _saveTimer;
  Timer? _expiryTimer;
  bool _started = false;
  Future<void> _queue = Future.value(); // serialises decryption (ratchet state must not race)

  List<SecretChat> get sortedChats => chats.values.toList()..sort((a, b) => b.lastActivity.compareTo(a.lastActivity));

  /// Each account on this phone has its own secret chats (keys + history are namespaced by user id).
  String _ns = 'none';

  Future<void> start(int userId) async {
    if (_started && _ns == '$userId') return;
    if (_started) await suspend();
    _ns = '$userId';
    _started = true;
    await _loadLocal();
    _sub = services.socket.events.listen(_onEvent);
    _connSub = services.socket.connectionChanges.listen((up) {
      if (up) sync();
    });
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) => _expire());
    sync();
  }

  /// Switching accounts: forget this account's chats in memory, keep them on disk.
  Future<void> suspend() async {
    await stop();
    _saveTimer?.cancel();
    if (_ns != 'none') await _saveLocal();
    chats.clear();
    messages.clear();
    _keys.clear();
    typingUntil.clear();
    _storeKey = null;
    notifyListeners();
  }

  Future<void> stop() async {
    _started = false;
    await _sub?.cancel();
    await _connSub?.cancel();
    _expiryTimer?.cancel();
  }

  // ------------------------------------------------------------------ server sync
  Future<void> sync() async {
    try {
      final list = await services.api.get('/secret-chats') as List;
      final seen = <int>{};
      for (final raw in list) {
        final j = Map<String, dynamic>.from(raw as Map);
        final id = (j['id'] as num).toInt();
        seen.add(id);
        await _applyServerChat(j);
      }
      // chats the server no longer lists for this device (expired long ago)
      for (final c in chats.values.where((c) => !seen.contains(c.id) && c.status != 'closed').toList()) {
        c.status = 'closed';
      }
      final pending = await services.api.get('/secret-chats/pending') as List;
      for (final m in pending) {
        await _receive(Map<String, dynamic>.from(m as Map));
      }
      _changed();
    } catch (e) {
      debugPrint('secret sync failed: $e');
    }
  }

  Future<void> _applyServerChat(Map<String, dynamic> j) async {
    final id = (j['id'] as num).toInt();
    final status = j['status'] as String;
    final initiator = j['is_initiator'] == true;
    final existing = chats[id];
    if (status == 'closed') {
      if (existing != null && existing.status != 'closed') {
        existing.status = 'closed';
        existing.closeReason = j['close_reason'] as String?;
      }
      return;
    }
    if (status == 'requested' && !initiator) {
      if (_keys[id] == null) await _accept(j);
      return;
    }
    final keys = _keys[id];
    if (keys == null) {
      // keys lost (app reinstalled) — this chat can never be read again
      services.socket.request('secret:close', {'secret_chat_id': id}).catchError((_) => <String, dynamic>{});
      return;
    }
    final c = existing ?? _chatFrom(j);
    c.peer = j['peer'] == null ? c.peer : AppUser.fromJson(Map<String, dynamic>.from(j['peer'] as Map));
    chats[id] = c;
    if (status == 'active' && !keys.ready && j['their_key'] != null) await _finishHandshake(id, j['their_key'] as String);
    c.status = status;
  }

  SecretChat _chatFrom(Map<String, dynamic> j) => SecretChat(
        id: (j['id'] as num).toInt(),
        status: j['status'] as String,
        isInitiator: j['is_initiator'] == true,
        peerId: (j['peer_id'] as num).toInt(),
        peer: j['peer'] == null ? null : AppUser.fromJson(Map<String, dynamic>.from(j['peer'] as Map)),
        lastActivity: DateTime.now(),
      );

  // ------------------------------------------------------------------ handshake
  /// Starts a secret chat with [user]. It becomes usable when their phone comes online.
  Future<SecretChat> create(AppUser user) async {
    final (priv, pub) = await E2E.newKeyPair();
    final r = await services.socket.request('secret:create', {'user_id': user.id, 'public_key': pub});
    final j = Map<String, dynamic>.from(r['secret_chat'] as Map);
    final id = (j['id'] as num).toInt();
    final state = RatchetState(chatId: id, isInitiator: true, myPrivate: priv, myPublic: pub);
    _keys[id] = state;
    await _saveKeys(state);
    final c = _chatFrom(j)..peer = user;
    chats[id] = c;
    messages[id] = [];
    _service(id, 'You invited ${user.firstName} to a vault chat. Waiting for their phone to come online…');
    _changed();
    return c;
  }

  Future<void> _accept(Map<String, dynamic> j) async {
    final id = (j['id'] as num).toInt();
    final (priv, pub) = await E2E.newKeyPair();
    try {
      await services.socket.request('secret:accept', {'secret_chat_id': id, 'public_key': pub});
    } on ApiException catch (e) {
      if (e.code == 'accepted_elsewhere' || e.code == 'secret_chat_closed') return;
      rethrow;
    }
    final state = RatchetState(chatId: id, isInitiator: false, myPrivate: priv, myPublic: pub, theirPublic: j['their_key'] as String?);
    _keys[id] = state;
    final c = _chatFrom(j)..status = 'active';
    chats[id] = c;
    messages[id] ??= [];
    await _finishHandshake(id, j['their_key'] as String);
    _service(id, '${c.peer?.firstName ?? 'Someone'} started a vault chat with you.');
    _changed();
  }

  Future<void> _finishHandshake(int id, String theirKey) async {
    final s = _keys[id];
    if (s == null) return;
    final k = await E2E.derive(chatId: id, isInitiator: s.isInitiator, myPrivate: s.myPrivate, myPublic: s.myPublic, theirPublic: theirKey);
    final ready = RatchetState(
      chatId: id,
      isInitiator: s.isInitiator,
      myPrivate: s.myPrivate,
      myPublic: s.myPublic,
      theirPublic: theirKey,
      sendChain: k.sendChain,
      recvChain: k.recvChain,
      fingerprint: k.fingerprint,
    );
    _keys[id] = ready;
    await _saveKeys(ready);
    final c = chats[id];
    if (c != null) {
      c.fingerprint = k.fingerprint;
      c.status = 'active';
    }
  }

  // ------------------------------------------------------------------ events
  void _onEvent(SocketEvent e) {
    final d = e.data;
    int? cid() => (d['secret_chat_id'] as num?)?.toInt();
    switch (e.name) {
      case 'secret:request':
        final j = Map<String, dynamic>.from(d['secret_chat'] as Map);
        _enqueue(() => _accept(j));
        break;
      case 'secret:accepted':
        final j = Map<String, dynamic>.from(d['secret_chat'] as Map);
        _enqueue(() async {
          final id = (j['id'] as num).toInt();
          if (_keys[id] == null) return;
          await _finishHandshake(id, j['their_key'] as String);
          _service(id, '${chats[id]?.peer?.firstName ?? 'They'} joined your vault chat.');
          _changed();
        });
        break;
      case 'secret:taken':
        final id = cid();
        if (id != null && _keys[id] == null && chats.containsKey(id)) {
          chats.remove(id);
          _changed();
        }
        break;
      case 'secret:closed':
        final id = cid();
        final c = id == null ? null : chats[id];
        if (c != null && c.status != 'closed') {
          c.status = 'closed';
          c.closeReason = d['reason'] as String?;
          _service(c.id, d['reason'] == 'declined' ? 'Vault chat was declined.' : 'This vault chat was closed.');
          _changed();
        }
        break;
      case 'secret:message':
        final m = Map<String, dynamic>.from(d['message'] as Map);
        _enqueue(() => _receive(m));
        break;
      case 'secret:delivered':
        final ids = ((d['message_ids'] as List?) ?? []).map((x) => (x as num).toInt()).toSet();
        for (final m in messages[cid()] ?? <SecretMessage>[]) {
          if (m.outgoing && ids.contains(m.serverId) && m.state.index < SecretSendState.delivered.index) m.state = SecretSendState.delivered;
        }
        _changed();
        break;
      case 'secret:read':
        final maxId = (d['max_id'] as num?)?.toInt() ?? 0;
        final now = DateTime.now();
        for (final m in messages[cid()] ?? <SecretMessage>[]) {
          if (m.outgoing && (m.serverId ?? 1 << 62) <= maxId && m.state != SecretSendState.read) {
            m.state = SecretSendState.read;
            if (m.ttl > 0) m.expiresAt ??= now.add(Duration(seconds: m.ttl));
          }
        }
        _changed();
        break;
      case 'secret:typing':
        final id = cid();
        if (id != null) {
          typingUntil[id] = DateTime.now().add(const Duration(seconds: 5));
          notifyListeners();
        }
        break;
      case 'secret:deleted':
        final ids = ((d['message_ids'] as List?) ?? []).map((x) => (x as num).toInt()).toSet();
        final list = messages[cid()];
        if (list != null) {
          for (final m in list.where((m) => ids.contains(m.serverId))) {
            _deleteFile(m);
          }
          list.removeWhere((m) => ids.contains(m.serverId));
          _changed();
        }
        break;
    }
  }

  void _enqueue(Future<void> Function() job) {
    _queue = _queue.then((_) => job()).catchError((Object e) => debugPrint('secret error: $e'));
  }

  Future<void> _receive(Map<String, dynamic> m) async {
    final id = (m['secret_chat_id'] as num).toInt();
    final serverId = (m['id'] as num).toInt();
    final state = _keys[id];
    final chat = chats[id];
    if (state == null || !state.ready || chat == null) return;
    final list = messages.putIfAbsent(id, () => []);
    if (list.any((x) => !x.outgoing && x.serverId == serverId)) {
      _ack(id, [serverId]);
      return;
    }
    Map<String, dynamic>? plain;
    try {
      plain = await E2E.decrypt(state, m['ciphertext'] as String);
      await _saveKeys(state);
    } catch (e) {
      list.insert(0, SecretMessage(localId: 's$serverId', serverId: serverId, outgoing: false, kind: 'service', text: '⚠️ A message could not be decrypted', sentAt: DateTime.now()));
      _ack(id, [serverId]);
      _changed();
      return;
    }
    _ack(id, [serverId]);
    if (plain == null) return;
    final ttl = (m['ttl_sec'] as num?)?.toInt() ?? 0;
    final at = DateTime.tryParse('${m['created_at']}')?.toLocal() ?? DateTime.now();
    switch (plain['k']) {
      case 'ttl':
        chat.ttl = (plain['ttl'] as num?)?.toInt() ?? 0;
        _service(id, chat.ttl == 0 ? '${chat.peer?.firstName ?? 'They'} turned off the self-destruct timer' : '${chat.peer?.firstName ?? 'They'} set messages to disappear after ${ttlLabel(chat.ttl)}');
        break;
      case 'screenshot':
        _service(id, '${chat.peer?.firstName ?? 'They'} took a screenshot');
        break;
      default:
        final mediaJson = plain['media'];
        final msg = SecretMessage(
          localId: 's$serverId',
          serverId: serverId,
          outgoing: false,
          kind: mediaJson is Map ? 'media' : 'text',
          text: '${plain['text'] ?? ''}',
          media: mediaJson is Map ? (SecretMedia.fromJson(Map<String, dynamic>.from(mediaJson))..mediaId = (m['media_id'] as num?)?.toInt()) : null,
          ttl: ttl,
          sentAt: at,
        );
        list.insert(0, msg);
        chat.lastActivity = DateTime.now();
        if (openChatId == id) {
          _markRead(id);
        } else {
          chat.unread += 1;
        }
    }
    _changed();
  }

  void _ack(int chatId, List<int> ids) {
    services.socket.request('secret:ack', {'secret_chat_id': chatId, 'message_ids': ids}).catchError((_) {
      return services.api.post('/secret-chats/$chatId/ack', {'message_ids': ids}).then((_) => <String, dynamic>{});
    }).catchError((_) => <String, dynamic>{});
  }

  // ------------------------------------------------------------------ sending
  Future<void> sendText(int chatId, String text) => _send(chatId, {'k': 'text', 'text': text}, kind: 'text', text: text);

  /// Encrypts the file on the phone, uploads the encrypted blob, then sends its key inside the message.
  Future<void> sendFile(int chatId, String path, {required bool image}) async {
    final f = File(path);
    final bytes = await f.readAsBytes();
    final (enc, key, nonce) = await E2E.encryptFile(bytes);
    final dir = await getTemporaryDirectory();
    final tmp = File('${dir.path}/secret-up-${DateTime.now().microsecondsSinceEpoch}.bin');
    await tmp.writeAsBytes(enc, flush: true);
    final name = path.split(Platform.pathSeparator).last;
    final media = SecretMedia(
      kind: image ? 'image' : 'file',
      name: name,
      mime: lookupMimeType(path) ?? 'application/octet-stream',
      size: bytes.length,
      key: key,
      nonce: nonce,
    );
    // keep a decrypted copy for ourselves
    final keep = await _mediaFile(chatId, 'out-${DateTime.now().microsecondsSinceEpoch}-$name');
    await keep.writeAsBytes(bytes, flush: true);
    media.localPath = keep.path;
    try {
      final up = await services.api.upload(tmp.path, kind: 'file', mime: 'application/octet-stream');
      media.mediaId = (up['id'] as num).toInt();
    } finally {
      tmp.delete().catchError((_) => tmp);
    }
    await _send(chatId, {'k': 'media', 'media': media.wire()}, kind: 'media', media: media);
  }

  Future<void> setTtl(int chatId, int ttl) async {
    final c = chats[chatId];
    if (c == null) return;
    c.ttl = ttl;
    _service(chatId, ttl == 0 ? 'You turned off the self-destruct timer' : 'You set messages to disappear after ${ttlLabel(ttl)}');
    await _send(chatId, {'k': 'ttl', 'ttl': ttl}, kind: 'service', silentLocal: true);
  }

  Future<void> _send(int chatId, Map<String, dynamic> plain, {required String kind, String text = '', SecretMedia? media, bool silentLocal = false}) async {
    final c = chats[chatId];
    final state = _keys[chatId];
    if (c == null || state == null || !state.ready || !c.isActive) throw ApiException(400, 'secret_not_ready', 'This vault chat is not ready yet');
    final ttl = kind == 'service' ? 0 : c.ttl;
    plain['ts'] = DateTime.now().millisecondsSinceEpoch;
    late String ct;
    final done = Completer<void>();
    _enqueue(() async {
      try {
        ct = await E2E.encrypt(state, plain);
        await _saveKeys(state); // never reuse a message key, even if the app dies now
        done.complete();
      } catch (e) {
        done.completeError(e);
      }
    });
    await done.future;
    final msg = SecretMessage(
      localId: 'l${DateTime.now().microsecondsSinceEpoch}',
      outgoing: true,
      kind: kind,
      text: text,
      media: media,
      ttl: ttl,
      sentAt: DateTime.now(),
      state: SecretSendState.sending,
      ciphertext: ct,
    );
    if (!silentLocal) {
      messages.putIfAbsent(chatId, () => []).insert(0, msg);
      c.lastActivity = DateTime.now();
      _changed();
    }
    await _push(chatId, msg);
  }

  Future<void> _push(int chatId, SecretMessage msg) async {
    try {
      final r = await services.socket.request('secret:send', {
        'secret_chat_id': chatId,
        'ciphertext': msg.ciphertext,
        'ttl_sec': msg.ttl,
        'client_id': msg.localId,
        if (msg.media?.mediaId != null) 'media_id': msg.media!.mediaId,
      });
      msg.serverId = ((r['message'] as Map)['id'] as num).toInt();
      if (msg.state == SecretSendState.sending || msg.state == SecretSendState.failed) msg.state = SecretSendState.sent;
      msg.ciphertext = null;
    } catch (e) {
      msg.state = SecretSendState.failed;
    }
    _changed();
  }

  Future<void> retry(int chatId, SecretMessage m) async {
    if (m.ciphertext == null) return;
    m.state = SecretSendState.sending;
    _changed();
    await _push(chatId, m);
  }

  // ------------------------------------------------------------------ reading, typing, media
  void openChat(int? chatId) {
    openChatId = chatId;
    if (chatId != null) _markRead(chatId);
  }

  void _markRead(int chatId) {
    final c = chats[chatId];
    final list = messages[chatId] ?? [];
    if (c == null) return;
    c.unread = 0;
    int? maxId;
    final now = DateTime.now();
    for (final m in list) {
      if (m.outgoing || m.serverId == null) continue;
      if (maxId == null || m.serverId! > maxId) maxId = m.serverId;
      if (m.ttl > 0 && m.expiresAt == null) m.expiresAt = now.add(Duration(seconds: m.ttl));
    }
    if (maxId != null && c.isActive) {
      services.socket.request('secret:read', {'secret_chat_id': chatId, 'max_id': maxId}).catchError((_) => <String, dynamic>{});
    }
    _changed();
  }

  void sendTyping(int chatId) {
    if (chats[chatId]?.isActive != true) return;
    services.socket.emit('secret:typing', {'secret_chat_id': chatId});
  }

  bool isTyping(int chatId) => (typingUntil[chatId]?.isAfter(DateTime.now())) ?? false;

  /// Downloads + decrypts a received file (once). Returns the local path.
  Future<String> loadMedia(int chatId, SecretMessage m) async {
    final media = m.media!;
    final existing = media.localPath;
    if (existing != null && await File(existing).exists()) return existing;
    if (media.mediaId == null) throw ApiException(404, 'media_not_found', 'File not available');
    final dir = await getTemporaryDirectory();
    final tmp = File('${dir.path}/secret-down-${media.mediaId}.bin');
    await services.api.download('/api/media/${media.mediaId}', tmp);
    final plain = await E2E.decryptFile(await tmp.readAsBytes(), media.key, media.nonce);
    await tmp.delete().catchError((_) => tmp);
    final out = await _mediaFile(chatId, 'in-${m.serverId}-${media.name}');
    await out.writeAsBytes(plain, flush: true);
    media.localPath = out.path;
    _changed();
    return out.path;
  }

  Future<File> _mediaFile(int chatId, String name) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/secret/$_ns/$chatId');
    await dir.create(recursive: true);
    return File('${dir.path}/${name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}');
  }

  void _deleteFile(SecretMessage m) {
    final p = m.media?.localPath;
    if (p != null) File(p).delete().catchError((_) => File(p));
  }

  // ------------------------------------------------------------------ deleting / closing
  Future<void> deleteMessages(int chatId, List<SecretMessage> list, {bool forBoth = true}) async {
    final ids = list.map((m) => m.serverId).whereType<int>().toList();
    if (forBoth && ids.isNotEmpty && chats[chatId]?.isActive == true) {
      await services.socket.request('secret:delete', {'secret_chat_id': chatId, 'message_ids': ids}).catchError((_) => <String, dynamic>{});
    }
    for (final m in list) {
      _deleteFile(m);
    }
    final set = list.map((m) => m.localId).toSet();
    messages[chatId]?.removeWhere((m) => set.contains(m.localId));
    _changed();
  }

  /// Closes the chat for both people and wipes it (keys, messages, files) from this phone.
  Future<void> closeAndDelete(int chatId) async {
    if (chats[chatId]?.status != 'closed') {
      await services.socket.request('secret:close', {'secret_chat_id': chatId}).catchError((_) => <String, dynamic>{});
    }
    await _wipeChat(chatId);
    _changed();
  }

  Future<void> _wipeChat(int chatId) async {
    for (final m in messages[chatId] ?? <SecretMessage>[]) {
      _deleteFile(m);
    }
    messages.remove(chatId);
    chats.remove(chatId);
    _keys.remove(chatId);
    await _secure.delete(key: '${_ns}_secret_keys_$chatId');
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/secret/$_ns/$chatId');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Logout: secret chats belong to this device and end with it.
  Future<void> wipeAll() async {
    await stop();
    for (final id in chats.keys.toList()) {
      await _wipeChat(id);
    }
    chats.clear();
    messages.clear();
    _keys.clear();
    await _secure.delete(key: '${_ns}_secret_store_key');
    try {
      final base = await getApplicationSupportDirectory();
      final f = File('${base.path}/secret/$_ns/index.bin');
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _storeKey = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ self-destruct
  void _expire() {
    final now = DateTime.now();
    var changed = false;
    for (final entry in messages.entries) {
      final gone = entry.value.where((m) => m.expiresAt != null && m.expiresAt!.isBefore(now)).toList();
      if (gone.isEmpty) continue;
      for (final m in gone) {
        _deleteFile(m);
      }
      entry.value.removeWhere((m) => gone.contains(m));
      changed = true;
    }
    if (changed) {
      _changed();
    } else if (messages.values.any((l) => l.any((m) => m.expiresAt != null))) {
      notifyListeners(); // countdown labels
    }
  }

  void _service(int chatId, String text) {
    messages.putIfAbsent(chatId, () => []).insert(
          0,
          SecretMessage(localId: 'v${DateTime.now().microsecondsSinceEpoch}', outgoing: false, kind: 'service', text: text, sentAt: DateTime.now()),
        );
  }

  // ------------------------------------------------------------------ local persistence
  Future<List<int>> _key() async {
    if (_storeKey != null) return _storeKey!;
    var k = await _secure.read(key: '${_ns}_secret_store_key');
    if (k == null) {
      k = base64Encode(E2E.randomBytes(32));
      await _secure.write(key: '${_ns}_secret_store_key', value: k);
    }
    return _storeKey = base64Decode(k);
  }

  Future<void> _saveKeys(RatchetState s) => _secure.write(key: '${_ns}_secret_keys_${s.chatId}', value: jsonEncode(s.toJson()));

  Future<void> _loadLocal() async {
    try {
      final base = await getApplicationSupportDirectory();
      final f = File('${base.path}/secret/$_ns/index.bin');
      if (!await f.exists()) return;
      final data = jsonDecode(utf8.decode(await E2E.openLocal(await _key(), await f.readAsBytes()))) as Map<String, dynamic>;
      for (final c in (data['chats'] as List? ?? [])) {
        final chat = SecretChat.fromJson(Map<String, dynamic>.from(c as Map));
        chats[chat.id] = chat;
        final raw = await _secure.read(key: '${_ns}_secret_keys_${chat.id}');
        if (raw != null) _keys[chat.id] = RatchetState.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
      }
      final msgs = Map<String, dynamic>.from((data['messages'] as Map?) ?? {});
      msgs.forEach((k, v) {
        messages[int.parse(k)] = (v as List).map((m) => SecretMessage.fromJson(Map<String, dynamic>.from(m as Map))).toList();
      });
      notifyListeners();
    } catch (e) {
      debugPrint('secret load failed: $e');
    }
  }

  void _changed() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _saveLocal);
  }

  Future<void> _saveLocal() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/secret/$_ns');
      await dir.create(recursive: true);
      final data = {
        'chats': chats.values.map((c) => c.toJson()).toList(),
        'messages': messages.map((k, v) => MapEntry('$k', v.take(2000).map((m) => m.toJson()).toList())),
      };
      final sealed = await E2E.sealLocal(await _key(), utf8.encode(jsonEncode(data)));
      final tmp = File('${dir.path}/index.tmp');
      await tmp.writeAsBytes(sealed, flush: true);
      await tmp.rename('${dir.path}/index.bin');
    } catch (e) {
      debugPrint('secret save failed: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _connSub?.cancel();
    _expiryTimer?.cancel();
    _saveTimer?.cancel();
    super.dispose();
  }
}
