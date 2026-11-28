import 'package:flutter/material.dart';

/// Hushavia's look ("Midnight & Violet"): deep ink surfaces, one calm violet accent, mint for "secure",
/// champagne gold for Hushavia Plus, Plus Jakarta Sans type. Change these constants to re-brand the app.
class Brand {
  Brand._();

  static const font = 'Jakarta';

  // core palette
  static const primary = Color(0xFF655194); // Hush Violet
  static const primaryDeep = Color(0xFF503D78);
  static const primaryLight = Color(0xFFC8B6EF);
  static const rose = Color(0xFFE0417A);
  static const accent = Color(0xFF369982); // Signal Mint: online, read, secure, success
  static const amber = Color(0xFFF5B544);
  static const ink = Color(0xFF292634); // headers, my bubbles, dark surfaces
  static const inkSoft = Color(0xFF383344);
  /// Secondary text/icons readable on both the light and the dark background.
  static const muted = Color(0xFF6D6879);
  static const faint = Color(0xFF959AAF);
  static const premium = Color(0xFFC9A45C); // champagne gold (Hushavia Plus)
  static const violet = Color(0xFF74599D);
  static const sky = Color(0xFF3C9BEA);
  static const green = Color(0xFF22B573);

  /// Signature "Aurora" gradient: orchid to plum. Buttons, badges, story rings, highlights.
  static const aurora = LinearGradient(
    colors: [Color(0xFF80689F), Color(0xFF655194), Color(0xFF51416D)],
    stops: [0, 0.5, 1],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// A very light aurora wash for backgrounds behind illustrations and headers.
  static LinearGradient auroraSoft(bool dark) => LinearGradient(
        colors: dark
            ? const [Color(0xFF1E1A3E), Color(0xFF16233A)]
            : const [Color(0xFFF5F0F7), Color(0xFFECE4F2), Color(0xFFE7F1ED)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  // gradients
  static const mineGradient = LinearGradient(colors: [Color(0xFF796195), Color(0xFF584573)], begin: Alignment.topLeft, end: Alignment.bottomRight);
  static const storyGradient = SweepGradient(colors: [Color(0xFF80689F), Color(0xFF655194), Color(0xFF3FD8C0), Color(0xFF8F72FF), Color(0xFF80689F)]);
  static const heroGradient = LinearGradient(colors: [Color(0xFF80689F), primary, Color(0xFF51416D)], begin: Alignment.topLeft, end: Alignment.bottomRight);
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

  static final _lightTheme = _theme(Brightness.light);
  static final _darkTheme = _theme(Brightness.dark);

  static ThemeData light() => _lightTheme;
  static ThemeData dark() => _darkTheme;

  static ThemeData _theme(Brightness b) {
    final dark = b == Brightness.dark;
    final bg = dark ? const Color(0xFF191820) : const Color(0xFFF6F4F7);
    final surface = dark ? const Color(0xFF23212B) : Colors.white;
    final scheme = ColorScheme.fromSeed(seedColor: primary, brightness: b).copyWith(
      primary: dark ? primaryLight : primary,
      onPrimary: dark ? ink : Colors.white,
      secondary: accent,
      tertiary: rose,
      surface: surface,
      surfaceContainerHighest: dark ? const Color(0xFF37323F) : const Color(0xFFEEEAF0),
      surfaceContainerHigh: dark ? const Color(0xFF302C37) : const Color(0xFFF1EEF3),
      surfaceContainer: dark ? const Color(0xFF2C2932) : const Color(0xFFF6F4F7),
      surfaceContainerLow: dark ? const Color(0xFF26232D) : const Color(0xFFFAF8FB),
      onSurface: dark ? const Color(0xFFF3EFF5) : const Color(0xFF23212B),
      onSurfaceVariant: dark ? const Color(0xFFBDB5C7) : const Color(0xFF625D6C),
      outline: dark ? const Color(0xFF3A4060) : const Color(0xFFD5D9E4),
      outlineVariant: dark ? const Color(0xFF39353F) : const Color(0xFFE6E1E9),
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: b, fontFamily: font);
    final text = base.textTheme.apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface).copyWith(
          headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6, color: scheme.onSurface),
          titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3, color: scheme.onSurface),
          titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.43, color: scheme.onSurface),
        );
    final radius12 = BorderRadius.circular(12);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      textTheme: text,
      // screens glide in (a short slide + fade) instead of the heavier zoom
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      }),
      // a clean, quick ripple (the sparkle one is slower to draw)
      splashFactory: InkRipple.splashFactory,
      splashColor: primary.withValues(alpha: dark ? 0.16 : 0.10),
      highlightColor: primary.withValues(alpha: dark ? 0.08 : 0.05),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: dark ? primaryLight : primary,
        selectionColor: primary.withValues(alpha: dark ? 0.45 : 0.24),
        selectionHandleColor: dark ? primaryLight : primary,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: dark ? primaryLight : primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: dark ? primaryLight : primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontFamily: font, fontWeight: FontWeight.w700, fontSize: 14.5),
        unselectedLabelStyle: const TextStyle(fontFamily: font, fontWeight: FontWeight.w600, fontSize: 14.5),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: dark ? const Color(0xFF262B49) : ink, borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontFamily: font, color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        waitDuration: const Duration(milliseconds: 400),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(3.5),
        radius: const Radius.circular(4),
        thumbColor: WidgetStatePropertyAll(scheme.onSurface.withValues(alpha: 0.22)),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: dark ? primaryLight : primary,
        inactiveTrackColor: scheme.outlineVariant,
        thumbColor: dark ? primaryLight : primary,
        overlayColor: primary.withValues(alpha: 0.14),
        trackHeight: 3.5,
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: bg,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(fontFamily: font, fontSize: 21, fontWeight: FontWeight.w700, color: scheme.onSurface, letterSpacing: -0.5),
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
          backgroundColor: primary,
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
        fillColor: scheme.surfaceContainerHighest,
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
        backgroundColor: scheme.surfaceContainerHighest,
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
        indicatorColor: dark ? const Color(0xFF40364F) : const Color(0xFFECE4F2),
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

