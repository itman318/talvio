import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:proximity_sensor/proximity_sensor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'services.dart';

/// Remembers which voice messages were played (the "new" dot on unplayed ones).
class PlayedVoices {
  PlayedVoices._();
  static const _key = 'played_voice_ids';
  static final Set<int> _ids = {};
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final l = (await SharedPreferences.getInstance()).getStringList(_key) ?? const [];
      _ids.addAll(l.map(int.tryParse).whereType<int>());
    } catch (_) {}
  }

  static bool played(int id) => _ids.contains(id);

  static Future<void> mark(int id) async {
    if (!_ids.add(id)) return;
    try {
      final list = _ids.toList();
      await (await SharedPreferences.getInstance())
          .setStringList(_key, list.sublist(list.length > 600 ? list.length - 600 : 0).map((e) => '$e').toList());
    } catch (_) {}
  }
}

/// The one voice-message player of the app.
///
/// * only one voice message plays at a time;
/// * when it ends, the next unplayed voice message in that chat starts by itself;
/// * it keeps playing when you leave the chat (a mini player shows it);
/// * held to the ear (proximity sensor) the sound moves to the earpiece and the screen turns off.
class VoicePlayback extends ChangeNotifier {
  VoicePlayback(this.services) {
    _stateSub = player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _onFinished();
      } else {
        notifyListeners();
      }
    });
    PlayedVoices.load();
    SharedPreferences.getInstance().then((p) {
      final v = p.getDouble('voice.speed');
      if (v != null && const [1.0, 1.5, 2.0].contains(v)) speed = v;
    }).catchError((_) {});
  }

  final AppServices services;
  final player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<int>? _proxSub;

  /// Messages of a chat, newest first (set by the app from ChatStore).
  List<Message> Function(int chatId)? messagesOf;

  /// My user id (auto-play skips my own voice messages).
  int? Function()? myId;

  Message? current;
  String title = '';
  bool loading = false;
  double speed = 1.0;
  bool earpiece = false;

  bool get playing => player.playing;
  bool isCurrent(Message m) => current != null && current!.id == m.id && current!.chatId == m.chatId;

  Future<void> toggle(Message m, {String title = ''}) async {
    if (isCurrent(m)) {
      if (player.playing) {
        await player.pause();
      } else {
        await player.play();
      }
      notifyListeners();
      return;
    }
    await play(m, title: title);
  }

  Future<void> play(Message m, {String title = ''}) async {
    if (m.media == null) return;
    current = m;
    this.title = title.isNotEmpty ? title : (m.sender?.name ?? 'Voice message');
    loading = true;
    notifyListeners();
    try {
      final File f = (m.localFilePath != null && File(m.localFilePath!).existsSync())
          ? File(m.localFilePath!)
          : await services.media.get(m.media!);
      if (!isCurrent(m)) return; // another one was started meanwhile
      await player.setFilePath(f.path);
      await player.setSpeed(speed);
      loading = false;
      notifyListeners();
      if (!m.isLocal) {
        final firstTime = !PlayedVoices.played(m.id);
        PlayedVoices.mark(m.id);
        // tell the sender it was listened to (their mic turns blue)
        if (firstTime && m.senderId != null && m.senderId != myId?.call()) {
          unawaited(services.api.post('/messages/${m.id}/played').catchError((_) => null));
        }
      }
      _startProximity();
      unawaited(player.play());
    } catch (e) {
      debugPrint('voice: $e');
      loading = false;
      if (isCurrent(m)) current = null;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> pause() async {
    await player.pause();
    notifyListeners();
  }

  Future<void> seekFraction(double f) async {
    final d = player.duration;
    if (d == null) return;
    await player.seek(Duration(milliseconds: (d.inMilliseconds * f.clamp(0.0, 1.0)).round()));
  }

  void cycleSpeed() {
    speed = speed == 1.0 ? 1.5 : (speed == 1.5 ? 2.0 : 1.0);
    player.setSpeed(speed);
    notifyListeners();
    // remembered for the next voice messages too
    SharedPreferences.getInstance().then((p) => p.setDouble('voice.speed', speed)).catchError((_) => false);
  }

  /// Stops and hides the mini player.
  Future<void> stop() async {
    await player.stop();
    current = null;
    _stopProximity();
    notifyListeners();
  }

  void _onFinished() {
    final done = current;
    player.pause();
    player.seek(Duration.zero);
    final next = done == null ? null : _nextUnplayed(done);
    if (next != null) {
      play(next).catchError((_) {});
    } else {
      current = null;
      _stopProximity();
      notifyListeners();
    }
  }

  /// The next (older → newer) voice message in the same chat that I haven't played.
  Message? _nextUnplayed(Message after) {
    final list = messagesOf?.call(after.chatId) ?? const <Message>[];
    final me = myId?.call();
    Message? best;
    for (final m in list) {
      if (m.type != 'voice' || m.isLocal || m.viewOnce || m.id <= after.id) continue;
      if (m.senderId == me || PlayedVoices.played(m.id)) continue;
      if (best == null || m.id < best.id) best = m;
    }
    return best;
  }

  // ------------------------------------------------------------------ earpiece
  void _startProximity() {
    if (!Platform.isAndroid || _proxSub != null) return;
    try {
      ProximitySensor.setProximityScreenOff(true).catchError((_) {});
      _proxSub = ProximitySensor.events.listen((v) => _setEarpiece(v > 0), onError: (_) {});
    } catch (_) {}
  }

  void _stopProximity() {
    _proxSub?.cancel();
    _proxSub = null;
    if (!Platform.isAndroid) return;
    try {
      ProximitySensor.setProximityScreenOff(false).catchError((_) {});
    } catch (_) {}
    if (earpiece) _setEarpiece(false);
  }

  Future<void> _setEarpiece(bool on) async {
    if (on == earpiece) return;
    earpiece = on;
    notifyListeners();
    try {
      final am = AndroidAudioManager();
      await am.setMode(on ? AndroidAudioHardwareMode.inCommunication : AndroidAudioHardwareMode.normal);
      await am.setSpeakerphoneOn(!on);
      await player.setAndroidAudioAttributes(AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: on ? AndroidAudioUsage.voiceCommunication : AndroidAudioUsage.media,
      ));
    } catch (e) {
      debugPrint('earpiece: $e');
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _proxSub?.cancel();
    player.dispose();
    super.dispose();
  }
}
