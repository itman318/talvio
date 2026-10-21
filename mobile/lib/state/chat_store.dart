import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/services.dart';
import '../core/socket_service.dart';
import '../models/models.dart';

/// Holds chats, loaded messages, typing & presence, and handles realtime events.
class ChatStore extends ChangeNotifier {
  ChatStore(this.services);

  final AppServices services;
  ApiClient get api => services.api;
  SocketService get socket => services.socket;

  int? myId;
  List<Chat> chats = [];
  bool chatsLoaded = false;
  bool connected = false;
  int? activeChatId;
  bool appInForeground = true;
  void Function()? onSessionRevoked;

  final Map<int, List<Message>> _messages = {}; // newest first
  final Map<int, bool> _hasMore = {};
  final Set<int> _loadingMore = {};
  final Map<int, Map<int, DateTime>> _typing = {}; // chatId -> userId -> expiry
  final Map<int, DateTime> _typingSent = {};
  final Map<int, int> _lastReadSent = {};
  final Map<int, AppUser> userCache = {};
  final Map<int, List<GroupMember>> members = {};
  List<ChatFolder> folders = [];
  List<StoryGroup> stories = [];
  List<Announcement> announcements = [];
  final Map<int, Set<int>> _viewsSent = {};

  /// Bumped whenever an admin answers a support ticket (screens listen and refresh).
  final supportUpdates = ValueNotifier<int>(0);

  StreamSubscription<SocketEvent>? _eventSub;
  StreamSubscription<bool>? _connSub;
  Timer? _typingTimer;
  int _localId = -1;
  final _rand = Random();

  // ------------------------------------------------------------------ lifecycle
  void start(int meId) {
    stop();
    myId = meId;
    connected = socket.isConnected;
    _eventSub = socket.events.listen(_onEvent);
    _connSub = socket.connectionChanges.listen((c) {
      connected = c;
      notifyListeners();
      if (c) _resync();
    });
    _typingTimer = Timer.periodic(const Duration(seconds: 2), (_) => _expireTyping());
    loadChats().catchError((_) {});
    loadFolders().catchError((_) {});
    loadStories().catchError((_) {});
    loadAnnouncements().catchError((_) {});
  }

  void stop() {
    _eventSub?.cancel();
    _connSub?.cancel();
    _typingTimer?.cancel();
    _eventSub = null;
    _connSub = null;
    chats = [];
    chatsLoaded = false;
    activeChatId = null;
    _messages.clear();
    _hasMore.clear();
    _typing.clear();
    _lastReadSent.clear();
    userCache.clear();
    members.clear();
    folders = [];
    stories = [];
    announcements = [];
    _viewsSent.clear();
    myId = null;
  }

  void setForeground(bool fg) {
    appInForeground = fg;
    if (fg && activeChatId != null) markChatRead(activeChatId!);
  }

  // ------------------------------------------------------------------ chats
  Chat? chatById(int id) {
    for (final c in chats) {
      if (c.id == id) return c;
    }
    return null;
  }

  int get totalUnread => chats.where((c) => !c.isMuted).fold(0, (s, c) => s + c.unreadCount);

  Future<void> loadChats() async {
    final data = await api.get('/chats') as List;
    chats = data.map((j) => Chat.fromJson(Map<String, dynamic>.from(j as Map))).toList();
    for (final c in chats) {
      if (c.peer != null) userCache[c.peer!.id] = c.peer!;
    }
    _sortChats();
    chatsLoaded = true;
    notifyListeners();
  }

  Future<List<Chat>> loadArchived() async {
    final data = await api.get('/chats', query: {'archived': 'true'}) as List;
    return data.map((j) => Chat.fromJson(Map<String, dynamic>.from(j as Map))).toList();
  }

  Future<Chat?> refreshChat(int id) async {
    try {
      final c = Chat.fromJson(Map<String, dynamic>.from(await api.get('/chats/$id') as Map));
      _upsertChat(c);
      return c;
    } on ApiException catch (e) {
      if (e.status == 404) _removeChat(id);
      return null;
    }
  }

  /// Fetches a chat (from cache or server) without adding hidden chats to the list.
  Future<Chat> getChat(int id) async {
    return chatById(id) ?? Chat.fromJson(Map<String, dynamic>.from(await api.get('/chats/$id') as Map));
  }

  void _upsertChat(Chat c) {
    if (c.peer != null) userCache[c.peer!.id] = c.peer!;
    chats.removeWhere((x) => x.id == c.id);
    if (!c.isArchived && (c.lastMessage != null || c.isGroup || c.id == activeChatId)) chats.add(c);
    _sortChats();
    notifyListeners();
  }

  void _removeChat(int id) {
    chats.removeWhere((c) => c.id == id);
    _messages.remove(id);
    members.remove(id);
    notifyListeners();
  }

