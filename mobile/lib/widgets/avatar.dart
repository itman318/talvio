import 'package:flutter/material.dart';

const _palette = [
  Color(0xFFE57373),
  Color(0xFFF06292),
  Color(0xFFBA68C8),
  Color(0xFF7986CB),
  Color(0xFF4FC3F7),
  Color(0xFF4DB6AC),
  Color(0xFF81C784),
  Color(0xFFFFB74D),
];

Color colorForId(int id) => _palette[id.abs() % _palette.length];

/// Round avatar: network image (public avatar URL) or coloured initials.
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
      decoration: BoxDecoration(color: colorForId(id), shape: BoxShape.circle),
      child: icon != null
          ? Icon(icon, color: Colors.white, size: size * 0.5)
          : Text(_initials, style: TextStyle(color: Colors.white, fontSize: size * 0.38, fontWeight: FontWeight.w600)),
    );
    if (url == null) return fallback;
    return ClipOval(
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (ctx, child, progress) => progress == null ? child : fallback,
      ),
    );
  }
}
