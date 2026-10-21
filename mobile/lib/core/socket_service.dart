import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config.dart';
import 'api_client.dart';

/// Thin wrapper around Socket.IO: authenticates with the current access token,
/// refreshes it on auth errors, and exposes events as a broadcast stream.
class SocketService {
  SocketService(this.api);

  final ApiClient api;
  io.Socket? _socket;
  final _events = StreamController<SocketEvent>.broadcast();
  final _connected = StreamController<bool>.broadcast();
  bool isConnected = false;
  bool _wantConnected = false;

  Stream<SocketEvent> get events => _events.stream;
  Stream<bool> get connectionChanges => _connected.stream;

  static const _serverEvents = [
    'message:new',
    'message:edited',
    'message:deleted',
    'receipt:read',
    'receipt:delivered',
    'chat:updated',
    'chat:removed',
    'typing',
    'presence',
    'user:updated',
    'message:reactions',
    'message:poll',
    'support:updated',
    'session:revoked',
    'call:incoming',
    'call:accepted',
    'call:signal',
    'call:ended',
    'secret:request',
    'secret:accepted',
    'secret:taken',
    'secret:closed',
    'secret:message',
    'secret:delivered',
    'secret:read',
    'secret:typing',
    'secret:deleted',
    'secret:notify',
  ];

  void connect() {
    _wantConnected = true;
    final token = api.accessToken;
    if (token == null) return;
    _socket?.dispose();
    final s = io.io(
      AppConfig.serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .disableAutoConnect()
          .enableReconnection()
          .build(),
    );
    s.onConnect((_) => _setConnected(true));
    s.onDisconnect((_) => _setConnected(false));
    s.onConnectError((err) async {
      _setConnected(false);
      final text = '$err';
      if (text.contains('invalid_token')) {
        // Access token expired while offline → refresh, then reconnect with the new token.
        try {
          await api.refreshTokens();
        } catch (_) {
          return;
        }
        if (_wantConnected) connect();
      } else if (text.contains('session_revoked') || text.contains('account_banned') || text.contains('account_deleted')) {
        _events.add(SocketEvent('session:revoked', {'reason': text}));
      }
    });
    for (final name in _serverEvents) {
      s.on(name, (data) {
        if (data is Map) _events.add(SocketEvent(name, Map<String, dynamic>.from(data)));
      });
    }
    _socket = s;
    s.connect();
  }

  /// Called after a token refresh. The token is only checked during the handshake,
  /// so a live connection keeps working; a dropped one is rebuilt with the new token.
  void updateToken(String token) {
    if (_wantConnected && !isConnected) connect();
  }

  void disconnect() {
    _wantConnected = false;
    _socket?.dispose();
    _socket = null;
    _setConnected(false);
  }

  void _setConnected(bool v) {
    if (isConnected == v) return;
    isConnected = v;
    _connected.add(v);
  }

  void emit(String event, Map<String, dynamic> data) {
    if (isConnected) _socket?.emit(event, data);
  }

  /// Emits with an acknowledgement; throws ApiException-like error map on failure.
  Future<Map<String, dynamic>> request(String event, Map<String, dynamic> data, {Duration timeout = const Duration(seconds: 20)}) {
    final s = _socket;
    if (s == null || !isConnected) {
      return Future.error(ApiException(0, 'network', 'Not connected'));
    }
    final c = Completer<Map<String, dynamic>>();
    s.emitWithAck(event, data, ack: (resp) {
      if (c.isCompleted) return;
      final m = resp is Map ? Map<String, dynamic>.from(resp) : <String, dynamic>{};
      if (m['ok'] == true) {
        c.complete(m);
      } else {
        c.completeError(ApiException(400, (m['error'] ?? 'error') as String, (m['message'] ?? 'Something went wrong') as String, m));
      }
    });
    return c.future.timeout(timeout, onTimeout: () => throw ApiException(0, 'network', 'The server did not respond'));
  }
}

class SocketEvent {
  final String name;
  final Map<String, dynamic> data;
  SocketEvent(this.name, this.data);
}