  void _sortChats() {
    chats.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return b.sortTime.compareTo(a.sortTime);
    });
  }

  // ------------------------------------------------------------------ messages
  List<Message> messagesOf(int chatId) => _messages[chatId] ?? const [];
  bool isLoaded(int chatId) => _messages.containsKey(chatId);
  bool hasMore(int chatId) => _hasMore[chatId] ?? true;

  Future<void> openChat(int chatId) async {
    activeChatId = chatId;
    if (!_messages.containsKey(chatId)) await loadMessages(chatId);
    markChatRead(chatId);
  }

  void closeChat(int chatId) {
    if (activeChatId == chatId) activeChatId = null;
  }

  void _cacheSenders(Iterable<Message> list) {
    for (final m in list) {
      final s = m.sender;
      if (s != null && !userCache.containsKey(s.id)) userCache[s.id] = s;
    }
  }

  Future<void> loadMessages(int chatId) async {
    final data = Map<String, dynamic>.from(await api.get('/chats/$chatId/messages', query: {'limit': '50'}) as Map);
    final list = (data['messages'] as List).map((j) => Message.fromJson(Map<String, dynamic>.from(j as Map))).toList();
    _cacheSenders(list);
    final locals = (_messages[chatId] ?? []).where((m) => m.isLocal).toList();
    _messages[chatId] = [...locals, ...list];
    _hasMore[chatId] = data['has_more'] == true;
    notifyListeners();
  }

  Future<void> loadMore(int chatId) async {
    if (_loadingMore.contains(chatId) || !hasMore(chatId)) return;
    final list = _messages[chatId];
    if (list == null) return;
    final oldest = list.lastWhere((m) => !m.isLocal, orElse: () => list.isEmpty ? Message(id: 0, chatId: chatId, type: 'text', createdAt: DateTime.now()) : list.last);
    if (oldest.id <= 0) {
      _hasMore[chatId] = false;
      return;
    }
    _loadingMore.add(chatId);
    try {
      final data = Map<String, dynamic>.from(
          await api.get('/chats/$chatId/messages', query: {'before': '${oldest.id}', 'limit': '50'}) as Map);
      final older = (data['messages'] as List).map((j) => Message.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      _cacheSenders(older);
      final known = list.map((m) => m.id).toSet();
      list.addAll(older.where((m) => !known.contains(m.id)));
      _hasMore[chatId] = data['has_more'] == true;
    } finally {
      _loadingMore.remove(chatId);
      notifyListeners();
    }
  }

  /// After a reconnect: fetch anything we missed in the open chat; drop other caches.
  Future<void> _resync() async {
    try {
      await loadChats();
    } catch (_) {}
    final active = activeChatId;
    _messages.removeWhere((k, _) => k != active);
    if (active == null || !_messages.containsKey(active)) return;
    final list = _messages[active]!;
    final newest = list.firstWhere((m) => !m.isLocal, orElse: () => Message(id: 0, chatId: active, type: 'text', createdAt: DateTime.now()));
    try {
      if (newest.id == 0) {
        await loadMessages(active);
      } else {
        final data = Map<String, dynamic>.from(
            await api.get('/chats/$active/messages', query: {'after': '${newest.id}', 'limit': '100'}) as Map);
        if (data['has_more'] == true) {
          await loadMessages(active);
        } else {
          for (final j in (data['messages'] as List).reversed) {
            _insertIncoming(Message.fromJson(Map<String, dynamic>.from(j as Map)));
          }
          notifyListeners();
        }
      }
      markChatRead(active);
    } catch (_) {}
  }

  void markChatRead(int chatId) {
    if (!appInForeground) return;
    final list = _messages[chatId];
    final chat = chatById(chatId);
    if (list == null) return;
    final newest = list.firstWhere((m) => !m.isLocal, orElse: () => Message(id: 0, chatId: chatId, type: 'text', createdAt: DateTime.now()));
    if (newest.id <= 0) return;
    final dirty = chat != null && (chat.unreadCount != 0 || chat.markedUnread || chat.unreadMentions != 0);
    if ((_lastReadSent[chatId] ?? 0) >= newest.id && !dirty) return;
    _lastReadSent[chatId] = newest.id;
    if (chat != null && dirty) {
      chat.unreadCount = 0;
      chat.unreadMentions = 0;
      chat.markedUnread = false;
      notifyListeners();
    }
    final payload = {'chat_id': chatId, 'message_id': newest.id};
    if (socket.isConnected && !(chat?.markedUnread ?? false)) {
      socket.emit('message:read', payload);
    } else {
      api.post('/chats/$chatId/read', {'message_id': newest.id}).catchError((_) => null);
    }
  }

  // ------------------------------------------------------------------ sending
  String _newClientId() => '${DateTime.now().microsecondsSinceEpoch}-${_rand.nextInt(1 << 30)}';

  void _insertLocal(Message m) {
    final list = _messages.putIfAbsent(m.chatId, () => []);
    list.insert(0, m);
    final chat = chatById(m.chatId);
    if (chat != null) {
      chat.lastMessage = m;
      _sortChats();
    }
    notifyListeners();
  }

  ReplyInfo? _replyInfo(Message? r) => r == null
      ? null
      : ReplyInfo(id: r.id, senderId: r.senderId, senderName: r.sender?.name ?? '', type: r.type, text: r.text);

  Future<void> sendText(int chatId, String text, {Message? replyTo, bool silent = false}) async {
    final local = Message(
      id: _localId--,
      chatId: chatId,
      senderId: myId,
      type: 'text',
      text: text,
      replyTo: _replyInfo(replyTo),
      clientId: _newClientId(),
      createdAt: DateTime.now(),
      sendState: SendState.sending,
      outbox: {'type': 'text', 'text': text, if (replyTo != null) 'reply_to_id': replyTo.id, if (silent) 'silent': true},
    );
    _insertLocal(local);
    await _deliver(local);
  }

  Future<void> sendLocation(int chatId, double lat, double lng, {String title = ''}) async {
    final local = Message(
      id: _localId--,
      chatId: chatId,
      senderId: myId,
      type: 'location',
      text: title,
      meta: {
        'location': {'lat': lat, 'lng': lng, 'title': title},
      },
      clientId: _newClientId(),
      createdAt: DateTime.now(),
      sendState: SendState.sending,
      outbox: {
        'type': 'location',
        'location': {'lat': lat, 'lng': lng, 'title': title},
      },
    );
    _insertLocal(local);
    await _deliver(local);
  }

  /// type: image | video | voice | file
  Future<void> sendMedia(
    int chatId,
    String path, {
    required String type,
    String caption = '',
    String? mime,
    String? name,
    int? duration,
    int? width,
    int? height,
    Message? replyTo,
    String? albumId,
  }) async {
    final file = File(path);
    final local = Message(
      id: _localId--,
      chatId: chatId,
      senderId: myId,
      type: type,
      text: caption,
      albumId: albumId,
      replyTo: _replyInfo(replyTo),
      clientId: _newClientId(),
      createdAt: DateTime.now(),
      sendState: SendState.sending,
      localFilePath: path,
      uploadKind: type,
      media: MediaInfo(
        id: 0,
        kind: type,
        mime: mime ?? 'application/octet-stream',
        size: await file.length(),
        name: name ?? path.split(Platform.pathSeparator).last,
        duration: duration,
        width: width,
        height: height,
        url: '',
      ),
      outbox: {'type': type, 'text': caption, if (replyTo != null) 'reply_to_id': replyTo.id, if (albumId != null) 'album_id': albumId},
    );
    _insertLocal(local);
    await _uploadAndDeliver(local);
  }

  Future<void> _uploadAndDeliver(Message local) async {
    if (local.uploadKind != null) {
      try {
        final m = local.media!;
        final media = await api.upload(local.localFilePath!, kind: local.uploadKind!, mime: m.mime, fields: {
          if (m.duration != null) 'duration': '${m.duration}',
          if (m.width != null) 'width': '${m.width}',
          if (m.height != null) 'height': '${m.height}',
        });
        final info = MediaInfo.fromJson(media);
        await services.media.putLocal(info, local.localFilePath!);
        local.outbox!['media_id'] = info.id;
        local.uploadKind = null;
      } on ApiException catch (e) {
        _fail(local, e.message);
        return;
      } catch (e) {
        _fail(local, 'Upload failed');
        return;
      }
    }
    await _deliver(local);
  }

  Future<void> _deliver(Message local) async {
    final payload = <String, dynamic>{...local.outbox!, 'chat_id': local.chatId, 'client_id': local.clientId};
    try {
      Map<String, dynamic> json;
      if (socket.isConnected) {
        final r = await socket.request('message:send', payload);
        json = Map<String, dynamic>.from(r['message'] as Map);
      } else {
        json = Map<String, dynamic>.from(await api.post('/chats/${local.chatId}/messages', payload) as Map);
      }
      _confirm(local, Message.fromJson(json));
    } on ApiException catch (e) {
      _fail(local, e.message);
    } catch (_) {
      _fail(local, 'Could not send');
    }
  }

  void _fail(Message local, String error) {
    local.sendState = SendState.failed;
    local.errorText = error;
    notifyListeners();
  }

  void _confirm(Message local, Message real) {
    final list = _messages[local.chatId];
    if (list != null) {
      final already = list.any((m) => m.id == real.id);
      final i = list.indexOf(local);
      if (i >= 0) {
        if (already) {
          list.removeAt(i);
        } else {
          list[i] = real;
        }
      }
      list.sort(_byNewest);
    }
    final chat = chatById(local.chatId);
    if (chat != null && (chat.lastMessage == local || (chat.lastMessage?.id ?? 0) < real.id)) {
      chat.lastMessage = real;
      _sortChats();
    } else if (chat == null) {
      refreshChat(local.chatId);
    }
    notifyListeners();
  }

  static int _byNewest(Message a, Message b) {
    if (a.isLocal != b.isLocal) return a.isLocal ? -1 : 1;
    if (a.isLocal) return a.id.compareTo(b.id); // more negative = newer
    return b.id.compareTo(a.id);
  }

  Future<void> retry(Message local) async {
    local.sendState = SendState.sending;
    local.errorText = null;
    notifyListeners();
    await _uploadAndDeliver(local);
  }

  void discard(Message local) {
    _messages[local.chatId]?.remove(local);
    final chat = chatById(local.chatId);
    if (chat != null && chat.lastMessage == local) {
      final rest = messagesOf(local.chatId);
      chat.lastMessage = rest.isEmpty ? null : rest.first;
    }
    notifyListeners();
  }

  void sendTyping(int chatId) {
    final last = _typingSent[chatId];
    if (last != null && DateTime.now().difference(last).inMilliseconds < 3000) return;
    _typingSent[chatId] = DateTime.now();
    socket.emit('typing', {'chat_id': chatId});
  }

  // ------------------------------------------------------------------ message actions
  Future<void> editMessage(Message m, String text) async {
    final json = await api.patch('/messages/${m.id}', {'text': text});
    _replaceMessage(Message.fromJson(Map<String, dynamic>.from(json as Map)));
  }

  Future<void> deleteMessages(int chatId, List<int> ids, {required bool forEveryone}) async {
    await api.post('/chats/$chatId/messages/delete', {'message_ids': ids, 'for_everyone': forEveryone});
    _removeMessages(chatId, ids);
  }

  Future<int> forward(int fromChatId, List<int> messageIds, List<int> toChatIds) async {
    final r = await api.post('/messages/forward', {
      'from_chat_id': fromChatId,
      'message_ids': messageIds,
      'to_chat_ids': toChatIds,
    });
    return ((r as Map)['forwarded'] as num).toInt();
  }

  void _replaceMessage(Message m) {
    final list = _messages[m.chatId];
    if (list != null) {
      final i = list.indexWhere((x) => x.id == m.id);
      if (i >= 0) list[i] = m;
    }
    final chat = chatById(m.chatId);
    if (chat != null && chat.lastMessage?.id == m.id) chat.lastMessage = m;
    notifyListeners();
  }

  void _removeMessages(int chatId, List<int> ids) {
    _messages[chatId]?.removeWhere((m) => ids.contains(m.id));
    final chat = chatById(chatId);
    if (chat != null && ids.contains(chat.lastMessage?.id)) refreshChat(chatId);
    notifyListeners();
  }

  // ------------------------------------------------------------------ chat actions
  Future<Chat> openPrivateWith(int userId) async {
    final c = Chat.fromJson(Map<String, dynamic>.from(await api.post('/chats/private', {'user_id': userId}) as Map));
    if (c.peer != null) userCache[c.peer!.id] = c.peer!;
    return c;
  }

  Future<(Chat, List<int>)> createGroup(String title, List<int> memberIds, {String? avatarPath}) async {
    final r = Map<String, dynamic>.from(await api.post('/chats/group', {'title': title, 'member_ids': memberIds}) as Map);
    var chat = Chat.fromJson(Map<String, dynamic>.from(r['chat'] as Map));
    final skipped = (r['skipped'] as List).map((s) => ((s as Map)['user_id'] as num).toInt()).toList();
    if (avatarPath != null) {
      try {
        chat = await setGroupAvatar(chat.id, avatarPath);
      } catch (_) {}
    }
    _upsertChat(chat);
    return (chat, skipped);
  }

  Future<Chat> updateChatSettings(int chatId, Map<String, dynamic> body) async {
    final c = Chat.fromJson(Map<String, dynamic>.from(await api.patch('/chats/$chatId/settings', body) as Map));
    _upsertChat(c);
    return c;
  }

  Future<void> leaveOrDelete(int chatId) async {
    await api.post('/chats/$chatId/leave');
    _removeChat(chatId);
  }

  Future<void> clearHistory(int chatId) async {
    await api.post('/chats/$chatId/clear');
    _messages[chatId] = [];
    _hasMore[chatId] = false;
    final chat = chatById(chatId);
    if (chat != null) {
      chat.lastMessage = null;
      chat.unreadCount = 0;
    }
    notifyListeners();
  }

  Future<List<GroupMember>> loadMembers(int chatId) async {
    final data = await api.get('/chats/$chatId/members') as List;
    final list = data.map((j) => GroupMember.fromJson(Map<String, dynamic>.from(j as Map))).toList();
    for (final m in list) {
      userCache[m.user.id] = m.user;
    }
    members[chatId] = list;
    notifyListeners();
    return list;
  }

  Future<Chat> updateGroup(int chatId, {String? title, String? description}) async {
    final c = Chat.fromJson(Map<String, dynamic>.from(await api.patch('/chats/$chatId', {
      if (title != null) 'title': title,
      if (description != null) 'description': description,
    }) as Map));
    _upsertChat(c);
    return c;
  }

  Future<Chat> setGroupAvatar(int chatId, String? path) async {
    int? mediaId;
    if (path != null) mediaId = ((await api.upload(path, kind: 'avatar'))['id'] as num).toInt();
    final c = Chat.fromJson(Map<String, dynamic>.from(await api.put('/chats/$chatId/avatar', {'media_id': mediaId}) as Map));
    _upsertChat(c);
    return c;
  }

  Future<List<int>> addMembers(int chatId, List<int> userIds) async {
    final r = Map<String, dynamic>.from(await api.post('/chats/$chatId/members', {'user_ids': userIds}) as Map);
    await loadMembers(chatId);
    return (r['skipped'] as List).map((s) => ((s as Map)['user_id'] as num).toInt()).toList();
  }

  Future<void> removeMember(int chatId, int userId) async {
    await api.delete('/chats/$chatId/members/$userId');
    await loadMembers(chatId);
  }

  Future<void> setRole(int chatId, int userId, String role) async {
    await api.put('/chats/$chatId/members/$userId/role', {'role': role});
    await loadMembers(chatId);
  }

  Future<String> regenerateInvite(int chatId) async {
    final r = await api.post('/chats/$chatId/invite/regenerate');
    await refreshChat(chatId);
    return (r as Map)['invite_code'] as String;
  }

  Future<Map<String, dynamic>> invitePreview(String code) async =>
      Map<String, dynamic>.from(await api.get('/chats/invite/${Uri.encodeComponent(code)}') as Map);

  /// Returns null when the chat requires admin approval (request sent).
  Future<Chat?> joinByInvite(String code) async {
    final r = Map<String, dynamic>.from(await api.post('/chats/invite/${Uri.encodeComponent(code)}/join') as Map);
    if (r['requested'] == true) return null;
    final c = Chat.fromJson(r);
    _upsertChat(c);
    return c;
  }


  // ------------------------------------------------------------------ reactions
  static const reactionEmojis = ['👍', '❤️', '🔥', '😂', '😮', '😢', '👏', '🙏', '🎉', '👎'];

  Message? _findMessage(int chatId, int messageId) {
    final list = _messages[chatId];
    if (list == null) return null;
    for (final m in list) {
      if (m.id == messageId) return m;
    }
    return null;
  }

  /// Sets (or clears with null / same emoji) this user's reaction.
  Future<void> react(Message m, String? emoji) async {
    final next = emoji == m.myReaction ? null : emoji;
    final r = Map<String, dynamic>.from(await api.put('/messages/${m.id}/reaction', {'emoji': next}) as Map);
    m.reactions = ReactionCount.listFrom(r['reactions']);
    m.myReaction = r['my_reaction'] as String?;
    notifyListeners();
  }

  // ------------------------------------------------------------------ polls
  Future<void> sendPoll(int chatId, Map<String, dynamic> poll) async {
    await api.post('/chats/$chatId/messages', {'type': 'poll', 'poll': poll, 'client_id': _newClientId()});
  }

  Future<void> vote(Message m, List<int> options) async {
    final p = PollInfo.fromJson(Map<String, dynamic>.from(await api.post('/messages/${m.id}/vote', {'options': options}) as Map));
    _applyPoll(m, p, own: true);
  }

  Future<void> closePoll(Message m) async {
    final p = PollInfo.fromJson(Map<String, dynamic>.from(await api.post('/messages/${m.id}/poll/close') as Map));
    _applyPoll(m, p, own: true);
  }

  Future<List<AppUser>> pollVoters(Message m, int option) async {
    final data = await api.get('/messages/${m.id}/poll/voters', query: {'option': '$option'}) as List;
    return data.map((j) => AppUser.fromJson(Map<String, dynamic>.from(j as Map))).toList();
  }

  void _applyPoll(Message m, PollInfo p, {required bool own}) {
    final current = m.poll;
    if (current == null) return;
    current.mergeCounts(p);
    if (own) current.myVotes = p.myVotes;
    notifyListeners();
  }

  // ------------------------------------------------------------------ channels & public chats
  Future<Chat> createChannel({required String title, String description = '', String? username, String? avatarPath}) async {
    var chat = Chat.fromJson(Map<String, dynamic>.from(await api.post('/chats/channel', {
      'title': title,
      'description': description,
      if (username != null && username.isNotEmpty) 'username': username,
    }) as Map));
    if (avatarPath != null) {
      try {
        chat = await setGroupAvatar(chat.id, avatarPath);
      } catch (_) {}
    }
    _upsertChat(chat);
    return chat;
  }

  Future<List<Map<String, dynamic>>> searchPublic(String q) async {
    final data = await api.get('/chats/search', query: {'q': q}) as List;
    return data.map((j) => Map<String, dynamic>.from(j as Map)).toList();
  }

  Future<Map<String, dynamic>> publicPreview(String username) async =>
      Map<String, dynamic>.from(await api.get('/chats/public/${Uri.encodeComponent(username)}') as Map);

  /// Returns null when the chat requires admin approval (request sent).
  Future<Chat?> joinPublic(int chatId) async {
    final r = Map<String, dynamic>.from(await api.post('/chats/$chatId/join') as Map);
    if (r['requested'] == true) return null;
    final c = Chat.fromJson(r);
    _upsertChat(c);
    return c;
  }

  Future<Chat> setChatUsername(int chatId, String? username) async {
    final c = Chat.fromJson(Map<String, dynamic>.from(await api.put('/chats/$chatId/username', {'username': username}) as Map));
    _upsertChat(c);
    return c;
  }

  Future<Chat> setSignatures(int chatId, bool on) async {
    final c = Chat.fromJson(Map<String, dynamic>.from(await api.patch('/chats/$chatId', {'signatures': on}) as Map));
    _upsertChat(c);
    return c;
  }

  Future<Map<String, dynamic>> stats(int chatId) async => Map<String, dynamic>.from(await api.get('/chats/$chatId/stats') as Map);

  /// Reports channel posts as seen (each post counted once per user on the server).
  Future<void> recordViews(int chatId, Iterable<Message> visible) async {
    final sent = _viewsSent.putIfAbsent(chatId, () => {});
    final ids = visible.where((m) => !m.isLocal && !m.isSystem && !sent.contains(m.id)).map((m) => m.id).take(100).toList();
    if (ids.isEmpty) return;
    sent.addAll(ids);
    try {
      final r = Map<String, dynamic>.from(await api.post('/chats/$chatId/views', {'message_ids': ids}) as Map);
      final views = Map<String, dynamic>.from(r['views'] as Map);
      views.forEach((k, v) => _findMessage(chatId, int.parse(k))?.views = (v as num).toInt());
      notifyListeners();
    } catch (_) {
      sent.removeAll(ids);
    }
  }

  // ------------------------------------------------------------------ scheduled messages
  Future<void> scheduleText(int chatId, String text, DateTime at) async {
    await api.post('/chats/$chatId/messages', {'type': 'text', 'text': text, 'schedule_at': at.toUtc().toIso8601String()});
  }

  Future<List<Map<String, dynamic>>> listScheduled(int chatId) async {
    final data = await api.get('/chats/$chatId/scheduled') as List;
    return data.map((j) => Map<String, dynamic>.from(j as Map)).toList();
  }

  Future<void> cancelScheduled(int id) async => api.delete('/scheduled/$id');

  // ------------------------------------------------------------------ folders
  Future<void> loadFolders() async {
    final data = await api.get('/folders') as List;
    folders = data.map((j) => ChatFolder.fromJson(Map<String, dynamic>.from(j as Map))).toList();
    notifyListeners();
  }

  Future<void> saveFolder(ChatFolder? existing, Map<String, dynamic> body) async {
    if (existing == null) {
      await api.post('/folders', body);
    } else {
      await api.patch('/folders/${existing.id}', body);
    }
    await loadFolders();
  }

  Future<void> deleteFolder(int id) async {
    await api.delete('/folders/$id');
    await loadFolders();
  }

  Future<void> reorderFolders(List<int> ids) async {
    final data = await api.put('/folders/order', {'folder_ids': ids}) as List;
    folders = data.map((j) => ChatFolder.fromJson(Map<String, dynamic>.from(j as Map))).toList();
    notifyListeners();
  }


  // ------------------------------------------------------------------ stories
  Future<void> loadStories() async {
    final data = await api.get('/stories') as List;
    stories = data.map((j) => StoryGroup.fromJson(Map<String, dynamic>.from(j as Map))).toList();
    notifyListeners();
  }

  /// type: image | video. privacy: contacts | everyone
  Future<void> postStory(String path, {required String type, String caption = '', String privacy = 'contacts', String? mime}) async {
    final m = await api.upload(path, kind: type, mime: mime);
    await api.post('/stories', {'media_id': m['id'], 'caption': caption, 'privacy': privacy});
    await loadStories();
  }

  Future<void> markStoryViewed(StoryItem s, {String? emoji}) async {
    if (s.userId == myId) return;
    if (s.viewed && emoji == null) return;
    s.viewed = true;
    await api.post('/stories/${s.id}/view', {if (emoji != null) 'emoji': emoji});
  }

  Future<void> deleteStory(StoryItem s) async {
    await api.delete('/stories/${s.id}');
    await loadStories();
  }

  Future<List<Map<String, dynamic>>> storyViewers(StoryItem s) async {
    final data = await api.get('/stories/${s.id}/viewers') as List;
    return data.map((j) => Map<String, dynamic>.from(j as Map)).toList();
  }

  Future<void> replyToStory(StoryItem s, String text) async {
    await api.post('/stories/${s.id}/reply', {'text': text});
  }

  /// Re-evaluates "unseen" rings after viewing.
  void refreshStoryRings() {
    for (final g in stories) {
      g.hasUnseen = g.user.id != myId && g.stories.any((s) => !s.viewed);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ announcements
  Future<void> loadAnnouncements() async {
    final data = await api.get('/announcements') as List;
    announcements = data.map((j) => Announcement.fromJson(Map<String, dynamic>.from(j as Map))).toList();
    notifyListeners();
  }

  Future<void> dismissAnnouncement(Announcement a) async {
    announcements.remove(a);
    notifyListeners();
    await api.post('/announcements/${a.id}/dismiss');
  }


  // ------------------------------------------------------------------ pins
  Future<List<Message>> listPins(int chatId) async {
    final data = await api.get('/chats/$chatId/pins') as List;
    return data.map((j) => Message.fromJson(Map<String, dynamic>.from(j as Map))).toList();
  }

  Future<void> pin(int chatId, int messageId) async {
    await api.post('/chats/$chatId/pins', {'message_id': messageId});
    await refreshChat(chatId);
  }

  Future<void> unpin(int chatId, Object messageId) async {
    await api.delete('/chats/$chatId/pins/$messageId');
    await refreshChat(chatId);
  }

  // ------------------------------------------------------------------ unread marks
  Future<void> setMarkedUnread(Chat chat, bool value) async {
    if (!value) {
      chat.markedUnread = false;
      chat.unreadCount = 0;
      notifyListeners();
      final last = chat.lastMessage;
      if (last != null && !last.isLocal) {
        await api.post('/chats/${chat.id}/read', {'message_id': last.id});
      } else {
        await api.patch('/chats/${chat.id}/settings', {'marked_unread': false});
      }
      return;
    }
    await updateChatSettings(chat.id, {'marked_unread': true});
  }

  // ------------------------------------------------------------------ search
  /// Returns pairs of (chat summary, message), newest first.
  Future<List<(Map<String, dynamic>, Message)>> searchMessages(String q, {int? chatId}) async {
    final r = Map<String, dynamic>.from(await api.get('/search/messages', query: {
      'q': q,
      if (chatId != null) 'chat_id': '$chatId',
    }) as Map);
    return (r['results'] as List).map((x) {
      final m = Map<String, dynamic>.from(x as Map);
      return (Map<String, dynamic>.from(m['chat'] as Map), Message.fromJson(Map<String, dynamic>.from(m['message'] as Map)));
    }).toList();
  }

  // ------------------------------------------------------------------ contacts
  Future<List<AppUser>> syncContacts(List<String> phones) async {
    final out = <AppUser>[];
    for (var i = 0; i < phones.length; i += 2000) {
      final part = phones.sublist(i, (i + 2000).clamp(0, phones.length).toInt());
      final data = await api.post('/contacts/sync', {'phones': part}) as List;
      out.addAll(data.map((j) => AppUser.fromJson(Map<String, dynamic>.from(j as Map))));
    }
    return out;
  }

  // ------------------------------------------------------------------ group admin tools
  Future<Chat> patchChat(int chatId, Map<String, dynamic> body) async {
    final c = Chat.fromJson(Map<String, dynamic>.from(await api.patch('/chats/$chatId', body) as Map));
    _upsertChat(c);
    return c;
  }

  Future<Map<String, dynamic>> listInvites(int chatId) async => Map<String, dynamic>.from(await api.get('/chats/$chatId/invites') as Map);

  Future<void> createInvite(int chatId, {String name = '', int? expireHours, int? usageLimit}) async {
    await api.post('/chats/$chatId/invites', {
      'name': name,
      if (expireHours != null) 'expire_hours': expireHours,
      if (usageLimit != null) 'usage_limit': usageLimit,
    });
  }

  Future<void> revokeInvite(int chatId, String code) async => api.delete('/chats/$chatId/invites/$code');

  Future<List<Map<String, dynamic>>> joinRequests(int chatId) async {
    final data = await api.get('/chats/$chatId/join-requests') as List;
    return data.map((j) => Map<String, dynamic>.from(j as Map)).toList();
  }

  Future<void> resolveJoinRequest(int chatId, int userId, bool approve) async {
    await api.post('/chats/$chatId/join-requests/$userId/${approve ? 'approve' : 'decline'}');
    await refreshChat(chatId);
    if (members.containsKey(chatId)) await loadMembers(chatId);
  }

  Future<void> transferOwnership(int chatId, int userId) async {
    await api.put('/chats/$chatId/owner', {'user_id': userId});
    await refreshChat(chatId);
    await loadMembers(chatId);
  }

  // ------------------------------------------------------------------ typing & names
  String userName(int? id) {
    if (id == null) return 'Someone';
    if (id == myId) return 'You';
    return userCache[id]?.name ?? 'a member';
  }

  /// "typing…" / "Ali is typing…" / "2 people are typing…", or null.
  String? typingText(Chat chat) {
    final t = _typing[chat.id];
    if (t == null || t.isEmpty) return null;
    if (!chat.isGroup) return 'typing…';
    if (t.length == 1) return '${userCache[t.keys.first]?.firstName ?? 'Someone'} is typing…';
    return '${t.length} people are typing…';
  }

  void _expireTyping() {
    final now = DateTime.now();
    var changed = false;
    for (final m in _typing.values) {
      final before = m.length;
      m.removeWhere((_, exp) => exp.isBefore(now));
      if (m.length != before) changed = true;
    }
    if (changed) notifyListeners();
  }

  // ------------------------------------------------------------------ realtime events
  int _int(dynamic v) => (v as num).toInt();

  void _onEvent(SocketEvent e) {
    final d = e.data;
    switch (e.name) {
      case 'message:new':
        final m = Message.fromJson(Map<String, dynamic>.from(d['message'] as Map));
        _onNewMessage(m);
        break;
      case 'message:edited':
        _replaceMessage(Message.fromJson(Map<String, dynamic>.from(d['message'] as Map)));
        break;
      case 'message:deleted':
        _removeMessages(_int(d['chat_id']), (d['message_ids'] as List).map(_int).toList());
        break;
      case 'receipt:read':
        final chat = chatById(_int(d['chat_id']));
        if (chat != null) {
          chat.readUpTo = max(chat.readUpTo, _int(d['message_id']));
          chat.deliveredUpTo = max(chat.deliveredUpTo, chat.readUpTo);
          notifyListeners();
        }
        break;
      case 'receipt:delivered':
        final dChat = chatById(_int(d['chat_id']));
        if (dChat != null) {
          dChat.deliveredUpTo = max(dChat.deliveredUpTo, _int(d['message_id']));
          notifyListeners();
        }
        break;
      case 'chat:updated':
        final id = _int(d['chat_id']);
        refreshChat(id);
        if (members.containsKey(id)) loadMembers(id).catchError((_) => <GroupMember>[]);
        break;
      case 'chat:removed':
        _removeChat(_int(d['chat_id']));
        break;
      case 'typing':
        final uid = _int(d['user_id']);
        if (uid == myId) break;
        _typing.putIfAbsent(_int(d['chat_id']), () => {})[uid] = DateTime.now().add(const Duration(seconds: 5));
        notifyListeners();
        break;
      case 'presence':
        _onPresence(_int(d['user_id']), d['online'] == true, d['last_seen'] as String?);
        break;
      case 'user:updated':
        final changedId = _int(d['user_id']);
        for (final c in chats.where((c) => c.peer?.id == changedId).toList()) {
          refreshChat(c.id);
        }
        break;
      case 'message:reactions':
        final rm = _findMessage(_int(d['chat_id']), _int(d['message_id']));
        if (rm != null) {
          rm.reactions = ReactionCount.listFrom(d['reactions']);
          notifyListeners();
        }
        break;
      case 'message:poll':
        final pm = _findMessage(_int(d['chat_id']), _int(d['message_id']));
        if (pm != null && d['poll'] != null) {
          _applyPoll(pm, PollInfo.fromJson(Map<String, dynamic>.from(d['poll'] as Map)), own: false);
        }
        break;
      case 'support:updated':
        supportUpdates.value++;
        break;
      case 'session:revoked':
        onSessionRevoked?.call();
        break;
    }
  }

  void _onPresence(int userId, bool online, String? lastSeen) {
    final seen = lastSeen == null ? null : DateTime.parse(lastSeen).toLocal();
    for (final c in chats) {
      if (c.peer?.id == userId) {
        c.peer!.online = online;
        if (seen != null) c.peer!.lastSeen = seen;
      }
    }
    final u = userCache[userId];
    if (u != null) {
      u.online = online;
      if (seen != null) u.lastSeen = seen;
    }
    notifyListeners();
  }

  /// Inserts a message from the server into the loaded list (dedupes own optimistic copies).
  bool _insertIncoming(Message m) {
    final list = _messages[m.chatId];
    if (list == null) return false;
    if (list.any((x) => x.id == m.id)) return false;
    final localIdx = m.clientId == null ? -1 : list.indexWhere((x) => x.isLocal && x.clientId == m.clientId);
    if (localIdx >= 0) {
      list[localIdx] = m;
    } else {
      list.add(m);
    }
    list.sort(_byNewest);
    return true;
  }

  void _onNewMessage(Message m) {
    if (m.threadId != null) {
      // a comment under a channel post: not part of the channel timeline
      for (final x in _messages[m.chatId] ?? <Message>[]) {
        if (x.id == m.threadId) x.commentsCount += 1;
      }
      notifyListeners();
      return;
    }
    _cacheSenders([m]);
    // Channel posts carry no sender id, so a matching optimistic copy is how we know it's ours.
    final hadLocal = m.clientId != null && (_messages[m.chatId]?.any((x) => x.isLocal && x.clientId == m.clientId) ?? false);
    _insertIncoming(m);
    final mine = (m.senderId == myId && !m.isSystem) || hadLocal;
    final chat = chatById(m.chatId);
    if (chat == null) {
      refreshChat(m.chatId);
    } else {
      if ((chat.lastMessage?.id ?? 0) <= m.id || chat.lastMessage!.isLocal) chat.lastMessage = m;
      if (!mine && (m.senderId != myId || m.senderId == null)) {
        final viewing = activeChatId == m.chatId && appInForeground;
        if (!viewing) {
          chat.unreadCount += 1;
          if (m.mentions.contains(myId)) chat.unreadMentions += 1;
        }
        _typing[m.chatId]?.remove(m.senderId);
      }
      _sortChats();
    }
    if (!mine && m.senderId != myId) {
      socket.emit('message:delivered', {'chat_id': m.chatId, 'message_id': m.id});
      if (activeChatId == m.chatId) markChatRead(m.chatId);
    }
    notifyListeners();
  }
}
