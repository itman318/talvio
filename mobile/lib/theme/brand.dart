import 'package:flutter/material.dart';

/// Talvio's own look ("Ember"): warm coral + ink, rounded "pebble" bubbles, soft dotted chat wallpaper.
/// Change these constants to re-brand the whole app.
class Brand {
  Brand._();

  // core palette
  static const primary = Color(0xFFF2603D); // ember coral
  static const primaryDeep = Color(0xFFD4452A);
  static const primaryLight = Color(0xFFFF8E70);
  static const rose = Color(0xFFE9447A);
  static const accent = Color(0xFF12B3A3); // mint: online, read, success
  static const amber = Color(0xFFFFB547);
  static const ink = Color(0xFF1D1B2F);
  /// Secondary text/icons readable on both the light and the dark background.
  static const muted = Color(0xFF8C8296);
  static const faint = Color(0xFFA9A2B5);
  static const premium = Color(0xFF8B6CF6);

  // gradients
  static const mineGradient = LinearGradient(colors: [primary, rose], begin: Alignment.topLeft, end: Alignment.bottomRight);
  static const storyGradient = SweepGradient(colors: [primary, amber, rose, primary]);
  static const heroGradient = LinearGradient(colors: [Color(0xFFFF7A50), primary, rose], begin: Alignment.topLeft, end: Alignment.bottomRight);

  /// Avatar gradients (initials avatars get one of these by id).
  static const avatarGradients = [
    [Color(0xFFFF8A65), Color(0xFFF2603D)],
    [Color(0xFFF06292), Color(0xFFE9447A)],
    [Color(0xFF9575CD), Color(0xFF6C4FE0)],
    [Color(0xFF4DD0C4), Color(0xFF12B3A3)],
    [Color(0xFFFFCA6B), Color(0xFFFF9F43)],
    [Color(0xFF64B5F6), Color(0xFF3F7FE0)],
    [Color(0xFF81C784), Color(0xFF3FA66B)],
    [Color(0xFFA1887F), Color(0xFF7B5E57)],
  ];

  static ThemeData light() => _theme(Brightness.light);
  static ThemeData dark() => _theme(Brightness.dark);

  static ThemeData _theme(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: primary, brightness: b).copyWith(
      primary: dark ? primaryLight : primary,
      onPrimary: Colors.white,
      secondary: accent,
      tertiary: rose,
      surface: dark ? const Color(0xFF17162A) : const Color(0xFFFFFFFF),
      surfaceContainerHighest: dark ? const Color(0xFF2A2840) : const Color(0xFFF4EFEA),
      onSurface: dark ? const Color(0xFFECEAF4) : ink,
      outlineVariant: dark ? const Color(0xFF2E2C44) : const Color(0xFFEDE6DF),
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: b);
    return base.copyWith(
      scaffoldBackgroundColor: dark ? const Color(0xFF121120) : const Color(0xFFFBF8F5),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: dark ? const Color(0xFF121120) : const Color(0xFFFBF8F5),
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: scheme.onSurface, letterSpacing: -0.2),
      ),
      textTheme: base.textTheme.apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF1F1E33) : const Color(0xFFF4EFEA),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.primary, width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF1C1B2F) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      chipTheme: base.chipTheme.copyWith(shape: const StadiumBorder(), side: BorderSide.none),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 0,
        backgroundColor: dark ? const Color(0xFF17162A) : Colors.white,
        indicatorColor: primary.withAlpha(dark ? 60 : 36),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontSize: 12,
              fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
              color: s.contains(WidgetState.selected) ? scheme.primary : scheme.onSurface.withAlpha(160),
            )),
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? scheme.primary : scheme.onSurface.withAlpha(160))),
      ),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
      snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: ink, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? primary : null),
      ),
    );
  }
}

/// The app's mark: two overlapping rounded "pebbles" (drawn, so no image asset is needed).
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 72});
  final double size;

  @override
  Widget build(BuildContext context) {
    // Align(1,1) keeps the mark square even inside a Column that stretches its children.
    return Align(
      widthFactor: 1,
      heightFactor: 1,
      child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(gradient: Brand.heroGradient, borderRadius: BorderRadius.circular(size * 0.3), boxShadow: [
        BoxShadow(color: Brand.primary.withAlpha(90), blurRadius: size * 0.35, offset: Offset(0, size * 0.12)),
      ]),
      child: CustomPaint(painter: _MarkPainter()),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final w = s.shortestSide;
    final back = RRect.fromRectAndCorners(
      Rect.fromLTWH(w * 0.36, w * 0.22, w * 0.42, w * 0.34),
      topLeft: Radius.circular(w * 0.17), topRight: Radius.circular(w * 0.17), bottomLeft: Radius.circular(w * 0.17), bottomRight: Radius.circular(w * 0.05),
    );
    canvas.drawRRect(back, Paint()..color = Colors.white.withAlpha(120));
    final front = RRect.fromRectAndCorners(
      Rect.fromLTWH(w * 0.2, w * 0.36, w * 0.46, w * 0.38),
      topLeft: Radius.circular(w * 0.19), topRight: Radius.circular(w * 0.19), bottomRight: Radius.circular(w * 0.19), bottomLeft: Radius.circular(w * 0.05),
    );
    canvas.drawRRect(front, Paint()..color = Colors.white);
    final dot = Paint()..color = Brand.primary;
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(Offset(w * (0.33 + i * 0.1), w * 0.55), w * 0.032, dot);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Soft dotted wallpaper behind chats.
class ChatWallpaper extends StatelessWidget {
  const ChatWallpaper({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      painter: _DotsPainter(
        bg: dark ? const Color(0xFF121120) : const Color(0xFFF5EEE7),
        dot: dark ? const Color(0xFF1E1C33) : const Color(0xFFEBDDD1),
      ),
      child: child,
    );
  }
}

class _DotsPainter extends CustomPainter {
  _DotsPainter({required this.bg, required this.dot});
  final Color bg;
  final Color dot;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final p = Paint()..color = dot;
    const gap = 22.0;
    for (var y = 0.0, row = 0; y < size.height + gap; y += gap, row++) {
      for (var x = (row.isOdd ? gap / 2 : 0.0); x < size.width + gap; x += gap) {
        canvas.drawCircle(Offset(x, y), 1.6, p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotsPainter old) => old.bg != bg || old.dot != dot;
}
