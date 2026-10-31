import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socks5_proxy/socks_client.dart';

import '../config.dart';

/// One proxy server: SOCKS5 or HTTP (CONNECT), optional username & password.
class ProxyServer {
  ProxyServer({required this.type, required this.host, required this.port, this.username = '', this.password = '', this.name = ''});

  final String type; // 'socks5' | 'http'
  final String host;
  final int port;
  final String username;
  final String password;
  final String name;

  String get id => '$type://$host:$port';
  String get label => name.isNotEmpty ? name : '$host:$port';
  String get typeLabel => type == 'http' ? 'HTTP' : 'SOCKS5';

  Map<String, dynamic> toJson() => {'type': type, 'host': host, 'port': port, 'user': username, 'pass': password, 'name': name};

  factory ProxyServer.fromJson(Map<String, dynamic> j) => ProxyServer(
        type: j['type'] == 'http' ? 'http' : 'socks5',
        host: '${j['host']}',
        port: (j['port'] as num).toInt(),
        username: '${j['user'] ?? ''}',
        password: '${j['pass'] ?? ''}',
        name: '${j['name'] ?? ''}',
      );

  /// talvio://proxy?type=socks5&server=1.2.3.4&port=1080&user=a&pass=b
  String get link => Uri(scheme: 'talvio', host: 'proxy', queryParameters: {
        'type': type,
        'server': host,
        'port': '$port',
        if (username.isNotEmpty) 'user': username,
        if (password.isNotEmpty) 'pass': password,
        if (name.isNotEmpty) 'name': name,
      }).toString();

  /// Reads talvio://proxy?…, https://<our server>/proxy?…, and tg-style socks links.
  static ProxyServer? fromLink(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    final talvio = uri.scheme == 'talvio' && uri.host == 'proxy';
    final web = (uri.scheme == 'http' || uri.scheme == 'https') && uri.path.replaceAll('/', '') == 'proxy';
    if (!talvio && !web && uri.scheme != 'socks5') return null;
    if (uri.scheme == 'socks5') {
      final info = uri.userInfo.split(':');
      return ProxyServer(type: 'socks5', host: uri.host, port: uri.port == 0 ? 1080 : uri.port, username: info.first, password: info.length > 1 ? info[1] : '');
    }
    final q = uri.queryParameters;
    final host = q['server'] ?? '';
    final port = int.tryParse(q['port'] ?? '');
    if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
    return ProxyServer(type: q['type'] == 'http' ? 'http' : 'socks5', host: host, port: port, username: q['user'] ?? '', password: q['pass'] ?? '', name: q['name'] ?? '');
  }
}

/// Like Telegram's proxy settings: a saved list, one active proxy, every connection goes through it
/// (API calls, the live socket, media and pictures) via a global HttpOverrides.
class ProxyManager extends ChangeNotifier {
  ProxyManager._();
  static final ProxyManager instance = ProxyManager._();

  final List<ProxyServer> servers = [];
  bool enabled = false;
  String? activeId;
  final Map<String, int?> pings = {}; // ms, null = failed
  final Set<String> checking = {};

  /// Called after the proxy changed: drop pooled connections, reconnect the socket.
  VoidCallback? onChanged;

  ProxyServer? get active {
    if (!enabled) return null;
    for (final s in servers) {
      if (s.id == activeId) return s;
    }
    return null;
  }

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('proxy.list');
      if (raw != null) {
        servers
          ..clear()
          ..addAll((jsonDecode(raw) as List).map((j) => ProxyServer.fromJson(Map<String, dynamic>.from(j as Map))));
      }
      enabled = p.getBool('proxy.enabled') ?? false;
      activeId = p.getString('proxy.active');
    } catch (_) {}
    await _apply();
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('proxy.list', jsonEncode(servers.map((s) => s.toJson()).toList()));
      await p.setBool('proxy.enabled', enabled);
      if (activeId == null) {
        await p.remove('proxy.active');
      } else {
        await p.setString('proxy.active', activeId!);
      }
    } catch (_) {}
  }

  Future<void> _apply() async {
    final s = active;
    if (s == null) {
      HttpOverrides.global = null;
    } else {
      InternetAddress? addr;
      if (s.type == 'socks5') {
        try {
          addr = InternetAddress.tryParse(s.host) ?? (await InternetAddress.lookup(s.host).timeout(const Duration(seconds: 8))).first;
        } catch (_) {
          addr = null;
        }
      }
      HttpOverrides.global = _ProxyOverrides(s, addr);
    }
    onChanged?.call();
    notifyListeners();
  }

  Future<void> add(ProxyServer s, {bool use = true}) async {
    servers.removeWhere((x) => x.id == s.id);
    servers.insert(0, s);
    if (use) {
      activeId = s.id;
      enabled = true;
    }
    await _save();
    await _apply();
    unawaited(check(s));
  }

  Future<void> remove(ProxyServer s) async {
    servers.removeWhere((x) => x.id == s.id);
    if (activeId == s.id) {
      activeId = servers.isEmpty ? null : servers.first.id;
      if (activeId == null) enabled = false;
    }
    await _save();
    await _apply();
  }

  Future<void> use(ProxyServer s) async {
    activeId = s.id;
    enabled = true;
    notifyListeners();
    await _save();
    await _apply();
  }

  Future<void> setEnabled(bool on) async {
    enabled = on && servers.isNotEmpty;
    if (servers.isNotEmpty && !servers.any((x) => x.id == activeId)) activeId = servers.first.id;
    notifyListeners(); // flip the switch right away; the DNS lookup below can take a moment
    await _save();
    await _apply();
  }

  /// Time to reach our server through [s] (null = it doesn't work).
  Future<int?> check(ProxyServer s) async {
    checking.add(s.id);
    notifyListeners();
    int? ms;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      _configure(client, s, s.type == 'socks5' ? (InternetAddress.tryParse(s.host) ?? (await InternetAddress.lookup(s.host)).first) : null);
      final sw = Stopwatch()..start();
      final req = await client.getUrl(Uri.parse('${AppConfig.serverUrl}/health')).timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      if (res.statusCode < 500) ms = sw.elapsedMilliseconds;
    } catch (_) {
      ms = null;
    } finally {
      client.close(force: true);
    }
    pings[s.id] = ms;
    checking.remove(s.id);
    notifyListeners();
    return ms;
  }

  Future<void> checkAll() async {
    await Future.wait(servers.map(check));
  }
}

void _configure(HttpClient client, ProxyServer s, InternetAddress? socksAddress) {
  if (s.type == 'http') {
    client.findProxy = (_) => 'PROXY ${s.host}:${s.port}';
    if (s.username.isNotEmpty) {
      client.addProxyCredentials(s.host, s.port, '', HttpClientBasicCredentials(s.username, s.password));
    }
  } else if (socksAddress != null) {
    SocksTCPClient.assignToHttpClient(client, [
      ProxySettings(socksAddress, s.port, username: s.username.isEmpty ? null : s.username, password: s.password.isEmpty ? null : s.password),
    ]);
  }
}

class _ProxyOverrides extends HttpOverrides {
  _ProxyOverrides(this.server, this.socksAddress);
  final ProxyServer server;
  final InternetAddress? socksAddress;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final c = super.createHttpClient(context);
    _configure(c, server, socksAddress);
    return c;
  }
}
