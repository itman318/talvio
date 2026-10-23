import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../state/chat_store.dart';

/// Keeps live-location messages up to date while the app is open: a new position at most
/// every ~15 s (or after 25 m of movement), until the time is up or the user stops sharing.
class LiveLocationService {
  LiveLocationService(this.store);
  final ChatStore store;

  final _active = <int, DateTime>{}; // messageId → until
  StreamSubscription<Position>? _sub;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  bool isSharing(int messageId) => _active.containsKey(messageId);

  void start(int messageId, DateTime until) {
    _active[messageId] = until;
    _sub ??= Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 25),
    ).listen(_onPosition, onError: (_) {});
  }

  Future<void> stop(int messageId) async {
    _active.remove(messageId);
    try {
      await store.updateLiveLocation(messageId, stop: true);
    } catch (_) {}
    _maybeCancel();
  }

  Future<void> _onPosition(Position p) async {
    final now = DateTime.now();
    _active.removeWhere((_, until) => until.isBefore(now));
    _maybeCancel();
    if (_active.isEmpty || now.difference(_lastSent).inSeconds < 15) return;
    _lastSent = now;
    for (final id in _active.keys.toList()) {
      try {
        final r = await store.updateLiveLocation(id, lat: p.latitude, lng: p.longitude, accuracy: p.accuracy);
        if (r['ended'] == true) _active.remove(id);
      } catch (_) {}
    }
  }

  void _maybeCancel() {
    if (_active.isEmpty) {
      _sub?.cancel();
      _sub = null;
    }
  }
}
