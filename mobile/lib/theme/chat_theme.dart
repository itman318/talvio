import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';


/// A colour theme for the chat screen: wallpaper colours and my bubble colours (light + dark).
class ChatThemeDef {
  const ChatThemeDef(this.id, this.name, this.light, this.dark, this.lightPattern, this.darkPattern, this.mine, this.mineDark);
  final String id;
  final String name;
  final List<Color> light; // wallpaper gradient (light mode)
  final List<Color> dark; // wallpaper gradient (dark mode)
  final Color lightPattern;
  final Color darkPattern;
  final List<Color> mine; // my bubble gradient (light mode)
  final List<Color> mineDark; // my bubble gradient (dark mode)
}

const chatThemes = <ChatThemeDef>[
  ChatThemeDef('classic', 'Classic', [Color(0xFFEEF1F7), Color(0xFFE6EAF3)], [Color(0xFF0B0D17), Color(0xFF0E1120)], Color(0xFFDCE1EC),
      Color(0xFF181C2F), [Color(0xFF1B2138), Color(0xFF2A3152)], [Color(0xFF2A3052), Color(0xFF353C66)]),
  ChatThemeDef('ocean', 'Ocean', [Color(0xFFDDEFFB), Color(0xFFC6E2F6)], [Color(0xFF07182A), Color(0xFF0C2840)], Color(0xFFBFDDF2),
      Color(0xFF12324D), [Color(0xFF1767CF), Color(0xFF3C9BEA)], [Color(0xFF1558B0), Color(0xFF2F86D6)]),
  ChatThemeDef('forest', 'Forest', [Color(0xFFE2F4EA), Color(0xFFCCEADB)], [Color(0xFF08190F), Color(0xFF0E271B)], Color(0xFFC3E5D2),
      Color(0xFF143424), [Color(0xFF0C8A64), Color(0xFF18B892)], [Color(0xFF0B7556), Color(0xFF13A07E)]),
  ChatThemeDef('sunset', 'Sunset', [Color(0xFFFFEADF), Color(0xFFFFD8E4)], [Color(0xFF21101A), Color(0xFF2D1323)], Color(0xFFFFD3C9),
      Color(0xFF3A1A2C), [Color(0xFFEF5A3C), Color(0xFFE0417A)], [Color(0xFFD2432A), Color(0xFFC23468)]),
  ChatThemeDef('lavender', 'Lavender', [Color(0xFFEDE9FF), Color(0xFFDFD8FF)], [Color(0xFF120F26), Color(0xFF1A1636)], Color(0xFFD9D1FA),
      Color(0xFF241F45), [Color(0xFF5B4BD6), Color(0xFF8E7CF8)], [Color(0xFF4F41BF), Color(0xFF7765E6)]),
  ChatThemeDef('gold', 'Gold', [Color(0xFFFBF3E2), Color(0xFFF3E4C2)], [Color(0xFF17130A), Color(0xFF221B0D)], Color(0xFFEEDDB7),
      Color(0xFF2E2512), [Color(0xFFB8913F), Color(0xFFD7B56A)], [Color(0xFF9C7A33), Color(0xFFC29E52)]),
  ChatThemeDef('midnight', 'Midnight', [Color(0xFFE4E6EE), Color(0xFFD5D9E5)], [Color(0xFF000000), Color(0xFF07080F)], Color(0xFFCDD1DE),
      Color(0xFF10121C), [Color(0xFF0E1122), Color(0xFF232945)], [Color(0xFF1C2140), Color(0xFF2B3360)]),
];

ChatThemeDef chatThemeById(String id) => chatThemes.firstWhere((t) => t.id == id, orElse: () => chatThemes.first);

/// What the user picked: a theme, a background pattern, or their own photo.
class ChatAppearance {
  const ChatAppearance({this.themeId = 'classic', this.pattern = 'doodle', this.photoPath, this.dim = 0.15, this.blur = false});

  final String themeId;
  final String pattern; // doodle | dots | none
  final String? photoPath;
  final double dim; // 0..0.7 darkening over a photo
  final bool blur;

  ChatThemeDef get def => chatThemeById(themeId);

  ChatAppearance copyWith({String? themeId, String? pattern, String? photoPath, bool clearPhoto = false, double? dim, bool? blur}) => ChatAppearance(
        themeId: themeId ?? this.themeId,
        pattern: pattern ?? this.pattern,
        photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
        dim: dim ?? this.dim,
        blur: blur ?? this.blur,
      );

  String toJson() => jsonEncode({'t': themeId, 'p': pattern, if (photoPath != null) 'f': photoPath, 'd': dim, 'b': blur});

  static ChatAppearance fromJson(String? s) {
    if (s == null || s.isEmpty) return const ChatAppearance();
    try {
      final j = jsonDecode(s) as Map;
      final photo = j['f'] as String?;
      return ChatAppearance(
        themeId: (j['t'] ?? 'classic') as String,
        pattern: (j['p'] ?? 'doodle') as String,
        photoPath: photo != null && File(photo).existsSync() ? photo : null,
        dim: ((j['d'] ?? 0.15) as num).toDouble(),
        blur: j['b'] == true,
      );
    } catch (_) {
      return const ChatAppearance();
    }
  }
}

/// Gives the chat screen's widgets (bubbles, colours) the current chat appearance.
class ChatThemeScope extends InheritedWidget {
  const ChatThemeScope({super.key, required this.appearance, required super.child});
  final ChatAppearance appearance;

