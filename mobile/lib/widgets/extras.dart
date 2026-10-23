import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
    final accent = Theme.of(context).brightness == Brightness.dark ? Brand.primaryLight : Brand.primaryDeep;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _mentionRe.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
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
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(style: base, children: spans));
  }
}

/// Location card; tap opens the maps app.
class LocationView extends StatelessWidget {
  const LocationView({super.key, required this.message, required this.accent});
  final Message message;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final loc = message.location ?? const {};
    final lat = (loc['lat'] as num?)?.toDouble() ?? 0;
    final lng = (loc['lng'] as num?)?.toDouble() ?? 0;
    final title = '${loc['title'] ?? ''}';
    return InkWell(
      onTap: () => launchUrl(
        Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
        mode: LaunchMode.externalApplication,
      ),
      child: Container(
        width: 230,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: accent.withAlpha(25), borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          CircleAvatar(backgroundColor: accent, child: const Icon(Icons.location_on, color: Colors.white)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title.isEmpty ? 'Location' : title, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}', style: const TextStyle(fontSize: 12)),
              Text('Open in Maps', style: TextStyle(fontSize: 12, color: accent)),
            ]),
          ),
        ]),
      ),
    );
  }
}
