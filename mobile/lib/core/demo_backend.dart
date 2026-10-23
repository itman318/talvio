import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

import 'api_client.dart';

/// Offline demo ("Try demo" on the login screen): plays back a recorded world from
/// assets/demo/demo.json so the whole app can be explored without a server.
/// Sending messages, reactions, polls, mute/pin etc. work locally; friends reply automatically.
class DemoBackend {
  DemoBackend._(this._responses, this._messages, this._media, this.meId);

  static const marker = 'demo-session';

  /// The running demo (null when talking to a real server).
  static DemoBackend? active;

  /// Recorded bytes for a public file URL (stickers, avatars), if this is the demo.
  static Uint8List? bytesFor(String url) {
    final d = active;
    if (d == null) return null;
    final i = url.indexOf('/api/media/');
    final b64 = i < 0 ? null : d._media[url.substring(i)];
    return b64 == null ? null : base64Decode(b64);
  }

  final Map<String, dynamic> _responses;
  final Map<int, List<Map<String, dynamic>>> _messages;
  final Map<String, String> _media;
  final int meId;
  int _nextId = 900000000;
  final Map<String, String> _localFiles = {};

  /// Pushes a realtime event into the app (wired to SocketService).
  void Function(String event, Map<String, dynamic> data)? onEvent;

  static Future<DemoBackend> load() async {
    var raw = await rootBundle.loadString('assets/demo/demo.json');
    final data = jsonDecode(raw) as Map<String, dynamic>;
    // move every timestamp so the conversation happened "just now"
    final recorded = DateTime.parse(data['recorded_at'] as String);
    final shift = DateTime.now().toUtc().subtract(const Duration(minutes: 3)).difference(recorded);
    raw = raw.replaceAllMapped(RegExp(r'"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)"'), (m) {
      final t = DateTime.tryParse(m[1]!);
      return t == null ? m[0]! : '"${t.add(shift).toUtc().toIso8601String()}"';
    });
    final d = jsonDecode(raw) as Map<String, dynamic>;
    if ((d['responses'] as Map?)?['/me'] == null) throw ApiException(500, 'demo', 'Demo data is missing from this build');
    final msgs = <int, List<Map<String, dynamic>>>{};
    (d['messages'] as Map).forEach((k, v) {
      msgs[int.parse('$k')] = (v as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    });
    return DemoBackend._(
      Map<String, dynamic>.from(d['responses'] as Map),
      msgs,
      Map<String, String>.from(d['media'] as Map),
      (d['me_id'] as num).toInt(),
    );
  }

  Map<String, dynamic> get me => Map<String, dynamic>.from(_responses['/me'] as Map);
  Map<String, dynamic> get appConfig => Map<String, dynamic>.from((_responses['/app-config'] ?? const {}) as Map);

  List<Map<String, dynamic>> get _chats =>
      ((_responses['/chats'] as List?) ?? const []).map((e) => e as Map<String, dynamic>).toList();

  Map<String, dynamic>? _chat(int id) {
    for (final c in (_responses['/chats'] as List? ?? const [])) {
      if ((c as Map)['id'] == id) return c as Map<String, dynamic>;
    }
    return null;
  }

  Map<String, dynamic>? _findMessage(int id) {
    for (final list in _messages.values) {
      for (final m in list) {
        if (m['id'] == id) return m;
      }
    }
    return null;
  }

  static bool _matches(Map<String, dynamic> m, String filter) => switch (filter) {
        'media' => ['image', 'video', 'gif'].contains(m['type']),
        'files' => m['type'] == 'file',
        'voice' => ['voice', 'video_note'].contains(m['type']),
        'links' => m['type'] == 'text' && (m['link_preview'] != null || RegExp(r'https?://').hasMatch('${m['text'] ?? ''}')),
        _ => true,
      };

  static ApiException _notInDemo() =>
      ApiException(400, 'demo', 'Demo mode — this works once the app is connected to your server');

  // ------------------------------------------------------------------ REST
  Future<dynamic> handle(String method, String path, Object? body, Map<String, String>? query) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final b = body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};
    final seg = path.split('?').first.split('/').where((s) => s.isNotEmpty).toList();
    int? idAt(int i) => seg.length > i ? int.tryParse(seg[i]) : null;

