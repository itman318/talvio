import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/prefs.dart';
import '../theme/brand.dart';
import 'package:provider/provider.dart';

/// Card under a message with the title, description and picture of its first link (filled in by the server).
class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({super.key, required this.data, required this.accent});
  final Map<String, dynamic> data;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final url = '${data['url'] ?? ''}';
    final title = data['title'] as String?;
    final desc = data['description'] as String?;
    final image = data['image'] as String?;
    final site = '${data['site'] ?? ''}';
    final saver = context.select<AppPrefs, bool>((p) => p.dataSaver);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: url.isEmpty ? null : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          color: accent.withAlpha(22),
          borderRadius: BorderRadius.circular(12),
          border: Border(left: BorderSide(color: accent, width: 3)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (image != null && !saver)
            AspectRatio(
              aspectRatio: 1.91,
              child: Image.network(image, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (site.isNotEmpty) Text(site, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: accent, fontWeight: FontWeight.w700, fontSize: 12.5)),
              if (title != null) Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: onSurface)),
              if (desc != null)
                Text(desc, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: onSurface.withAlpha(190), height: 1.3)),
              if (image != null && saver)
                const Padding(padding: EdgeInsets.only(top: 4), child: Text('Image hidden — data saver', style: TextStyle(fontSize: 11.5, color: Brand.muted))),
            ]),
          ),
        ]),
      ),
    );
  }
}