/// The app's mark: a speech bubble folded from one sheet of paper, in a violet circle
/// (drawn, so no image asset is needed — same art as the app icon).
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
          gradient: const LinearGradient(colors: [Color(0xFF8F72FF), Color(0xFF4E2FE0)], begin: Alignment(-0.7, -1), end: Alignment(0.7, 1)),
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: const Color(0xFF655194).withAlpha(70), blurRadius: size * 0.3, offset: Offset(0, size * 0.1))],
        ),
        child: CustomPaint(painter: _MarkPainter()),
      ),
    );
  }
}

/// The folded bubble: upper fold white, lower fold lilac, a mint "seal" dot (100-unit box).
class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final k = s.shortestSide / 100;
    canvas.save();
    canvas.scale(k);
    Path poly(List<double> p) {
      final path = Path()..moveTo(p[0], p[1]);
      for (var i = 2; i < p.length; i += 2) {
        path.lineTo(p[i], p[i + 1]);
      }
      return path..close();
    }

    Paint paint(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.fill;
    Paint edge(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeJoin = StrokeJoin.round;
    final up = poly(const [27, 29, 73, 29, 73, 61]);
    final low = poly(const [27, 29, 73, 61, 49, 61, 32, 76, 36, 61, 27, 61]);
    canvas.drawPath(up, paint(Colors.white));
    canvas.drawPath(up, edge(Colors.white));
    canvas.drawPath(low, paint(const Color(0xFFD6CBFF)));
    canvas.drawPath(low, edge(const Color(0xFFD6CBFF)));
    canvas.drawCircle(const Offset(66, 36), 2.6, paint(const Color(0xFF5EF0D2)));
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
