import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/api_client.dart';
import '../core/notif_prefs.dart';
import '../core/services.dart';
import '../core/socket_service.dart';
import '../models/models.dart';

enum CallPhase { idle, outgoing, incoming, connecting, connected, reconnecting, ended }

/// One-to-one voice/video calls over WebRTC. Signaling goes through Socket.IO (see backend call.service.js):
///
///   caller: call:start → (callee accepts) call:accepted → creates offer → call:signal{offer}
///   callee: call:incoming → call:accept → receives offer → call:signal{answer}
///   both:   call:signal{ice} candidates, call:signal{media} mute/camera state, call:hangup → call:ended
class CallManager extends ChangeNotifier {
  CallManager(this.services) {
    _sub = services.socket.events.listen(_onEvent);
  }

  final AppServices services;
  StreamSubscription<SocketEvent>? _sub;

  /// Set from the data-saver preference (lower video resolution and frame rate).
  bool lowData = false;

  CallPhase phase = CallPhase.idle;
  CallInfo? call;
  AppUser? peer;
  bool video = false;

  bool muted = false;
  bool speaker = false;
  bool cameraOff = false;
  bool frontCamera = true;
  bool remoteMuted = false;
  bool remoteVideoOff = false;
  bool hasRemoteVideo = false;

  /// Screen sharing (video calls only): I'm sharing / the other person is sharing.
  bool sharingScreen = false;
  bool remoteSharing = false;
  MediaStream? _screen;

  String? endedText;
  bool canRate = false;
  Duration elapsed = Duration.zero;

  /// Set by the app: shows the full-screen call UI.
  void Function()? onShowCallScreen;

  /// True while CallScreen is on screen (so it isn't pushed twice).
  bool screenVisible = false;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  List<Map<String, dynamic>> _iceServers = [];
  final List<RTCIceCandidate> _pendingCandidates = [];
  String? _pendingOffer;
  bool _remoteSet = false;
  bool _restartTried = false;
  bool _cancelled = false;
  DateTime? _connectedAt;
  Timer? _ticker;
  Timer? _closeTimer;
  Timer? _failTimer;
  bool _ringing = false;

  /// Call waiting: someone else is calling while I'm on this call.
  CallInfo? waitingCall;

  bool get active => phase != CallPhase.idle;
  bool get isCaller => call?.outgoing ?? (phase == CallPhase.outgoing);

  String get statusText {
    switch (phase) {
      case CallPhase.outgoing:
        return call == null ? 'Calling…' : (waitingNotice ?? 'Ringing…');
      case CallPhase.incoming:
        return video ? 'Incoming video call' : 'Incoming voice call';
      case CallPhase.connecting:
        return 'Connecting…';
      case CallPhase.reconnecting:
        return 'Reconnecting…';
      case CallPhase.connected:
        return formatCallDuration(elapsed.inSeconds);
      case CallPhase.ended:
        return endedText ?? 'Call ended';
      case CallPhase.idle:
        return '';
    }
  }

  // ------------------------------------------------------------------ public actions
  /// Starts a call to [user]. Shows the call screen right away.
  Future<void> start(AppUser user, {required bool video, String? link}) async {
    if (active) return;
    _resetState();
    peer = user;
    this.video = video;
    speaker = video;
    phase = CallPhase.outgoing;
    notifyListeners();
    _showScreen();
    WakelockPlus.enable().catchError((_) {});
    try {
      await _ensureRenderers();
      await _openMedia();
      final r = await services.socket.request('call:start', link != null ? {'link': link, 'video': video} : {'user_id': user.id, 'video': video});
      call = CallInfo.fromJson(Map<String, dynamic>.from(r['call'] as Map));
      _iceServers = _parseIce(r['ice_servers']);
      if (_cancelled) {
        _sendHangup('hangup');
        return;
      }
      if (call!.status == 'busy') {
        _finish('Line busy');
        return;
      }
      if (call!.waiting) {
        endedText = null;
        waitingNotice = 'On another call — waiting…';
      }
      if (call!.status == 'accepted') {
        // They were calling us at the same moment — the server joined the two calls.
        phase = CallPhase.connecting;
        notifyListeners();
        await _createPeer();
        return;
      }
      notifyListeners();
    } on ApiException catch (e) {
      _finish(e.message);
    } catch (e) {
      _finish(_mediaError(e));
    }
  }

