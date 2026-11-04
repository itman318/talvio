import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/image_store.dart';
import '../theme/brand.dart';

/// Solid accent per user (names, reply bars); the avatar itself uses the matching gradient.
Color colorForId(int id) => Brand.avatarGradients[id.abs() % Brand.avatarGradients.length][1];
List<Color> gradientForId(int id) => Brand.avatarGradients[id.abs() % Brand.avatarGradients.length];

/// Ember avatar: soft rounded square ("squircle") with a gradient + initials, or the photo.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.id, required this.name, this.url, this.size = 48, this.icon});

  final int id;
  final String name;
  final String? url;
  final double size;
  final IconData? icon;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty && !p.startsWith('@')).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.characters.first;
    final second = parts.length > 1 ? parts[1].characters.first : '';
    return (first + second).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: gradientForId(id), begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(size * 0.34),
      ),
      child: icon != null
          ? Icon(icon, color: Colors.white, size: size * 0.5)
          : Text(_initials, style: TextStyle(color: Colors.white, fontSize: size * 0.38, fontWeight: FontWeight.w600)),
    );
    if (url == null) return fallback;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.34),
      // kept on the phone (a picture's address never changes), so lists open with faces already there
      child: CachedNetworkImage(
        imageUrl: url!,
        cacheManager: imageStore,
        width: size,
        height: size,
        memCacheWidth: px, // decode only as many pixels as shown: far less memory and work
        fit: BoxFit.cover,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }
}