    if (method == 'GET') {
      if (path == '/chats') {
        if (query?['archived'] == 'true') return <dynamic>[];
        final list = _chats.where((c) => c['is_archived'] != true).toList()
          ..sort((x, y) => '${y['last_message_at'] ?? y['created_at']}'.compareTo('${x['last_message_at'] ?? x['created_at']}'));
        return list;
      }
      if (seg.length == 3 && seg[0] == 'chats' && seg[2] == 'messages') {
        final id = idAt(1)!;
        if (query?['before'] != null || query?['after'] != null) return {'messages': <dynamic>[], 'has_more': false};
        final list = _messages[id] ?? <Map<String, dynamic>>[];
        final filter = query?['filter'];
        if (filter != null) return {'messages': list.where((m) => _matches(m, filter)).toList(), 'has_more': false};
        return {'messages': list, 'has_more': false};
      }
      if (seg.length == 3 && seg[0] == 'chats' && seg[2] == 'media-counts') {
        final list = _messages[idAt(1)!] ?? <Map<String, dynamic>>[];
        return {for (final f in ['media', 'files', 'voice', 'links']) f: list.where((m) => _matches(m, f)).length};
      }
      if (seg.length == 2 && seg[0] == 'chats' && idAt(1) != null) {
        final c = _chat(idAt(1)!);
        if (c != null) return c;
      }
      if (path == '/search/messages') {
        final q = (query?['q'] ?? '').toLowerCase();
        final only = int.tryParse(query?['chat_id'] ?? '');
        final results = <Map<String, dynamic>>[];
        _messages.forEach((cid, list) {
          if (only != null && cid != only) return;
          final c = _chat(cid);
          if (c == null) return;
          for (final m in list) {
            if (q.isNotEmpty && '${m['text'] ?? ''}'.toLowerCase().contains(q)) results.add({'chat': c, 'message': m});
          }
        });
        return {'results': results};
      }
      if (path == '/users/search' || path == '/chats/search') {
        final q = (query?['q'] ?? '').toLowerCase();
        if (path == '/chats/search') return <dynamic>[];
        final users = <dynamic>[];
        for (final c in _chats) {
          final p = c['peer'];
          if (p is Map && '${p['first_name']} ${p['last_name']} ${p['username'] ?? ''}'.toLowerCase().contains(q)) users.add(p);
        }
        return users;
      }
      if (path == '/me/username-check') return {'available': true};
      if (path == '/me/password') return {'enabled': false, 'hint': '', 'reset_pending_until': null};
      if (path == '/gifs') return {'results': <dynamic>[]};
      if (_responses.containsKey(path)) return _responses[path];
      // things the recording doesn't have: an empty list is the safest answer for collections
      if (seg.isNotEmpty && (seg.last.endsWith('s') || seg.last == 'pending' || seg.last == 'active')) return <dynamic>[];
      throw _notInDemo();
    }