  Future<void> accept() async {
    final c = call;
    if (c == null || phase != CallPhase.incoming) return;
    _stopRing();
    phase = CallPhase.connecting;
    notifyListeners();
    WakelockPlus.enable().catchError((_) {});
    try {
      await _ensureRenderers();
      await _openMedia();
      final r = await services.socket.request('call:accept', {'call_id': c.id});
      _iceServers = _parseIce(r['ice_servers']);
      await _createPeer();
      final offer = _pendingOffer;
      _pendingOffer = null;
      if (offer != null) await _handleOffer(offer);
    } on ApiException catch (e) {
      _finish(e.code == 'answered_elsewhere' ? 'Answered on another device' : e.message);
    } catch (e) {
      _sendHangup('failed');
      _finish(_mediaError(e));
    }
  }

  Future<void> decline() async {
    final c = call;
    _stopRing();
    if (c != null) {
      services.socket.request('call:decline', {'call_id': c.id}).catchError((_) {
        return services.api.post('/calls/${c.id}/decline').then((_) => <String, dynamic>{});
      }).catchError((_) => <String, dynamic>{});
    }
    _finish('Declined', closeAfter: const Duration(milliseconds: 600));
  }

  /// Call waiting → decline the second call, keep talking.
  void declineWaiting() {
    final w = waitingCall;
    if (w == null) return;
    waitingCall = null;
    services.socket.request('call:decline', {'call_id': w.id}).catchError((_) => <String, dynamic>{});
    notifyListeners();
  }

  /// Call waiting → end this call and answer the waiting one (the server ends the first call).
  Future<void> endAndAnswer() async {
    final w = waitingCall;
    if (w == null) return;
    waitingCall = null;
    _closeTimer?.cancel();
    _cleanupMedia();
    _resetState();
    call = w;
    peer = w.peer;
    video = w.video;
    speaker = w.video;
    phase = CallPhase.incoming;
    notifyListeners();
    _showScreen();
    await accept();
  }

  /// Shown on the caller's screen when the other person is on another call.
  String? waitingNotice;

  void hangup() {
    if (phase == CallPhase.ended || phase == CallPhase.idle) return;
    if (call == null) {
      _cancelled = true; // call:start still in flight
      _finish('Cancelled', closeAfter: const Duration(milliseconds: 600));
      return;
    }
    final wasConnected = _connectedAt != null;
    _sendHangup('hangup');
    _finish('Call ended', rate: wasConnected);
  }

