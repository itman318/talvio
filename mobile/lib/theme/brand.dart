import 'package:flutter/material.dart';

/// Talvio's look ("Ink & Coral"): deep ink surfaces, one confident coral accent, cool clean neutrals,
/// champagne gold for Talvio Plus, Plus Jakarta Sans type. Change these constants to re-brand the app.
class Brand {
  Brand._();

  static const font = 'Jakarta';

  // core palette
  static const primary = Color(0xFFEF5A3C); // coral
  static const primaryDeep = Color(0xFFD2432A);
  static const primaryLight = Color(0xFFFF8A6E);
  static const rose = Color(0xFFE0417A);
  static const accent = Color(0xFF10B39A); // mint: online, read, success
  static const amber = Color(0xFFF5B544);
  static const ink = Color(0xFF151A2E); // headers, my bubbles, dark surfaces
  static const inkSoft = Color(0xFF232945);
  /// Secondary text/icons readable on both the light and the dark background.
  static const muted = Color(0xFF656C84);
  static const faint = Color(0xFF959AAF);
  static const premium = Color(0xFFC9A45C); // champagne gold (Talvio Plus)
  static const violet = Color(0xFF7C5CFF);
  static const sky = Color(0xFF3C9BEA);
  static const green = Color(0xFF22B573);

  /// Signature "Aurora" gradient: coral → rose → violet. Buttons, badges, story rings, highlights.
  static const aurora = LinearGradient(
    colors: [Color(0xFFFF7A59), Color(0xFFF0446E), Color(0xFF8B5CF6)],
    stops: [0, 0.55, 1],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// A very light aurora wash for backgrounds behind illustrations and headers.
  static LinearGradient auroraSoft(bool dark) => LinearGradient(
        colors: dark
            ? const [Color(0xFF2A1A2E), Color(0xFF231A3A)]
            : const [Color(0xFFFFEDE7), Color(0xFFFCE7F0), Color(0xFFEEE8FF)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  // gradients
  static const mineGradient = LinearGradient(colors: [Color(0xFF1B2138), Color(0xFF2A3152)], begin: Alignment.topLeft, end: Alignment.bottomRight);
  static const storyGradient = SweepGradient(colors: [Color(0xFFFF7A59), Color(0xFFF0446E), Color(0xFF8B5CF6), Color(0xFFFFB347), Color(0xFFFF7A59)]);
  static const heroGradient = LinearGradient(colors: [Color(0xFFFF7A55), primary, rose], begin: Alignment.topLeft, end: Alignment.bottomRight);
  static const plusGradient = LinearGradient(colors: [Color(0xFFE6C987), Color(0xFFC9A45C), Color(0xFFA9853F)], begin: Alignment.topLeft, end: Alignment.bottomRight);

  /// Avatar gradients (initials avatars get one of these by id) — muted, jewel-toned.
  static const avatarGradients = [
    [Color(0xFFFF8A6E), Color(0xFFE2553A)],
    [Color(0xFFEE6A9A), Color(0xFFC8366E)],
    [Color(0xFF8E7CF0), Color(0xFF5B49D6)],
    [Color(0xFF34CDB6), Color(0xFF0E9A86)],
    [Color(0xFFF7C56B), Color(0xFFE29A2E)],
    [Color(0xFF5DA9F0), Color(0xFF2F6FD0)],
    [Color(0xFF6FCB8C), Color(0xFF2F9D5A)],
    [Color(0xFF8A93B4), Color(0xFF4E5675)],
  ];

  static ThemeData light() => _theme(Brightness.light);
  static ThemeData dark() => _theme(Brightness.dark);

  static ThemeData _theme(Brightness b) {
    final dark = b == Brightness.dark;
    final bg = dark ? const Color(0xFF090B14) : const Color(0xFFF4F5FA);
    final surface = dark ? const Color(0xFF12152A) : Colors.white;
    final scheme = ColorScheme.fromSeed(seedColor: primary, brightness: b).copyWith(
      primary: dark ? primaryLight : primary,
      onPrimary: Colors.white,
      secondary: accent,
      tertiary: rose,
      surface: surface,
      surfaceContainerHighest: dark ? const Color(0xFF1E2238) : const Color(0xFFEEF0F6),
      surfaceContainerHigh: dark ? const Color(0xFF191C31) : const Color(0xFFF1F3F8),
      surfaceContainer: dark ? const Color(0xFF161A2D) : const Color(0xFFF4F5FA),
      surfaceContainerLow: dark ? const Color(0xFF13162A) : const Color(0xFFF8F9FC),
      onSurface: dark ? const Color(0xFFECEEF6) : const Color(0xFF12152A),
      onSurfaceVariant: dark ? const Color(0xFFA3A8BC) : const Color(0xFF5E647A),
      outline: dark ? const Color(0xFF3A4060) : const Color(0xFFD5D9E4),
      outlineVariant: dark ? const Color(0xFF242842) : const Color(0xFFE6E9F1),
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: b, fontFamily: font);
    final text = base.textTheme.apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface).copyWith(
          headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6, color: scheme.onSurface),
          titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3, color: scheme.onSurface),
          titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.35, color: scheme.onSurface),
        );
    final radius12 = BorderRadius.circular(12);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      textTheme: text,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: bg,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(fontFamily: font, fontSize: 21, fontWeight: FontWeight.w800, color: scheme.onSurface, letterSpacing: -0.5),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 2,
        highlightElevation: 4,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: dark ? primary : ink,
          foregroundColor: Colors.white,
          disabledBackgroundColor: scheme.onSurface.withAlpha(30),
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontFamily: font, fontWeight: FontWeight.w700, fontSize: 15, letterSpacing: 0.1),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          side: BorderSide(color: scheme.outline),
          textStyle: const TextStyle(fontFamily: font, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: scheme.primary, textStyle: const TextStyle(fontFamily: font, fontWeight: FontWeight.w600)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? (dark ? const Color(0xFF262B49) : ink) : Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : scheme.onSurface),
          side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius12)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: font, fontWeight: FontWeight.w600)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF181C31) : const Color(0xFFEEF0F6),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.primary, width: 1.6)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE5484D), width: 1.2)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE5484D), width: 1.6)),
        disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (st) => TextStyle(fontWeight: FontWeight.w600, color: st.contains(WidgetState.error) ? const Color(0xFFE5484D) : (st.contains(WidgetState.focused) ? scheme.primary : scheme.onSurfaceVariant)),
        ),
        prefixIconColor: WidgetStateColor.resolveWith((st) => st.contains(WidgetState.focused) ? scheme.primary : scheme.onSurfaceVariant),
        suffixIconColor: scheme.onSurfaceVariant,
        helperStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        counterStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11.5),
        errorStyle: const TextStyle(color: Color(0xFFE5484D), fontSize: 12, fontWeight: FontWeight.w500),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: scheme.outlineVariant)),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: radius12),
        side: BorderSide.none,
        backgroundColor: dark ? const Color(0xFF181C31) : const Color(0xFFEEF0F6),
        selectedColor: dark ? const Color(0xFF2A3052) : ink,
        labelStyle: TextStyle(fontFamily: font, fontWeight: FontWeight.w600, color: scheme.onSurface),
        secondaryLabelStyle: const TextStyle(fontFamily: font, fontWeight: FontWeight.w700, color: Colors.white),
        checkmarkColor: Colors.white,
        showCheckmark: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: surface,
        indicatorColor: primary.withValues(alpha: dark ? 0.22 : 0.12),
        indicatorShape: const StadiumBorder(),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontFamily: font,
              fontSize: 12,
              fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
              color: s.contains(WidgetState.selected) ? scheme.onSurface : scheme.onSurfaceVariant,
            )),
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
              color: s.contains(WidgetState.selected) ? (dark ? primaryLight : primary) : scheme.onSurfaceVariant,
            )),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: TextStyle(fontFamily: font, fontSize: 15.5, fontWeight: FontWeight.w600, color: scheme.onSurface),
        subtitleTextStyle: TextStyle(fontFamily: font, fontSize: 13.5, color: scheme.onSurfaceVariant),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        titleTextStyle: TextStyle(fontFamily: font, fontSize: 19, fontWeight: FontWeight.w800, color: scheme.onSurface),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: scheme.outlineVariant)),
        textStyle: TextStyle(fontFamily: font, fontSize: 14.5, color: scheme.onSurface),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? const Color(0xFF262B49) : ink,
        contentTextStyle: const TextStyle(fontFamily: font, color: Colors.white, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      badgeTheme: const BadgeThemeData(backgroundColor: primary, textColor: Colors.white),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : null),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.transparent : null),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? primary : null),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? primary : scheme.onSurfaceVariant)),
    );
  }
}