    // ---------------------------------------------------------------- writes
    if (seg.length == 3 && seg[0] == 'chats' && seg[2] == 'messages' && method == 'POST') {
      if (b['schedule_at'] != null) throw _notInDemo();
      return _send({...b, 'chat_id': idAt(1)});
    }
    if (seg.length == 3 && seg[0] == 'chats' && seg[2] == 'read') {
      final c = _chat(idAt(1)!);
      if (c != null) {
        c['unread_count'] = 0;
        c['marked_unread'] = false;
        c['read_up_to'] = b['message_id'] ?? c['read_up_to'];
      }
      return {'ok': true};
    }
    if (seg.length == 3 && seg[0] == 'chats' && seg[2] == 'settings') {
      final c = _chat(idAt(1)!);
      if (c == null) throw _notInDemo();
      c.addAll(b);
      if (b.containsKey('muted_until') || b.containsKey('mute_for_sec') || b.containsKey('mute')) {
        c['is_muted'] = b['muted_until'] != null || (b['mute_for_sec'] ?? 0) != 0 || b['mute'] == true;
      }
      return c;
    }
    if (seg.length == 3 && seg[0] == 'messages' && seg[2] == 'reaction') {
      final m = _findMessage(idAt(1)!);
      if (m == null) throw _notInDemo();
      final emoji = b['emoji'] as String?;
      final list = ((m['reactions'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final old = m['my_reaction'] as String?;
      if (old != null) {
        for (final r in list) {
          if (r['emoji'] == old) r['count'] = (r['count'] as num) - 1;
        }
      }
      if (emoji != null) {
        final hit = list.where((r) => r['emoji'] == emoji).toList();
        if (hit.isEmpty) {
          list.add({'emoji': emoji, 'count': 1});
        } else {
          hit.first['count'] = (hit.first['count'] as num) + 1;
        }
      }
      list.removeWhere((r) => (r['count'] as num) <= 0);
      m['reactions'] = list;
      m['my_reaction'] = emoji;
      return {'reactions': list, 'my_reaction': emoji};
    }
    if (seg.length == 3 && seg[0] == 'messages' && seg[2] == 'vote') {
      final m = _findMessage(idAt(1)!);
      final poll = m?['poll'];
      if (poll is! Map) throw _notInDemo();
      final p = Map<String, dynamic>.from(poll);
      final options = (p['options'] as List).map((o) => Map<String, dynamic>.from(o as Map)).toList();
      final mine = ((p['my_votes'] as List?) ?? []).map((e) => (e as num).toInt()).toList();
      for (final i in mine) {
        if (i < options.length) options[i]['votes'] = ((options[i]['votes'] ?? 0) as num) - 1;
      }
      final picked = ((b['options'] as List?) ?? []).map((e) => (e as num).toInt()).where((i) => i >= 0 && i < options.length).toList();
      for (final i in picked) {
        options[i]['votes'] = ((options[i]['votes'] ?? 0) as num) + 1;
      }
      p['options'] = options;
      p['my_votes'] = picked;
      p['total_voters'] = ((p['total_voters'] ?? 0) as num) + (mine.isEmpty && picked.isNotEmpty ? 1 : (!mine.isEmpty && picked.isEmpty ? -1 : 0));
      m!['poll'] = p;
      return p;
    }
    if (path == '/me' && method == 'PATCH') {
      final me = _responses['/me'] as Map<String, dynamic>;
      me.addAll(b);
      return me;
    }
    if (path == '/chats/private') {
      final uid = (b['user_id'] as num?)?.toInt();
      for (final c in _chats) {
        if ((c['peer'] as Map?)?['id'] == uid || (uid == meId && c['is_saved_messages'] == true)) return c;
      }
      throw _notInDemo();
    }
    if (seg.length == 3 && seg[0] == 'messages' && seg[2] == 'live') return {'ok': true, 'until': DateTime.now().toUtc().toIso8601String()};
    if (seg.length == 3 && seg[0] == 'chats' && seg[2] == 'disappearing') {
      final c = _chat(idAt(1)!);
      if (c != null) c['disappear_after_sec'] = b['seconds'] ?? 0;
      return c ?? {'ok': true};
    }
    const quiet = ['read', 'views', 'dismiss', 'push-token', 'ack', 'logout', 'view'];
    if (seg.isNotEmpty && quiet.contains(seg.last)) return {'ok': true};
    throw _notInDemo();
  }

  // ------------------------------------------------------------------ messages
  Map<String, dynamic> _send(Map<String, dynamic> b) {
    final chatId = (b['chat_id'] as num).toInt();
    final chat = _chat(chatId);
    if (chat == null) throw _notInDemo();
    final type = (b['type'] ?? 'text') as String;
    if (!['text', 'image', 'video', 'voice', 'video_note', 'file', 'location', 'contact', 'sticker', 'gif', 'poll'].contains(type)) throw _notInDemo();
    final meJson = me;
    Map<String, dynamic>? replyTo;
    final rid = (b['reply_to_id'] as num?)?.toInt();
    if (rid != null) {
      final r = _findMessage(rid);
      if (r != null) {
        replyTo = {'id': r['id'], 'text': r['text'], 'type': r['type'], 'sender_id': r['sender_id'], 'sender_name': (r['sender'] as Map?)?['first_name']};
      }
    }
    Map<String, dynamic>? media;
    final mid = b['media_id'];
    if (mid != null && _localFiles.containsKey('/demo/media/$mid')) {
      final f = _localFiles['/demo/media/$mid']!;
      final mime = type == 'image' ? 'image/jpeg' : (type == 'video' || type == 'video_note') ? 'video/mp4' : type == 'voice' ? 'audio/mp4' : 'application/octet-stream';
      media = {'id': mid, 'url': '/demo/media/$mid', 'kind': type == 'video_note' ? 'video' : type, 'mime': mime, 'name': f.split(Platform.pathSeparator).last, 'size': File(f).lengthSync()};
    }
    Map<String, dynamic>? meta = b['meta'] is Map ? Map<String, dynamic>.from(b['meta'] as Map) : null;
    if (type == 'contact') meta = {'contact': b['contact']};
    if (type == 'location') {
      final loc = Map<String, dynamic>.from((b['location'] ?? const {}) as Map);
      meta = {'location': loc};
      if (loc['live_minutes'] != null) {
        final now = DateTime.now().toUtc();
        meta['live'] = {'until': now.add(Duration(minutes: (loc['live_minutes'] as num).toInt())).toIso8601String(), 'updated_at': now.toIso8601String()};
      }
    }
    if (type == 'gif') meta = {'gif': b['gif']};
    if (type == 'sticker') {
      // reuse the recorded sticker file
      for (final p in (_responses['/stickers/packs'] as List? ?? const [])) {
        for (final s in ((p as Map)['stickers'] as List? ?? const [])) {
          if ((s as Map)['id'] == b['sticker_id']) {
            media = null;
            meta = {'sticker': {'id': s['id'], 'emoji': s['emoji'], 'pack_id': p['id'], 'url': s['url']}};
          }
        }
      }
    }
    Map<String, dynamic>? poll;
    if (type == 'poll') {
      final pb = Map<String, dynamic>.from((b['poll'] ?? const {}) as Map);
      poll = {
        'id': _nextId,
        'question': pb['question'],
        'options': [for (final o in (pb['options'] as List? ?? const [])) {'text': '$o', 'votes': 0}],
        'total_voters': 0,
        'anonymous': pb['anonymous'] != false,
        'multiple': pb['multiple'] == true,
        'quiz': false,
        'closed': false,
        'my_votes': <int>[],
      };
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final m = <String, dynamic>{
      'id': _nextId++,
      'chat_id': chatId,
      'sender_id': meId,
      'sender': {'id': meId, 'first_name': meJson['first_name'], 'last_name': meJson['last_name'], 'username': meJson['username'], 'avatar_url': meJson['avatar_url']},
      'type': type,
      'text': type == 'poll' ? (poll?['question'] ?? '') : (b['text'] ?? ''),
      'media': media,
      'meta': meta,
      'poll': poll,
      'reply_to': replyTo,
      'reactions': <dynamic>[],
      'client_id': b['client_id'],
      'created_at': now,
    };
    _messages.putIfAbsent(chatId, () => []).insert(0, m);
    chat['last_message'] = m;
    chat['last_message_at'] = now;
    // the other side "reads" it and sometimes answers
    final peer = chat['peer'];
    if (chat['type'] == 'private' && peer is Map && chat['is_saved_messages'] != true && peer['is_bot'] != true) {
      Timer(const Duration(milliseconds: 900), () {
        chat['delivered_up_to'] = m['id'];
        chat['read_up_to'] = m['id'];
        onEvent?.call('receipt:read', {'chat_id': chatId, 'message_id': m['id'], 'user_id': peer['id']});
      });
      Timer(const Duration(milliseconds: 1600), () => onEvent?.call('typing', {'chat_id': chatId, 'user_id': peer['id']}));
      Timer(const Duration(milliseconds: 3200), () => _reply(chat, Map<String, dynamic>.from(peer), '${b['text'] ?? ''}'));
    }
    return m;
  }

  static const _answers = [
    'Sounds great 👍',
    'Okay, talk later 🙂',
    'Sure ✅',
    'Haha 😄',
    'Thank you! ❤️',
    'Perfect 👌',
  ];
  int _answer = 0;

  void _reply(Map<String, dynamic> chat, Map<String, dynamic> peer, String text) {
    final t = text.toLowerCase();
    final answer = RegExp(r'\b(hi|hello|hey|salam)\b').hasMatch(t)
        ? 'Hey! 👋 How are you?'
        : t.contains('?')
            ? 'Good question, let me think 🤔'
            : _answers[_answer++ % _answers.length];
    final now = DateTime.now().toUtc().toIso8601String();
    final m = <String, dynamic>{
      'id': _nextId++,
      'chat_id': chat['id'],
      'sender_id': peer['id'],
      'sender': {'id': peer['id'], 'first_name': peer['first_name'], 'last_name': peer['last_name'], 'username': peer['username'], 'avatar_url': peer['avatar_url']},
      'type': 'text',
      'text': answer,
      'reactions': <dynamic>[],
      'created_at': now,
    };
    _messages.putIfAbsent(chat['id'] as int, () => []).insert(0, m);
    chat['last_message'] = m;
    chat['last_message_at'] = now;
    onEvent?.call('message:new', {'message': m});
  }

  // ------------------------------------------------------------------ socket
  Future<Map<String, dynamic>> socketRequest(String event, Map<String, dynamic> data) async {
    if (event == 'message:send') {
      final m = await handle('POST', '/chats/${data['chat_id']}/messages', data, null);
      return {'ok': true, 'message': m};
    }
    if (event == 'call:start') {
      throw ApiException(400, 'demo', 'Calls need the server — they will work once Talvio is live');
    }
    throw _notInDemo();
  }

  // ------------------------------------------------------------------ files
  Future<Map<String, dynamic>> upload(String filePath, String kind) async {
    final id = _nextId++;
    _localFiles['/demo/media/$id'] = filePath;
    return {'id': id, 'url': '/demo/media/$id', 'kind': kind, 'mime': 'application/octet-stream', 'size': File(filePath).lengthSync(), 'name': filePath.split(Platform.pathSeparator).last};
  }

  Future<File> download(String url, File target) async {
    final local = _localFiles[url];
    if (local != null) return File(local).copy(target.path);
    var b64 = _media[url];
    if (b64 == null) {
      // the same file may be recorded with or without the server prefix
      final i = url.indexOf('/api/media/');
      if (i >= 0) b64 = _media[url.substring(i)];
    }
    if (b64 == null) throw ApiException(404, 'download_failed', 'Not available in demo');
    return target.writeAsBytes(base64Decode(b64));
  }
}

/// Image.network that also works in the offline demo.
Widget netImage(String url, {BoxFit? fit, ImageErrorWidgetBuilder? errorBuilder}) {
  final bytes = DemoBackend.bytesFor(url);
  if (bytes != null) return Image.memory(bytes, fit: fit, errorBuilder: errorBuilder, gaplessPlayback: true);
  return Image.network(url, fit: fit, errorBuilder: errorBuilder);
}