  void toggleMute() {
    muted = !muted;
    for (final t in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    _sendMedia();
    notifyListeners();
  }

  void toggleCamera() {
    if (!video) return;
    cameraOff = !cameraOff;
    for (final t in _local?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !cameraOff;
    }
    _sendMedia();
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final tracks = _local?.getVideoTracks() ?? [];
    if (tracks.isEmpty) return;
    await Helper.switchCamera(tracks.first);
    frontCamera = !frontCamera;
    notifyListeners();
  }

  /// Swaps my camera for my screen (and back). Android needs a media-projection foreground service.
  Future<String?> toggleScreenShare() async {
    final pc = _pc;
    if (!video || pc == null) return 'Screen sharing works in video calls';
    if (sharingScreen) {
      await _stopScreenShare();
      return null;
    }
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final ok = await Helper.requestCapturePermission();
        if (!ok) return null;
        await _startProjectionService();
      }
      final screen = await navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
      final track = screen.getVideoTracks().first;
      final sender = (await pc.getSenders()).where((s) => s.track?.kind == 'video').firstOrNull;
      if (sender == null) {
        for (final t in screen.getTracks()) {
          await t.stop();
        }
        await _stopProjectionService();
        return 'Could not share the screen';
      }
      await sender.replaceTrack(track);
      track.onEnded = () => _stopScreenShare();
      _screen = screen;
      sharingScreen = true;
      localRenderer.srcObject = screen;
      _sendMedia();
      notifyListeners();
      return null;
    } catch (e) {
      debugPrint('screen share: $e');
      await _stopProjectionService();
      return 'Could not share the screen';
    }
  }

  Future<void> _stopScreenShare() async {
    final screen = _screen;
    _screen = null;
    if (!sharingScreen && screen == null) return;
    sharingScreen = false;
    try {
      final cam = _local?.getVideoTracks().firstOrNull;
      final pc = _pc;
      if (pc != null && cam != null) {
        final sender = (await pc.getSenders()).where((s) => s.track?.kind == 'video').firstOrNull;
        await sender?.replaceTrack(cam);
      }
      if (_local != null && _renderersReady) localRenderer.srcObject = _local;
    } catch (_) {}
    for (final t in screen?.getTracks() ?? <MediaStreamTrack>[]) {
      t.stop().catchError((_) {});
    }
    screen?.dispose().catchError((_) {});
    await _stopProjectionService();
    _sendMedia();
    notifyListeners();
  }

  Future<void> _startProjectionService() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'screen_share',
        channelName: 'Screen sharing',
        channelDescription: 'Shown while you share your screen in a call',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.nothing()),
    );
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'Talvio',
      notificationText: 'You are sharing your screen',
    );
  }

  Future<void> _stopProjectionService() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
    } catch (_) {}
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    await Helper.setSpeakerphoneOn(speaker).catchError((_) {});
    notifyListeners();
  }

  Future<void> rate(int stars) async {
    final c = call;
    canRate = false;
    notifyListeners();
    if (c != null) {
      await services.api.post('/calls/${c.id}/rate', {'rating': stars}).catchError((_) => null);
    }
    close();
  }

  /// Closes the "call ended" view right away.
  void close() {
    _closeTimer?.cancel();
    _resetState();
    notifyListeners();
  }

  /// After the app is opened from a call notification (or comes back to the foreground).
  Future<void> checkActive() async {
    if (active) return;
    try {
      final r = await services.api.get('/calls/active');
      final j = (r as Map)['call'];
      if (j == null || active) return;
      final c = CallInfo.fromJson(Map<String, dynamic>.from(j as Map));
      if (!c.outgoing && c.status == 'ringing') _ring(c);
    } catch (_) {}
  }

  /// Logged out / session ended.
  void endLocal() {
    if (!active) return;
    if (call != null && phase != CallPhase.ended) {
      services.api.post('/calls/${call!.id}/hangup', {'reason': 'hangup'}).catchError((_) => null);
    }
    _cleanupMedia();
    _resetState();
    notifyListeners();
  }

  // ------------------------------------------------------------------ socket events
  void _onEvent(SocketEvent e) {
    final d = e.data;
    switch (e.name) {
      case 'call:incoming':
        final c = CallInfo.fromJson(Map<String, dynamic>.from(d['call'] as Map));
        if (active) {
          // already talking on this device: show it as a waiting call (end & answer / decline)
          if ((phase == CallPhase.connected || phase == CallPhase.connecting || phase == CallPhase.reconnecting) && call?.id != c.id) {
            waitingCall = c;
            FlutterRingtonePlayer().playNotification().catchError((_) {});
            notifyListeners();
          }
          return;
        }
        _ring(c);
        break;
      case 'call:accepted':
        if (!_isMine(d['call_id'])) return;
        if (phase == CallPhase.outgoing) {
          phase = CallPhase.connecting;
          notifyListeners();
          _startAsCaller();
        } else if (phase == CallPhase.incoming) {
          _stopRing();
          _finish('Answered on another device', closeAfter: const Duration(milliseconds: 800));
        }
        break;
      case 'call:signal':
        if (!_isMine(d['call_id'])) return;
        _onSignal(d);
        break;
      case 'call:ended':
        if (waitingCall != null && '${waitingCall!.id}' == '${d['call_id']}') {
          waitingCall = null; // the waiting caller gave up
          notifyListeners();
          return;
        }
        if (!_isMine(d['call_id'])) return;
        if (phase == CallPhase.ended || phase == CallPhase.idle) return;
        final status = '${d['status']}';
        final reason = '${d['end_reason']}';
        final outgoing = isCaller;
        String text;
        if (status == 'declined') {
          text = outgoing ? 'Call declined' : 'Declined';
        } else if (status == 'missed') {
          text = outgoing ? 'No answer' : 'Missed call';
        } else if (status == 'failed' || reason == 'connection_lost') {
          text = 'Connection lost';
        } else if (reason == 'time_limit') {
          text = 'Call time limit reached';
        } else {
          text = 'Call ended';
        }
        _finish(text, rate: _connectedAt != null);
        break;
    }
  }

  bool _isMine(dynamic id) => call != null && '${call!.id}' == '$id';

  Timer? _buzz;

  void _ring(CallInfo c) {
    _resetState();
    call = c;
    peer = c.peer;
    video = c.video;
    speaker = c.video;
    phase = CallPhase.incoming;
    _ringing = true;
    final np = NotifPrefs.instance;
    if (np.callRing) FlutterRingtonePlayer().playRingtone(looping: true, asAlarm: false).catchError((_) {});
    if (np.callVibrate) {
      _buzz?.cancel();
      HapticFeedback.vibrate();
      _buzz = Timer.periodic(const Duration(milliseconds: 1400), (_) => HapticFeedback.vibrate());
    }
    notifyListeners();
    _showScreen();
  }

  void _stopRing() {
    if (!_ringing) return;
    _ringing = false;
    _buzz?.cancel();
    _buzz = null;
    FlutterRingtonePlayer().stop().catchError((_) {});
  }

  void _showScreen() {
    if (!screenVisible) onShowCallScreen?.call();
  }

  // ------------------------------------------------------------------ WebRTC
  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersReady = true;
  }

  Future<void> _openMedia() async {
    if (_local != null) return;
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': video
          ? {
              'facingMode': 'user',
              // data saver → 480p at 15 fps (roughly a quarter of the data)
              'width': {'ideal': lowData ? 640 : 1280},
              'height': {'ideal': lowData ? 480 : 720},
              'frameRate': {'ideal': lowData ? 15 : 30},
            }
          : false,
    });
    if (video) localRenderer.srcObject = _local;
    notifyListeners();
  }

  Future<void> _createPeer() async {
    if (_pc != null) return;
    final pc = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
      await pc.addTrack(t, _local!);
    }
    pc.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null) return;
      _signal({
        'kind': 'ice',
        'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex},
      });
    };
    pc.onTrack = (RTCTrackEvent e) {
      if (e.streams.isEmpty) return;
      remoteRenderer.srcObject = e.streams.first;
      if (e.track.kind == 'video') hasRemoteVideo = true;
      notifyListeners();
    };
    pc.onIceConnectionState = _onIceState;
  }

  Future<void> _startAsCaller() async {
    try {
      await _createPeer();
      await _sendOffer();
    } catch (_) {
      _sendHangup('failed');
      _finish('Could not connect');
    }
  }

  Future<void> _sendOffer({bool iceRestart = false}) async {
    final pc = _pc;
    if (pc == null) return;
    final offer = await pc.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': video,
      if (iceRestart) 'iceRestart': true,
    });
    await pc.setLocalDescription(offer);
    _signal({'kind': 'offer', 'sdp': offer.sdp, if (iceRestart) 'ice_restart': true});
  }

  Future<void> _handleOffer(String sdp) async {
    final pc = _pc;
    if (pc == null) {
      _pendingOffer = sdp; // still opening the camera/microphone
      return;
    }
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _remoteSet = true;
    await _flushCandidates();
    final answer = await pc.createAnswer({'offerToReceiveAudio': true, 'offerToReceiveVideo': video});
    await pc.setLocalDescription(answer);
    _signal({'kind': 'answer', 'sdp': answer.sdp});
  }

  Future<void> _flushCandidates() async {
    final pc = _pc;
    if (pc == null) return;
    for (final c in List<RTCIceCandidate>.from(_pendingCandidates)) {
      await pc.addCandidate(c).catchError((_) {});
    }
    _pendingCandidates.clear();
  }

  Future<void> _onSignal(Map<String, dynamic> d) async {
    try {
      switch (d['kind']) {
        case 'offer':
          await _handleOffer('${d['sdp']}');
          break;
        case 'answer':
          await _pc?.setRemoteDescription(RTCSessionDescription('${d['sdp']}', 'answer'));
          _remoteSet = true;
          await _flushCandidates();
          break;
        case 'ice':
          final c = Map<String, dynamic>.from(d['candidate'] as Map);
          final cand = RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt());
          if (_pc != null && _remoteSet) {
            await _pc!.addCandidate(cand).catchError((_) {});
          } else {
            _pendingCandidates.add(cand);
          }
          break;
        case 'media':
          remoteMuted = d['muted'] == true;
          remoteVideoOff = d['video_off'] == true;
          remoteSharing = d['screen'] == true;
          notifyListeners();
          break;
      }
    } catch (e) {
      debugPrint('call signal error: $e');
    }
  }

  void _onIceState(RTCIceConnectionState s) {
    switch (s) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _failTimer?.cancel();
        if (_connectedAt == null) {
          _connectedAt = DateTime.now();
          Helper.setSpeakerphoneOn(speaker).catchError((_) {});
          _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
            elapsed = DateTime.now().difference(_connectedAt!);
            notifyListeners();
          });
        }
        phase = CallPhase.connected;
        notifyListeners();
        break;
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        if (phase == CallPhase.connected) {
          phase = CallPhase.reconnecting;
          notifyListeners();
        }
        _failTimer?.cancel();
        _failTimer = Timer(const Duration(seconds: 8), _tryRestartOrFail);
        break;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        _tryRestartOrFail();
        break;
      default:
        break;
    }
  }

  /// Network changed (Wi-Fi ↔ mobile data): the caller renegotiates once with an ICE restart.
  void _tryRestartOrFail() {
    if (phase == CallPhase.ended || phase == CallPhase.idle) return;
    if (isCaller && !_restartTried) {
      _restartTried = true;
      phase = CallPhase.reconnecting;
      notifyListeners();
      _sendOffer(iceRestart: true).catchError((_) {});
      _failTimer?.cancel();
      _failTimer = Timer(const Duration(seconds: 15), _tryRestartOrFail);
      return;
    }
    if (!isCaller && !_restartTried) {
      _restartTried = true; // give the caller time to restart
      _failTimer?.cancel();
      _failTimer = Timer(const Duration(seconds: 15), _tryRestartOrFail);
      return;
    }
    _sendHangup('failed');
    _finish('Connection lost', rate: _connectedAt != null);
  }

  void _signal(Map<String, dynamic> body) {
    final c = call;
    if (c == null) return;
    services.socket.emit('call:signal', {'call_id': c.id, ...body});
  }

  void _sendMedia() => _signal({'kind': 'media', 'muted': muted, 'video_off': cameraOff && !sharingScreen, 'screen': sharingScreen});

  void _sendHangup(String reason) {
    final c = call;
    if (c == null) return;
    services.socket.request('call:hangup', {'call_id': c.id, 'reason': reason}).catchError((_) {
      return services.api.post('/calls/${c.id}/hangup', {'reason': reason}).then((_) => <String, dynamic>{});
    }).catchError((_) => <String, dynamic>{});
  }

  // ------------------------------------------------------------------ teardown
  void _finish(String text, {bool rate = false, Duration? closeAfter}) {
    _stopRing();
    _cleanupMedia();
    endedText = text;
    canRate = rate && elapsed.inSeconds >= 10;
    phase = CallPhase.ended;
    notifyListeners();
    _closeTimer?.cancel();
    _closeTimer = Timer(closeAfter ?? (canRate ? const Duration(seconds: 8) : const Duration(seconds: 2)), close);
  }

  void _cleanupMedia() {
    final screen = _screen;
    _screen = null;
    if (screen != null || sharingScreen) {
      for (final t in screen?.getTracks() ?? <MediaStreamTrack>[]) {
        t.stop().catchError((_) {});
      }
      screen?.dispose().catchError((_) {});
      _stopProjectionService();
    }
    sharingScreen = false;
    _ticker?.cancel();
    _failTimer?.cancel();
    final pc = _pc;
    _pc = null;
    if (pc != null) {
      pc.close().catchError((_) {});
      pc.dispose().catchError((_) {});
    }
    final local = _local;
    _local = null;
    if (local != null) {
      for (final t in local.getTracks()) {
        t.stop().catchError((_) {});
      }
      local.dispose().catchError((_) {});
    }
    if (_renderersReady) {
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
    }
    WakelockPlus.disable().catchError((_) {});
    Helper.setSpeakerphoneOn(false).catchError((_) {});
  }

  void _resetState() {
    phase = CallPhase.idle;
    waitingNotice = null;
    call = null;
    peer = null;
    muted = false;
    cameraOff = false;
    frontCamera = true;
    remoteMuted = false;
    remoteVideoOff = false;
    hasRemoteVideo = false;
    remoteSharing = false;
    sharingScreen = false;
    endedText = null;
    canRate = false;
    elapsed = Duration.zero;
    _connectedAt = null;
    _pendingCandidates.clear();
    _pendingOffer = null;
    _remoteSet = false;
    _restartTried = false;
    _cancelled = false;
  }

  static List<Map<String, dynamic>> _parseIce(dynamic raw) {
    final list = raw is List ? raw : const [];
    return list.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }

  static String _mediaError(Object e) {
    final s = '$e'.toLowerCase();
    if (s.contains('permission') || s.contains('notallowed') || s.contains('denied')) {
      return 'Allow microphone (and camera) access in your phone settings to make calls';
    }
    return 'Could not start the call';
  }

  @override
  void dispose() {
    _sub?.cancel();
    _cleanupMedia();
    if (_renderersReady) {
      localRenderer.dispose();
      remoteRenderer.dispose();
    }
    super.dispose();
  }
}
