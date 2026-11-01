import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/services.dart';
import '../core/socket_service.dart';
import '../models/models.dart';

/// Someone in a live voice chat.
class VcParticipant {
  VcParticipant({required this.user, this.muted = true, this.canSpeak = true, this.handRaised = false, this.video = false});
  final AppUser user;
  bool muted;
  bool canSpeak;
  bool handRaised;
  bool video;
  bool speaking = false;

  factory VcParticipant.fromJson(Map<String, dynamic> j) => VcParticipant(
        user: AppUser.fromJson(Map<String, dynamic>.from(j['user'] as Map)),
        muted: j['muted'] != false,
        canSpeak: j['can_speak'] != false,
        handRaised: j['hand_raised'] == true,
        video: j['video'] == true,
      );
}

/// The live voice chat I'm in (one at a time). Audio goes peer-to-peer to every other participant
/// (WebRTC mesh); the server keeps the room state and relays offers / answers / ICE.
class VoiceChatManager extends ChangeNotifier {
  VoiceChatManager(this.services) {
    _sub = services.socket.events.listen(_onEvent);
  }

  final AppServices services;
  late final StreamSubscription<SocketEvent> _sub;

  int? chatId;
  String chatTitle = '';
  String title = '';
  bool canManage = false;
  bool connecting = false;
  bool speaker = true;
  final List<VcParticipant> participants = [];
  int? Function()? myId;

  int maxVideo = 8;

  // ---- video (cameras are optional: every connection carries an empty video slot we fill when the camera goes on)
  MediaStream? _camStream;
  MediaStreamTrack? get _cam => _camStream?.getVideoTracks().firstOrNull;
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  bool _localReady = false;
  final Map<int, RTCVideoRenderer> renderers = {};
  bool frontCamera = true;
  bool get cameraOn => _camStream != null;
  bool get anyVideo => participants.any((p) => p.video);

  MediaStream? _local;
  List<Map<String, dynamic>> _ice = [];
  final Map<int, RTCPeerConnection> _peers = {};
  final Map<int, List<RTCIceCandidate>> _pendingIce = {};
  final Map<int, bool> _remoteSet = {};
  Timer? _levelTimer;
  bool _wasSpeaking = false;

  bool get active => chatId != null;
  VcParticipant? get me {
    final id = myId?.call();
    for (final p in participants) {
      if (p.user.id == id) return p;
    }
    return null;
  }

  bool get muted => me?.muted ?? true;