/// The app's mark: a coral "pebble" behind a white one on deep ink (drawn, so no image asset is needed).
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
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFFFF9A62), Color(0xFFF2557E), Color(0xFF6C4BE0)], stops: [0, 0.48, 1], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(size * 0.227),
          boxShadow: [BoxShadow(color: const Color(0xFFF2557E).withAlpha(70), blurRadius: size * 0.3, offset: Offset(0, size * 0.1))],
        ),
        child: CustomPaint(painter: _MarkPainter()),
      ),
    );
  }
}

/// The Talvio mark (same art as the app icon): a speech bubble holding a "T", with two sparks.
class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final k = s.shortestSide / 512;
    canvas.save();
    canvas.scale(k);
    canvas.drawCircle(const Offset(150, 120), 170, Paint()..color = Colors.white.withAlpha(26));
    final bubble = Path()
      ..moveTo(256, 96)
      ..cubicTo(168, 96, 100, 158, 100, 240)
      ..cubicTo(100, 280, 116, 316, 144, 342)
      ..lineTo(128, 408)
      ..cubicTo(126, 416, 134, 422, 141, 418)
      ..lineTo(211, 380)
      ..cubicTo(225, 384, 240, 386, 256, 386)
      ..cubicTo(344, 386, 412, 324, 412, 240)
      ..cubicTo(412, 156, 344, 96, 256, 96)
      ..close();
    canvas.drawPath(bubble, Paint()..color = Colors.white);
    final t = Paint()..shader = const LinearGradient(colors: [Color(0xFFF2557E), Color(0xFF6C4BE0)], begin: Alignment.topLeft, end: Alignment.bottomRight).createShader(const Rect.fromLTWH(178, 170, 156, 150));
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(178, 170, 156, 44), const Radius.circular(22)), t);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(234, 170, 44, 150), const Radius.circular(22)), t);
    canvas.drawCircle(const Offset(372, 128), 16, Paint()..color = Colors.white);
    canvas.drawCircle(const Offset(404, 98), 8, Paint()..color = Colors.white.withAlpha(204));
    canvas.restore();
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
        bg: dark ? const Color(0xFF0B0D17) : const Color(0xFFEEF1F7),
        dot: dark ? const Color(0xFF161A2C) : const Color(0xFFE1E5EE),
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
