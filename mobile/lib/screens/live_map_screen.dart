import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';

/// Everyone sharing a live location in this chat, together on one map (refreshes every few seconds).
class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key, required this.chat});
  final Chat chat;

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  final _map = MapController();
  List<Message>? _list;
  Timer? _timer;
  bool _fitted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/chats/${widget.chat.id}/live-locations') as Map);
      final list = [for (final j in (r['locations'] as List? ?? const [])) Message.fromJson(Map<String, dynamic>.from(j as Map))];
      if (!mounted) return;
      setState(() {
        _list = list;
        _error = null;
      });
      if (!_fitted && list.isNotEmpty) {
        _fitted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _fitAll());
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  LatLng? _point(Message m) {
    final l = m.location;
    final lat = (l?['lat'] as num?)?.toDouble();
    final lng = (l?['lng'] as num?)?.toDouble();
    return lat == null || lng == null ? null : LatLng(lat, lng);
  }

  void _fitAll() {
    final pts = (_list ?? const <Message>[]).map(_point).whereType<LatLng>().toList();
    if (pts.isEmpty) return;
    try {
      if (pts.length == 1) {
        _map.move(pts.first, 15);
      } else {
        _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(60)));
      }
    } catch (_) {}
  }

  String _ago(Message m) {
    final t = DateTime.tryParse('${(m.meta?['live'] as Map?)?['updated_at'] ?? ''}')?.toLocal() ?? m.createdAt;
    final s = DateTime.now().difference(t).inSeconds;
    if (s < 60) return 'updated just now';
    if (s < 3600) return 'updated ${s ~/ 60} min ago';
    return 'updated ${s ~/ 3600} h ago';
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final myId = context.read<ChatStore>().myId;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final markers = <Marker>[];
    for (final m in list ?? const <Message>[]) {
      final p = _point(m);
      final u = m.sender;
      if (p == null) continue;
      markers.add(Marker(
        point: p,
        width: 54,
        height: 54,
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            gradient: m.senderId == myId ? null : Brand.aurora,
            color: m.senderId == myId ? Brand.sky : null,
            shape: BoxShape.circle,
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 8, offset: Offset(0, 3))],
          ),
          child: ClipOval(child: Avatar(id: u?.id ?? 0, name: u?.name ?? '?', url: u?.avatarAbsolute, size: 46)),
        ),
      ));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live locations'),
        actions: [IconButton(tooltip: 'Show everyone', icon: const Icon(Icons.fit_screen_rounded), onPressed: _fitAll)],
      ),
      body: Column(children: [
        Expanded(
          child: FlutterMap(
            mapController: _map,
            options: const MapOptions(initialCenter: LatLng(30.3753, 69.3451), initialZoom: 4),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.talvio.app'),
              MarkerLayer(markers: markers),
              const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
            ],
          ),
        ),
        Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.32),
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF12152A) : Colors.white,
            boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 12, offset: Offset(0, -2))],
          ),
          child: list == null
              ? Padding(padding: const EdgeInsets.all(24), child: Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator()))
              : list.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Nobody is sharing a live location in this chat right now.\nUse 📎 → Location → Share live location.',
                          textAlign: TextAlign.center, style: TextStyle(color: Brand.muted)),
                    )
                  : ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 6), children: [
                      for (final m in list)
                        ListTile(
                          leading: Avatar(id: m.sender?.id ?? 0, name: m.sender?.name ?? '?', url: m.sender?.avatarAbsolute, size: 40),
                          title: Text(m.senderId == myId ? 'You' : (m.sender?.name ?? 'Someone')),
                          subtitle: Text(_ago(m)),
                          trailing: const Icon(Icons.my_location_rounded, color: Brand.primary),
                          onTap: () {
                            final p = _point(m);
                            if (p != null) _map.move(p, 16);
                          },
                        ),
                    ]),
        ),
      ]),
    );
  }
}