  // ------------------------------------------------------------------ joining & leaving
  Future<void> join(Chat chat, {bool start = false, String title = ''}) async {
    if (chatId == chat.id) return;
    if (active) await leave();
    connecting = true;
    chatId = chat.id;
    chatTitle = chat.title;
    notifyListeners();
    try {
      _local = await navigator.mediaDevices.getUserMedia({
        'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
        'video': false,
      });
      _setMicEnabled(false); // everyone joins muted
      final r = await services.socket.request(start ? 'vc:start' : 'vc:join', {'chat_id': chat.id, if (title.isNotEmpty) 'title': title});
      _ice = ((r['ice_servers'] as List?) ?? const []).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
      canManage = r['can_manage'] == true;
      _applyState(r['voice_chat']);
      await Helper.setSpeakerphoneOn(speaker).catchError((_) {});
      // I'm the newcomer: I call everyone already in the room
      for (final p in participants) {
        if (p.user.id != myId?.call()) await _offerTo(p.user.id);
      }
      _startLevels();
    } catch (e) {
      await _cleanup();
      rethrow;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> leave() async {
    final id = chatId;
    if (id == null) return;
    services.socket.request('vc:leave', {'chat_id': id}).catchError((_) => <String, dynamic>{});
    await _cleanup();
  }

  Future<void> end() async {
    final id = chatId;
    if (id == null) return;
    try {
      await services.api.post('/chats/$id/voice-chat/end');
    } finally {
      await _cleanup();
    }
  }

  Future<void> _cleanup() async {
    _levelTimer?.cancel();
    await _stopCamera();
    for (final r in renderers.values) {
      r.srcObject = null;
      await r.dispose().catchError((_) {});
    }
    renderers.clear();
    for (final pc in _peers.values) {
      await pc.close().catchError((_) {});
    }
    _peers.clear();
    _pendingIce.clear();
    _remoteSet.clear();
    for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop().catchError((_) {});
    }
    await _local?.dispose().catchError((_) {});
    _local = null;
    chatId = null;
    participants.clear();
    canManage = false;
    Helper.setSpeakerphoneOn(false).catchError((_) {});
    notifyListeners();
  }

  // ------------------------------------------------------------------ controls
  Future<void> toggleMute() async {
    final id = chatId;
    final m = me;
    if (id == null || m == null) return;
    if (!m.canSpeak) {
      await setHand(!m.handRaised);
      return;
    }
    final next = !m.muted;
    m.muted = next;
    _setMicEnabled(!next);
    notifyListeners();
    try {
      await services.api.patch('/chats/$id/voice-chat', {'muted': next});
    } catch (_) {
      m.muted = !next;
      _setMicEnabled(next);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setHand(bool raised) async {
    final id = chatId;
    if (id == null) return;
    me?.handRaised = raised;
    notifyListeners();
    await services.api.patch('/chats/$id/voice-chat', {'hand_raised': raised});
  }

  /// Admin: mute someone, or (channels) let a listener speak / take the word back.
  Future<void> manage(int userId, {bool? mute, bool? canSpeak}) async {
    final id = chatId;
    if (id == null) return;
    await services.api.patch('/chats/$id/voice-chat', {'user_id': userId, if (mute != null) 'muted': mute, if (canSpeak != null) 'can_speak': canSpeak});
  }

  /// Camera on / off. The track goes into the video slot of every connection — no renegotiation needed.
  Future<void> toggleCamera() async {
    final id = chatId;
    final m = me;
    if (id == null || m == null) return;
    if (cameraOn) {
      await _stopCamera();
      m.video = false;
      notifyListeners();
      await services.api.patch('/chats/$id/voice-chat', {'video': false}).catchError((_) => <String, dynamic>{});
      return;
    }
    if (!m.canSpeak) throw Exception('Raise your hand — an admin will let you speak');
    if (participants.where((p) => p.video).length >= maxVideo) throw Exception('Up to $maxVideo cameras can be on at once');
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {'facingMode': frontCamera ? 'user' : 'environment', 'width': 640, 'height': 480, 'frameRate': 20},
    });
    _camStream = stream;
    if (!_localReady) {
      await localRenderer.initialize();
      _localReady = true;
    }
    localRenderer.srcObject = stream;
    for (final pc in _peers.values) {
      await _fillVideo(pc);
    }
    m.video = true;
    notifyListeners();
    try {
      await services.api.patch('/chats/$id/voice-chat', {'video': true});
    } catch (_) {
      await _stopCamera();
      m.video = false;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> switchCamera() async {
    final t = _cam;
    if (t == null) return;
    await Helper.switchCamera(t);
    frontCamera = !frontCamera;
    notifyListeners();
  }

  Future<void> _stopCamera() async {
    final s = _camStream;
    if (s == null) return;
    _camStream = null;
    for (final pc in _peers.values) {
      for (final tr in await pc.getTransceivers().catchError((_) => <RTCRtpTransceiver>[])) {
        if (_isVideo(tr)) await tr.sender.replaceTrack(null).catchError((_) {});
      }
    }
    if (_localReady) localRenderer.srcObject = null;
    for (final t in s.getTracks()) {
      await t.stop().catchError((_) {});
    }
    await s.dispose().catchError((_) {});
  }

  bool _isVideo(RTCRtpTransceiver tr) => tr.receiver.track?.kind == 'video' || tr.sender.track?.kind == 'video';

  /// Sends my camera (if on) through this connection's video slot, at a bitrate a mesh can afford.
  Future<void> _fillVideo(RTCPeerConnection pc) async {
    final cam = _cam;
    for (final tr in await pc.getTransceivers()) {
      if (!_isVideo(tr)) continue;
      await tr.sender.replaceTrack(cam).catchError((_) {});
      if (cam != null) {
        try {
          final params = tr.sender.parameters;
          final enc = params.encodings;
          if (enc != null && enc.isNotEmpty) {
            enc.first.maxBitrate = participants.length > 4 ? 250000 : 450000;
            await tr.sender.setParameters(params);
          }
        } catch (_) {}
      }
    }
  }

  void toggleSpeaker() {
    speaker = !speaker;
    Helper.setSpeakerphoneOn(speaker).catchError((_) {});
    notifyListeners();
  }

  void _setMicEnabled(bool on) {
    for (final t in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = on;
    }
  }

  // ------------------------------------------------------------------ room state & signalling
  void _applyState(Object? raw) {
    if (raw is! Map) return;
    final list = ((raw['participants'] as List?) ?? const []).whereType<Map>().map((j) => VcParticipant.fromJson(Map<String, dynamic>.from(j))).toList();
    final speaking = {for (final p in participants) p.user.id: p.speaking};
    participants
      ..clear()
      ..addAll(list.map((p) => p..speaking = speaking[p.user.id] ?? false));
    title = '${raw['title'] ?? ''}';
    // my mic follows what the server says (an admin may have muted me)
    final m = me;
    if (m != null) _setMicEnabled(!m.muted && m.canSpeak);
    if (raw['max_video'] is num) maxVideo = (raw['max_video'] as num).toInt();
    // an admin made me a listener: my camera goes off too
    if (m != null && !m.video && cameraOn) _stopCamera().then((_) => notifyListeners());
    // people who left: close their connection
    final ids = participants.map((p) => p.user.id).toSet();
    for (final gone in _peers.keys.where((k) => !ids.contains(k)).toList()) {
      _peers.remove(gone)?.close();
      _remoteSet.remove(gone);
      final r = renderers.remove(gone);
      if (r != null) {
        r.srcObject = null;
        r.dispose();
      }
    }
    notifyListeners();
  }

  Future<void> _onEvent(SocketEvent e) async {
    final d = e.data;
    if (chatId == null || '${d['chat_id']}' != '$chatId') return;
    switch (e.name) {
      case 'vc:update':
        if (d['voice_chat'] == null || d['ended'] == true) {
          await _cleanup();
          return;
        }
        _applyState(d['voice_chat']);
      case 'vc:speaking':
        for (final p in participants) {
          if ('${p.user.id}' == '${d['user_id']}') p.speaking = d['speaking'] == true;
        }
        notifyListeners();
      case 'vc:signal':
        await _onSignal(int.parse('${d['from']}'), Map<String, dynamic>.from(d['data'] as Map));
    }
  }

  Future<RTCPeerConnection> _peer(int userId, {bool offerer = false}) async {
    final existing = _peers[userId];
    if (existing != null) return existing;
    final pc = await createPeerConnection({'iceServers': _ice, 'sdpSemantics': 'unified-plan', 'bundlePolicy': 'max-bundle', 'rtcpMuxPolicy': 'require'});
    _peers[userId] = pc;
    for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
      await pc.addTrack(t, _local!);
    }
    // the video slot: whoever makes the offer opens it; it stays empty until a camera goes on
    if (offerer) {
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, streams: [if (_local != null) _local!]),
      );
      await _fillVideo(pc);
    }
    pc.onTrack = (RTCTrackEvent e) async {
      if (e.track.kind != 'video') return; // audio plays by itself
      var r = renderers[userId];
      if (r == null) {
        r = RTCVideoRenderer();
        await r.initialize();
        renderers[userId] = r;
      }
      if (e.streams.isNotEmpty) {
        r.srcObject = e.streams.first;
      } else {
        final s = await createLocalMediaStream('vc$userId');
        await s.addTrack(e.track);
        r.srcObject = s;
      }
      notifyListeners();
    };
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _send(userId, {'kind': 'ice', 'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex}});
    };
    // remote audio plays by itself once the track arrives
    return pc;
  }

  Future<void> _offerTo(int userId) async {
    final pc = await _peer(userId, offerer: true);
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _send(userId, {'kind': 'offer', 'sdp': offer.sdp});
  }

  Future<void> _onSignal(int from, Map<String, dynamic> data) async {
    switch (data['kind']) {
      case 'offer':
        final pc = await _peer(from);
        await pc.setRemoteDescription(RTCSessionDescription('${data['sdp']}', 'offer'));
        _remoteSet[from] = true;
        await _flush(from);
        // answer the video slot both ways, so my camera can go through it too
        for (final tr in await pc.getTransceivers()) {
          if (_isVideo(tr)) await tr.setDirection(TransceiverDirection.SendRecv).catchError((_) {});
        }
        await _fillVideo(pc);
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        _send(from, {'kind': 'answer', 'sdp': answer.sdp});
      case 'answer':
        final pc = _peers[from];
        if (pc == null) return;
        await pc.setRemoteDescription(RTCSessionDescription('${data['sdp']}', 'answer'));
        _remoteSet[from] = true;
        await _flush(from);
      case 'ice':
        final c = Map<String, dynamic>.from(data['candidate'] as Map);
        final cand = RTCIceCandidate('${c['candidate']}', c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt());
        final pc = _peers[from];
        if (pc != null && _remoteSet[from] == true) {
          await pc.addCandidate(cand).catchError((_) {});
        } else {
          (_pendingIce[from] ??= []).add(cand);
        }
    }
  }

  Future<void> _flush(int userId) async {
    final pc = _peers[userId];
    final list = _pendingIce.remove(userId) ?? const [];
    for (final c in list) {
      await pc?.addCandidate(c).catchError((_) {});
    }
  }

  void _send(int to, Map<String, dynamic> data) {
    final id = chatId;
    if (id == null) return;
    services.socket.emit('vc:signal', {'chat_id': id, 'to': to, 'data': data});
  }

  /// My "speaking" ring: reads the microphone level from WebRTC stats a few times a second.
  void _startLevels() {
    _levelTimer?.cancel();
    _levelTimer = Timer.periodic(const Duration(milliseconds: 450), (_) async {
      final m = me;
      if (m == null) return;
      var level = 0.0;
      if (!m.muted && _peers.isNotEmpty) {
        try {
          final stats = await _peers.values.first.getStats();
          for (final r in stats) {
            final v = r.values['audioLevel'];
            if ((r.type == 'media-source' || r.type == 'track') && v is num) level = level < v ? v.toDouble() : level;
          }
        } catch (_) {}
      }
      final speakingNow = !m.muted && level > 0.04;
      if (speakingNow != _wasSpeaking) {
        _wasSpeaking = speakingNow;
        m.speaking = speakingNow;
        notifyListeners();
        final id = chatId;
        if (id != null) services.socket.emit('vc:speaking', {'chat_id': id, 'speaking': speakingNow});
      }
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    _cleanup().then((_) {
      if (_localReady) localRenderer.dispose();
    });
    super.dispose();
  }
}