  static ChatAppearance? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ChatThemeScope>()?.appearance;

  @override
  bool updateShouldNotify(ChatThemeScope old) => old.appearance.toJson() != appearance.toJson();
}

/// My bubble gradient for the current chat theme (null outside a themed chat).
LinearGradient? mineGradientOf(BuildContext context) {
  final a = ChatThemeScope.maybeOf(context);
  if (a == null) return null;
  final dark = Theme.of(context).brightness == Brightness.dark;
  final c = dark ? a.def.mineDark : a.def.mine;
  return LinearGradient(colors: c, begin: Alignment.topLeft, end: Alignment.bottomRight);
}

/// Chat background: theme gradient + pattern, or a photo (dimmed / blurred).
class ChatBackground extends StatelessWidget {
  const ChatBackground({super.key, required this.appearance, required this.child});
  final ChatAppearance appearance;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final def = appearance.def;
    final photo = appearance.photoPath;
    Widget bg;
    if (photo != null) {
      Widget img = Image.file(File(photo), fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true);
      if (appearance.blur) img = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14), child: img);
      bg = Stack(fit: StackFit.expand, children: [
        img,
        ColoredBox(color: Colors.black.withValues(alpha: (appearance.dim + (dark ? 0.2 : 0)).clamp(0.0, 0.85))),
      ]);
    } else {
      bg = CustomPaint(
        painter: _PatternPainter(
          colors: dark ? def.dark : def.light,
          ink: dark ? def.darkPattern : def.lightPattern,
          pattern: appearance.pattern,
        ),
        child: const SizedBox.expand(),
      );
    }
    return Stack(children: [Positioned.fill(child: bg), child]);
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter({required this.colors, required this.ink, required this.pattern});
  final List<Color> colors;
  final Color ink;
  final String pattern;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight).createShader(rect));
    if (pattern == 'dots') {
      final p = Paint()..color = ink;
      const gap = 22.0;
      for (var y = 0.0, row = 0; y < size.height + gap; y += gap, row++) {
        for (var x = (row.isOdd ? gap / 2 : 0.0); x < size.width + gap; x += gap) {
          canvas.drawCircle(Offset(x, y), 1.7, p);
        }
      }
    } else if (pattern == 'doodle') {
      final stroke = Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      const cell = 76.0;
      var i = 0;
      for (var y = -10.0; y < size.height + cell; y += cell) {
        for (var x = -10.0 + ((y / cell).round().isOdd ? cell / 2 : 0); x < size.width + cell; x += cell) {
          canvas.save();
          canvas.translate(x + 20, y + 20);
          canvas.rotate((i * 37 % 50 - 25) * math.pi / 180);
          _doodle(canvas, i % 8, stroke);
          canvas.restore();
          i++;
        }
      }
    }
  }

  void _doodle(Canvas c, int k, Paint p) {
    switch (k) {
      case 0: // chat bubble
        c.drawRRect(RRect.fromLTRBR(-12, -9, 12, 7, const Radius.circular(7)), p);
        c.drawLine(const Offset(-6, 7), const Offset(-9, 13), p);
        break;
      case 1: // heart
        final h = Path()
          ..moveTo(0, 9)
          ..cubicTo(-14, 0, -8, -11, 0, -4)
          ..cubicTo(8, -11, 14, 0, 0, 9);
        c.drawPath(h, p);
        break;
      case 2: // star
        final s = Path();
        for (var j = 0; j < 10; j++) {
          final r = j.isEven ? 11.0 : 5.0;
          final a = -math.pi / 2 + j * math.pi / 5;
          j == 0 ? s.moveTo(r * math.cos(a), r * math.sin(a)) : s.lineTo(r * math.cos(a), r * math.sin(a));
        }
        s.close();
        c.drawPath(s, p);
        break;
      case 3: // paper plane
        final pl = Path()
          ..moveTo(-11, 1)
          ..lineTo(12, -9)
          ..lineTo(3, 10)
          ..lineTo(0, 2)
          ..close();
        c.drawPath(pl, p);
        break;
      case 4: // moon
        final m = Path()
          ..addArc(Rect.fromCircle(center: Offset.zero, radius: 10), math.pi * 0.35, math.pi * 1.3)
          ..arcTo(Rect.fromCircle(center: const Offset(4, -2), radius: 8), math.pi * 1.45, -math.pi * 1.0, false);
        c.drawPath(m, p);
        break;
      case 5: // music note
        c.drawCircle(const Offset(-5, 7), 4, p);
        c.drawLine(const Offset(-1, 7), const Offset(-1, -10), p);
        c.drawLine(const Offset(-1, -10), const Offset(8, -7), p);
        break;
      case 6: // smile
        c.drawCircle(Offset.zero, 10, p);
        c.drawArc(Rect.fromCircle(center: const Offset(0, 1), radius: 5.5), 0.3, math.pi - 0.6, false, p);
        break;
      default: // sparkle
        c.drawLine(const Offset(0, -10), const Offset(0, 10), p);
        c.drawLine(const Offset(-10, 0), const Offset(10, 0), p);
        c.drawLine(const Offset(-5, -5), const Offset(5, 5), p);
        c.drawLine(const Offset(5, -5), const Offset(-5, 5), p);
    }
  }

  @override
  bool shouldRepaint(covariant _PatternPainter old) => old.colors != colors || old.ink != ink || old.pattern != pattern;
}
