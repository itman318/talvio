import 'dart:async';
import '../theme/chat_theme.dart';
import 'tali_emoji.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../state/chat_store.dart';
import '../core/prefs.dart';
import 'package:provider/provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../theme/brand.dart';

/// Colours that follow light / dark mode for chat surfaces.
class ChatColors {
  ChatColors._(this.background, this.mine, this.other, this.bar, this.meta);

  final Color background;
  final Color mine;
  final Color other;
  final Color bar;
  final Color meta;

  static ChatColors of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final look = ChatThemeScope.maybeOf(context);
    if (look != null && look.themeId != 'classic') {
      final d = look.def;
      return dark
          ? ChatColors._(d.dark.first, d.mineDark.last, const Color(0xFF171A2C), const Color(0xFF131628), Colors.white60)
          : ChatColors._(d.light.first, d.mine.last, Colors.white, Colors.white, const Color(0xFF7D8399));
    }
    // Ink & Coral: my messages in deep ink (light text), others on clean white cards.
    return dark
        ? ChatColors._(const Color(0xFF0B0D17), const Color(0xFF2A3052), const Color(0xFF171A2C), const Color(0xFF131628), Colors.white60)
        : ChatColors._(const Color(0xFFEEF1F7), Brand.ink, Colors.white, Colors.white, const Color(0xFF7D8399));
  }
}

final _mentionRe = RegExp(r'(@[A-Za-z][A-Za-z0-9_]{3,31})|(https?://\S+)');

/// Message text with highlighted @mentions and tappable links.
class MessageText extends StatelessWidget {
  const MessageText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    if (isOnlyTali(text)) {
      // 1–3 Tali emoji alone: show them big
      return Text.rich(TextSpan(children: taliSpans(text.trim(), base.copyWith(fontSize: 44), scale: 1.0)));
    }
    final accent = Theme.of(context).brightness == Brightness.dark ? Brand.primaryLight : Brand.primaryDeep;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _mentionRe.allMatches(text)) {
      if (m.start > last) spans.addAll(taliSpans(text.substring(last, m.start), base));
      final token = m.group(0)!;
      if (m.group(2) != null) {
        spans.add(TextSpan(
          text: token,
          style: TextStyle(color: accent, decoration: TextDecoration.underline),
          recognizer: TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(token), mode: LaunchMode.externalApplication),
        ));
      } else {
        spans.add(TextSpan(text: token, style: TextStyle(color: accent, fontWeight: FontWeight.w600)));
      }
      last = m.end;
    }
    if (last < text.length) spans.addAll(taliSpans(text.substring(last), base));
    return Text.rich(TextSpan(style: base, children: spans));
  }
}

/// Location card; tap opens the maps app.
class LocationView extends StatefulWidget {
  const LocationView({super.key, required this.message, required this.accent});
  final Message message;
  final Color accent;

  @override
  State<LocationView> createState() => _LocationViewState();
}

/// A location (or live location) in a chat: a small map, the place, and "Open in Maps".
class _LocationViewState extends State<LocationView> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // refresh "updated … ago" / "ends in …" while a live location is running
    if (_liveUntil != null) _tick = Timer.periodic(const Duration(seconds: 30), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  DateTime? get _liveUntil => DateTime.tryParse('${(widget.message.meta?['live'] as Map?)?['until'] ?? ''}')?.toLocal();

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final loc = m.location ?? const {};
    final lat = (loc['lat'] as num?)?.toDouble() ?? 0;
    final lng = (loc['lng'] as num?)?.toDouble() ?? 0;
    final title = '${loc['title'] ?? ''}';
    final liveMeta = m.meta?['live'] as Map?;
    final until = _liveUntil;
    final live = until != null && until.isAfter(DateTime.now()) && liveMeta?['stopped'] != true;
    final updated = DateTime.tryParse('${liveMeta?['updated_at'] ?? ''}')?.toLocal();
    final saver = context.select<AppPrefs, bool>((p) => p.dataSaver);
    final store = context.read<ChatStore>();
    final mine = m.senderId == store.myId;
    final point = LatLng(lat, lng);
    return SizedBox(
      width: 250,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (!saver)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 140,
              child: IgnorePointer(
                child: FlutterMap(
                  key: ValueKey('$lat,$lng'),
                  options: MapOptions(initialCenter: point, initialZoom: 15, interactionOptions: const InteractionOptions(flags: InteractiveFlag.none)),
                  children: [
                    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.talvio.app'),
                    MarkerLayer(markers: [
                      Marker(
                        point: point,
                        width: 44,
                        height: 44,
                        child: Container(
                          decoration: BoxDecoration(
                            color: live ? Brand.primary : widget.accent,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6)],
                          ),
                          child: Icon(live ? Icons.navigation_rounded : Icons.location_on, color: Colors.white, size: 22),
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'), mode: LaunchMode.externalApplication),
          child: Row(children: [
            Icon(live ? Icons.share_location_rounded : Icons.location_on_outlined, color: live ? Brand.primary : widget.accent, size: 20),
            const SizedBox(width: 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(live ? 'Live location' : (until != null ? 'Live location ended' : (title.isEmpty ? 'Location' : title)),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(
                  live
                      ? 'Updated ${updated == null ? 'just now' : _ago(updated)} · ends ${_inTime(until)}'
                      : '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)} · Open in Maps',
                  style: TextStyle(fontSize: 12, color: widget.accent),
                ),
              ]),
            ),
          ]),
        ),
        if (live && mine && !m.isLocal)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => store.live.stop(m.id),
              child: const Text('Stop sharing'),
            ),
          ),
      ]),
    );
  }

  static String _ago(DateTime t) {
    final s = DateTime.now().difference(t).inSeconds;
    if (s < 60) return 'just now';
    if (s < 3600) return '${s ~/ 60} min ago';
    return '${s ~/ 3600} h ago';
  }

  static String _inTime(DateTime t) {
    final m = t.difference(DateTime.now()).inMinutes;
    if (m < 1) return 'soon';
    if (m < 60) return 'in $m min';
    return 'in ${(m / 60).round()} h';
  }
}
