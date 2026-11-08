import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../theme/brand.dart';

/// Photo editor before sending (like Telegram's): crop & rotate, filters, adjustments,
/// drawing (pen, marker, neon, eraser), text with styles, emoji, undo/redo and before/after.
/// Returns the path of the edited JPEG (or the original path if nothing changed), or null when cancelled.
class ImageEditorScreen extends StatefulWidget {
  const ImageEditorScreen({super.key, required this.path, this.sendLabel = 'Send', this.viewOnce});

  /// When given, a "1" button turns the photo into a view-once photo.
  final ValueNotifier<bool>? viewOnce;
  final String path;
  final String sendLabel;

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

enum _Tool { none, crop, adjust, filters, draw, text }

enum _Brush { pen, marker, neon, eraser }

enum _TextStyle { plain, box, outline }

class _Stroke {
  final List<Offset> points; // normalised 0..1 in image space
  final Color color;
  final double width; // fraction of image width
  final _Brush brush;
  _Stroke(this.points, this.color, this.width, this.brush);
  _Stroke copy() => _Stroke(List.of(points), color, width, brush);
}

class _TextItem {
  Offset pos; // normalised centre
  String text;
  Color color;
  double size; // fraction of image width
  double angle; // radians
  _TextStyle style;
  final bool emoji;
  _TextItem(this.pos, this.text, this.color, this.size, {this.angle = 0, this.style = _TextStyle.plain, this.emoji = false});
  _TextItem copy() => _TextItem(pos, text, color, size, angle: angle, style: style, emoji: emoji);
}

/// Colour & light settings. Filters are presets of the same numbers; the sliders add on top.
class _Look {
  const _Look({this.brightness = 0, this.contrast = 0, this.saturation = 0, this.warmth = 0, this.fade = 0, this.vignette = 0});
  final double brightness, contrast, saturation, warmth, fade, vignette; // −1..1 (fade, vignette 0..1)

  _Look operator +(_Look o) => _Look(
        brightness: (brightness + o.brightness).clamp(-1.0, 1.0),
        contrast: (contrast + o.contrast).clamp(-1.0, 1.0),
        saturation: (saturation + o.saturation).clamp(-1.0, 1.0),
        warmth: (warmth + o.warmth).clamp(-1.0, 1.0),
        fade: (fade + o.fade).clamp(0.0, 1.0),
        vignette: (vignette + o.vignette).clamp(0.0, 1.0),
      );

  double get(String k) => switch (k) {
        'brightness' => brightness,
        'contrast' => contrast,
        'saturation' => saturation,
        'warmth' => warmth,
        'fade' => fade,
        _ => vignette,
      };

  _Look set(String k, double v) => _Look(
        brightness: k == 'brightness' ? v : brightness,
        contrast: k == 'contrast' ? v : contrast,
        saturation: k == 'saturation' ? v : saturation,
        warmth: k == 'warmth' ? v : warmth,
        fade: k == 'fade' ? v : fade,
        vignette: k == 'vignette' ? v : vignette,
      );

  bool get isNeutral => brightness == 0 && contrast == 0 && saturation == 0 && warmth == 0 && fade == 0 && vignette == 0;

  /// One 5×4 colour matrix for all of it (vignette is drawn separately).
  List<double> matrix() {
    var m = _identity();
    if (brightness != 0) m = _mul(_offset(brightness * 70, brightness * 70, brightness * 70), m);
    if (contrast != 0) {
      final s = 1 + contrast * 0.6;
      final t = 128 * (1 - s);
      m = _mul([s, 0, 0, 0, t, 0, s, 0, 0, t, 0, 0, s, 0, t, 0, 0, 0, 1, 0], m);
    }
    if (saturation != 0) m = _mul(_saturate(1 + saturation), m);
    if (warmth != 0) m = _mul(_offset(warmth * 28, warmth * 6, -warmth * 28), m);
    if (fade != 0) {
      final s = 1 - fade * 0.32;
      final t = fade * 0.32 * 118;
      m = _mul([s, 0, 0, 0, t, 0, s, 0, 0, t, 0, 0, s, 0, t, 0, 0, 0, 1, 0], m);
    }
    return m;
  }

  static List<double> _identity() => [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
  static List<double> _offset(double r, double g, double b) => [1, 0, 0, 0, r, 0, 1, 0, 0, g, 0, 0, 1, 0, b, 0, 0, 0, 1, 0];
  static List<double> _saturate(double s) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final a = 1 - s;
    return [
      lr * a + s, lg * a, lb * a, 0, 0, //
      lr * a, lg * a + s, lb * a, 0, 0,
      lr * a, lg * a, lb * a + s, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// a ∘ b (apply b first, then a) for 4×5 colour matrices.
  static List<double> _mul(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 5; c++) {
        var v = 0.0;
        for (var k = 0; k < 4; k++) {
          v += a[r * 5 + k] * b[k * 5 + c];
        }
        if (c == 4) v += a[r * 5 + 4];
        out[r * 5 + c] = v;
      }
    }
    return out;
  }
}

const _filters = <(String, _Look)>[
  ('Original', _Look()),
  ('Vivid', _Look(saturation: 0.35, contrast: 0.15)),
  ('Warm', _Look(warmth: 0.55, saturation: 0.1, brightness: 0.03)),
  ('Cool', _Look(warmth: -0.5, contrast: 0.05)),
  ('B&W', _Look(saturation: -1, contrast: 0.2)),
  ('Vintage', _Look(fade: 0.5, warmth: 0.35, saturation: -0.25, vignette: 0.35)),
  ('Dramatic', _Look(contrast: 0.4, saturation: -0.15, brightness: -0.05, vignette: 0.45)),
  ('Soft', _Look(fade: 0.3, brightness: 0.06, saturation: -0.05)),
  ('Noir', _Look(saturation: -1, contrast: 0.45, brightness: -0.06, vignette: 0.5)),
];

const _adjustments = <(String, String, IconData, bool)>[
  ('brightness', 'Brightness', Icons.wb_sunny_outlined, true),
  ('contrast', 'Contrast', Icons.contrast, true),
  ('saturation', 'Saturation', Icons.palette_outlined, true),
  ('warmth', 'Warmth', Icons.thermostat, true),
  ('fade', 'Fade', Icons.gradient, false),
  ('vignette', 'Vignette', Icons.vignette_outlined, false),
];

const _palette = [
  Colors.white, Colors.black, Color(0xFFE53935), Color(0xFFFF7043), Color(0xFFFFB300), Color(0xFFFFEB3B),
  Color(0xFF43A047), Color(0xFF00BFA5), Color(0xFF1E88E5), Color(0xFF6D4AFF), Color(0xFFD81B60), Color(0xFF8D6E63),
];

const _emojiChoices = [
  '😀', '😂', '🤣', '😍', '🥰', '😎', '🤩', '😜', '🥳', '😭', '😡', '🤔', '😴', '🙏', '👍', '👎', '👏', '💪', '✌️', '🤝',
  '❤️', '🔥', '✨', '💯', '⭐', '🎉', '🎂', '🎁', '☕', '🍕', '⚽', '🏏', '🌙', '☀️', '🌈', '🌸', '🇵🇰', '📍', '✅', '❌',
];

class _Snapshot {
  _Snapshot(this.strokes, this.texts);
  final List<_Stroke> strokes;
  final List<_TextItem> texts;
}

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  ui.Image? _image; // full size (≤ 2560 px) — used only when saving
  ui.Image? _view; // screen size (≤ 1280 px): what the editor draws, so dragging stays smooth
  ui.Image? _thumb; // ≈160 px for the filter previews
  int _rev = 0; // bumps when drawings/texts change (repaint only then)
  _Tool _tool = _Tool.none;
  final List<_Stroke> _strokes = [];
  final List<_TextItem> _texts = [];
  final List<_Snapshot> _undo = [];
  final List<_Snapshot> _redo = [];
  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1); // normalised
  String _aspect = 'free'; // free | original | 1:1 | 4:3 | 3:4 | 16:9 | 9:16
  int _filter = 0;
  _Look _adjust = const _Look();
  String _adjustKey = 'brightness';
  Color _color = const Color(0xFFE53935);
  double _brush = 0.012;
  _Brush _brushKind = _Brush.pen;
  _TextStyle _textStyle = _TextStyle.plain;
  bool _changed = false;
  bool _saving = false;
  bool _showOriginal = false;

  // gesture state (one finger draws / moves, two fingers scale & turn text)
  int? _grab; // text being moved
  double _grabSize = 0, _grabAngle = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Drawings/texts may have changed → the overlay repaints (not while only the crop box moves).
  @override
  void setState(VoidCallback fn) {
    if (_tool != _Tool.crop) _rev++;
    super.setState(fn);
  }

  Future<void> _load() async {
    final bytes = await File(widget.path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    var frame = (await codec.getNextFrame()).image;
    // keep editing fast: at most 2560 px on the long side
    final longSide = math.max(frame.width, frame.height);
    if (longSide > 2560) {
      final s = 2560 / longSide;
      final src = frame;
      frame = await _redraw((src.width * s).round(), (src.height * s).round(), (c, w, h) {
        c.drawImageRect(src, Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()), Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
            Paint()..filterQuality = FilterQuality.high);
      });
    }
    await _setImage(frame);
  }

  /// Keeps the full picture for saving and makes the light copies the editor draws.
  Future<void> _setImage(ui.Image full) async {
    Future<ui.Image> shrink(int maxSide) async {
      final long = math.max(full.width, full.height);
      if (long <= maxSide) return full;
      final s = maxSide / long;
      return _redraw((full.width * s).round(), (full.height * s).round(), (c, w, h) {
        c.drawImageRect(full, Rect.fromLTWH(0, 0, full.width.toDouble(), full.height.toDouble()), Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
            Paint()..filterQuality = FilterQuality.medium);
      });
    }

    final view = await shrink(1280);
    final thumb = await shrink(160);
    if (!mounted) return;
    setState(() {
      _image = full;
      _view = view;
      _thumb = thumb;
    });
  }

  Future<ui.Image> _redraw(int w, int h, void Function(Canvas c, int w, int h) paint) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    paint(c, w, h);
    return rec.endRecording().toImage(w, h);
  }

  _Look get _look => _filters[_filter].$2 + _adjust;

  bool get _dirty => _changed || _filter != 0 || !_adjust.isNeutral || _crop != const Rect.fromLTRB(0, 0, 1, 1);

  // ------------------------------------------------------------------ undo / redo (drawings & texts)
  void _remember() {
    _undo.add(_Snapshot(_strokes.map((s) => s.copy()).toList(), _texts.map((t) => t.copy()).toList()));
    if (_undo.length > 60) _undo.removeAt(0);
    _redo.clear();
  }

  void _restore(List<_Snapshot> from, List<_Snapshot> to) {
    if (from.isEmpty) return;
    to.add(_Snapshot(_strokes.map((s) => s.copy()).toList(), _texts.map((t) => t.copy()).toList()));
    final s = from.removeLast();
    setState(() {
      _strokes
        ..clear()
        ..addAll(s.strokes);
      _texts
        ..clear()
        ..addAll(s.texts);
    });
  }

  // ------------------------------------------------------------------ crop tools
  Future<void> _rotate() async {
    final src = _image;
    if (src == null) return;
    final rotated = await _redraw(src.height, src.width, (c, w, h) {
      c.translate(w.toDouble(), 0);
      c.rotate(math.pi / 2);
      c.drawImage(src, Offset.zero, Paint());
    });
    // everything drawn on top turns 90° clockwise too: (x, y) → (1 - y, x)
    Offset r(Offset p) => Offset(1 - p.dy, p.dx);
    final strokes = _strokes.map((s) => _Stroke(s.points.map(r).toList(), s.color, s.width * src.width / src.height, s.brush)).toList();
    _strokes
      ..clear()
      ..addAll(strokes);
    for (final t in _texts) {
      t.pos = r(t.pos);
      t.size = t.size * src.width / src.height;
      t.angle += math.pi / 2;
    }
    _crop = Rect.fromLTRB(1 - _crop.bottom, _crop.left, 1 - _crop.top, _crop.right);
    if (_aspect != 'free' && _aspect != 'original' && _aspect != '1:1') {
      _aspect = const {'4:3': '3:4', '3:4': '4:3', '16:9': '9:16', '9:16': '16:9'}[_aspect]!;
    }
    _undo.clear();
    _redo.clear();
    _changed = true;
    _rev++;
    await _setImage(rotated);
  }

  /// Mirror left ↔ right.
  Future<void> _flip() async {
    final src = _image;
    if (src == null) return;
    final flipped = await _redraw(src.width, src.height, (c, w, h) {
      c.translate(w.toDouble(), 0);
      c.scale(-1, 1);
      c.drawImage(src, Offset.zero, Paint());
    });
    Offset m(Offset p) => Offset(1 - p.dx, p.dy);
    for (final st in _strokes) {
      for (var i = 0; i < st.points.length; i++) {
        st.points[i] = m(st.points[i]);
      }
    }
    for (final t in _texts) {
      t.pos = m(t.pos);
      t.angle = -t.angle;
    }
    _crop = Rect.fromLTRB(1 - _crop.right, _crop.top, 1 - _crop.left, _crop.bottom);
    _changed = true;
    _rev++;
    await _setImage(flipped);
  }

  double? _ratioFor(String a) {
    final im = _image;
    if (im == null) return null;
    return switch (a) {
      'original' => im.width / im.height,
      '1:1' => 1,
      '4:3' => 4 / 3,
      '3:4' => 3 / 4,
      '16:9' => 16 / 9,
      '9:16' => 9 / 16,
      _ => null,
    };
  }

  /// The chosen ratio in normalised (0..1) crop space.
  double? get _lock {
    final r = _ratioFor(_aspect);
    final im = _image;
    if (r == null || im == null) return null;
    return r * im.height / im.width;
  }

  void _setAspect(String a) {
    HapticFeedback.selectionClick();
    setState(() {
      _aspect = a;
      final n = _lock;
      if (n == null) return;
      // the biggest box of that shape, centred on the current crop
      final c = _crop.center;
      var w = 1.0, h = w / n;
      if (h > 1) {
        h = 1;
        w = h * n;
      }
      final l = (c.dx - w / 2).clamp(0.0, 1 - w), t = (c.dy - h / 2).clamp(0.0, 1 - h);
      _crop = Rect.fromLTWH(l, t, w, h);
    });
  }

  void _resetCrop() => setState(() {
        _crop = const Rect.fromLTRB(0, 0, 1, 1);
        _aspect = 'free';
      });

  // ------------------------------------------------------------------ text & emoji
  Future<void> _editText([int? index]) async {
    final existing = index == null ? null : _texts[index];
    final ctrl = TextEditingController(text: existing?.text ?? '');
    var style = existing?.style ?? _textStyle;
    var color = existing?.color ?? _color;
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF15151C),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(16)),
              child: TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: null,
                maxLength: 200,
                textAlign: TextAlign.center,
                textCapitalization: TextCapitalization.sentences,
                cursorColor: Colors.white,
                style: _textStyleFor(style, color, 26),
                decoration: const InputDecoration(border: InputBorder.none, counterText: '', hintText: 'Type something…', hintStyle: TextStyle(color: Colors.white38)),
                onChanged: (_) => setSheet(() {}),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              for (final s in _TextStyle.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _StyleChip(style: s, selected: s == style, color: color, onTap: () => setSheet(() => style = s)),
                ),
              const Spacer(),
              if (existing != null)
                IconButton(tooltip: 'Delete', onPressed: () => Navigator.pop(ctx, '\u0000delete'), icon: const Icon(Icons.delete_outline, color: Colors.white70)),
            ]),
            const SizedBox(height: 8),
            _ColorRow(selected: color, onPick: (c) => setSheet(() => color = c)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(existing == null ? 'Add text' : 'Done')),
            ),
          ]),
        ),
      ),
    );
    if (result == null || !mounted) return;
    _remember();
    setState(() {
      if (result == '\u0000delete' || (result.isEmpty && existing != null)) {
        _texts.removeAt(index!);
      } else if (result.isNotEmpty) {
        if (existing != null) {
          existing
            ..text = result
            ..style = style
            ..color = color;
        } else {
          _texts.add(_TextItem(const Offset(0.5, 0.45), result, color, 0.075, style: style));
        }
        _textStyle = style;
        _color = color;
      }
      _changed = true;
    });
  }

  Future<void> _addEmoji() async {
    final e = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF15151C),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        child: GridView.count(
          crossAxisCount: 8,
          shrinkWrap: true,
          padding: const EdgeInsets.all(14),
          children: [
            for (final e in _emojiChoices)
              InkWell(borderRadius: BorderRadius.circular(12), onTap: () => Navigator.pop(ctx, e), child: Center(child: Text(e, style: const TextStyle(fontSize: 30)))),
          ],
        ),
      ),
    );
    if (e == null || !mounted) return;
    _remember();
    setState(() {
      _texts.add(_TextItem(Offset(0.5 + (_texts.length % 3 - 1) * 0.08, 0.5), e, Colors.white, 0.16, emoji: true));
      _changed = true;
    });
  }

  // ------------------------------------------------------------------ export
  Future<void> _done() async {
    final src = _image;
    if (src == null) return;
    if (!_dirty) {
      Navigator.pop(context, widget.path);
      return;
    }
    setState(() => _saving = true);
    try {
      final w = src.width;
      final h = src.height;
      final look = _look;
      final full = await _redraw(w, h, (c, _, __) {
        final size = Size(w.toDouble(), h.toDouble());
        c.drawImage(src, Offset.zero, Paint()..colorFilter = ColorFilter.matrix(look.matrix()));
        _paintVignette(c, Offset.zero & size, look.vignette);
        _OverlayPainter(_strokes, _texts).paint(c, size);
      });
      final cr = Rect.fromLTRB(_crop.left * w, _crop.top * h, _crop.right * w, _crop.bottom * h);
      final cw = math.max(1, cr.width.round());
      final ch = math.max(1, cr.height.round());
      final cropped = await _redraw(cw, ch, (c, _, __) {
        c.drawImageRect(full, cr, Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()), Paint()..filterQuality = FilterQuality.high);
      });
      final rgba = await cropped.toByteData(format: ui.ImageByteFormat.rawRgba);
      final jpg = await compute(_encodeJpeg, _RawImage(cw, ch, rgba!.buffer.asUint8List()));
      final dir = await getTemporaryDirectory();
      final out = File('${dir.path}/edited_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await out.writeAsBytes(jpg, flush: true);
      if (mounted) Navigator.pop(context, out.path);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save the photo')));
      }
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty || _saving) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to this photo will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    return ok == true;
  }

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final image = _view;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          leading: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () async {
              if (await _confirmLeave() && context.mounted) Navigator.pop(context);
            },
          ),
          actions: [
            IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: _undo.isEmpty ? null : () => _restore(_undo, _redo), color: Colors.white, disabledColor: Colors.white24),
            IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: _redo.isEmpty ? null : () => _restore(_redo, _undo), color: Colors.white, disabledColor: Colors.white24),
            if (_dirty)
              Listener(
                onPointerDown: (_) => setState(() => _showOriginal = true),
                onPointerUp: (_) => setState(() => _showOriginal = false),
                onPointerCancel: (_) => setState(() => _showOriginal = false),
                child: const Tooltip(
                  message: 'Hold to see the original',
                  child: Padding(padding: EdgeInsets.all(12), child: Icon(Icons.compare, color: Colors.white)),
                ),
              ),
            if (widget.viewOnce != null)
              ValueListenableBuilder<bool>(
                valueListenable: widget.viewOnce!,
                builder: (_, on, __) => IconButton(
                  tooltip: on ? 'View once: on' : 'View once',
                  onPressed: () {
                    widget.viewOnce!.value = !on;
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(content: Text(on ? 'View once is off' : 'View once: it can be opened only one time'), duration: const Duration(seconds: 2)));
                  },
                  icon: ViewOnceIcon(on: on),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 10, left: 4),
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Brand.primary, padding: const EdgeInsets.symmetric(horizontal: 18), shape: const StadiumBorder()),
                onPressed: _saving ? null : _done,
                child: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(widget.sendLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
        body: image == null
            ? const Center(child: CircularProgressIndicator())
            : Column(children: [
                Expanded(child: LayoutBuilder(builder: (ctx, box) => _canvas(image, box))),
                AnimatedSize(duration: const Duration(milliseconds: 180), curve: Curves.easeOut, child: _panel(_thumb ?? image)),
                _toolBar(),
              ]),
      ),
    );
  }

  Widget _canvas(ui.Image image, BoxConstraints box) {
    final ratio = image.width / image.height;
    // room around the picture so crop handles are easy to grab (and away from the phone's back-swipe edge)
    final pad = _tool == _Tool.crop ? 64.0 : 24.0;
    var w = box.maxWidth - pad;
    var h = w / ratio;
    if (h > box.maxHeight - pad) {
      h = box.maxHeight - pad;
      w = h * ratio;
    }
    final size = Size(w, h);
    Offset norm(Offset local) => Offset((local.dx / w).clamp(0.0, 1.0), (local.dy / h).clamp(0.0, 1.0));
    final look = _showOriginal ? const _Look() : _look;

    int? textAt(Offset p) {
      for (var i = _texts.length - 1; i >= 0; i--) {
        final t = _texts[i];
        final reach = math.max(0.08, t.size * (t.emoji ? 0.7 : 1.4));
        if ((t.pos - p).distance < reach) return i;
      }
      return null;
    }

    return Center(
      child: SizedBox(
        width: w,
        height: h,
        child: GestureDetector(
          onTapUp: (d) {
            if (_tool == _Tool.crop || _tool == _Tool.draw) return;
            final i = textAt(norm(d.localPosition));
            if (i != null && !_texts[i].emoji) _editText(i);
          },
          onScaleStart: (d) {
            if (_tool == _Tool.crop) return;
            final p = norm(d.localFocalPoint);
            if (_tool == _Tool.draw && d.pointerCount == 1) {
              _remember();
              if (_brushKind == _Brush.eraser) {
                _erase(p);
              } else {
                setState(() {
                  _strokes.add(_Stroke([p], _color, _brushKind == _Brush.marker ? _brush * 2.2 : _brush, _brushKind));
                  _changed = true;
                });
              }
              return;
            }
            final i = textAt(p);
            if (i != null) {
              _remember();
              _grab = i;
              _grabSize = _texts[i].size;
              _grabAngle = _texts[i].angle;
            }
          },
          onScaleUpdate: (d) {
            if (_tool == _Tool.crop) return;
            final p = norm(d.localFocalPoint);
            if (_tool == _Tool.draw && _grab == null) {
              if (_brushKind == _Brush.eraser) {
                _erase(p);
              } else if (_strokes.isNotEmpty) {
                setState(() => _strokes.last.points.add(p));
              }
              return;
            }
            final g = _grab;
            if (g == null || g >= _texts.length) return;
            setState(() {
              final t = _texts[g];
              t.pos = p;
              if (d.pointerCount > 1) {
                t.size = (_grabSize * d.scale).clamp(0.02, 0.6);
                t.angle = _grabAngle + d.rotation;
              }
              _changed = true;
            });
          },
          onScaleEnd: (_) => _grab = null,
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: Stack(fit: StackFit.expand, children: [
                  ColorFiltered(
                    colorFilter: ColorFilter.matrix(look.matrix()),
                    child: RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.low),
                  ),
                  if (look.vignette > 0) IgnorePointer(child: CustomPaint(painter: _VignettePainter(look.vignette))),
                ]),
              ),
            ),
            if (!_showOriginal)
              Positioned.fill(child: RepaintBoundary(child: IgnorePointer(child: CustomPaint(painter: _OverlayPainter(_strokes, _texts, _rev))))),
            if (_tool == _Tool.crop)
              Positioned.fill(child: _CropOverlay(rect: _crop, size: size, lock: _lock, onChanged: (r) => setState(() => _crop = r)))
            else if (_crop != const Rect.fromLTRB(0, 0, 1, 1))
              Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _ShadePainter(_crop)))),
          ]),
        ),
      ),
    );
  }

  void _erase(Offset p) {
    final before = _strokes.length;
    _strokes.removeWhere((s) => s.points.any((q) => (q - p).distance < math.max(0.03, s.width * 1.5)));
    if (_strokes.length != before) {
      HapticFeedback.selectionClick();
      setState(() => _changed = true);
    }
  }

  // ------------------------------------------------------------------ panels above the tool bar
  Widget _panel(ui.Image image) {
    switch (_tool) {
      case _Tool.crop:
        return _cropPanel();
      case _Tool.adjust:
        return _adjustPanel();
      case _Tool.filters:
        return _filterPanel(image);
      case _Tool.draw:
        return _drawPanel();
      case _Tool.text:
        return _textPanel();
      case _Tool.none:
        return const SizedBox(width: double.infinity);
    }
  }

  Widget _cropPanel() {
    const opts = [('free', 'Free'), ('original', 'Original'), ('1:1', 'Square'), ('4:3', '4:3'), ('3:4', '3:4'), ('16:9', '16:9'), ('9:16', '9:16')];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _RoundAction(icon: Icons.rotate_90_degrees_cw_outlined, label: 'Rotate', onTap: _rotate),
        _RoundAction(icon: Icons.flip, label: 'Mirror', onTap: _flip),
        _RoundAction(icon: Icons.restart_alt, label: 'Reset', onTap: _resetCrop),
      ]),
      SizedBox(
        height: 46,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final o in opts) _Pill(label: o.$2, selected: _aspect == o.$1, onTap: () => _setAspect(o.$1)),
        ]),
      ),
      const SizedBox(height: 6),
    ]);
  }

  Widget _adjustPanel() {
    final cur = _adjust.get(_adjustKey);
    final signed = _adjustments.firstWhere((a) => a.$1 == _adjustKey).$4;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
        child: Row(children: [
          Text(_adjustments.firstWhere((a) => a.$1 == _adjustKey).$2, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(cur == 0 ? '0' : '${cur > 0 && signed ? '+' : ''}${(cur * 100).round()}', style: const TextStyle(color: Colors.white70, fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      ),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: Brand.primary,
          inactiveTrackColor: Colors.white24,
          thumbColor: Colors.white,
          overlayColor: Brand.primary.withAlpha(40),
          trackHeight: 3,
        ),
        child: Slider(
          min: signed ? -1 : 0,
          max: 1,
          value: cur,
          onChanged: (v) => setState(() {
            // snap to 0 near the middle, like Telegram
            _adjust = _adjust.set(_adjustKey, signed && v.abs() < 0.03 ? 0 : v);
          }),
        ),
      ),
      SizedBox(
        height: 74,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          for (final a in _adjustments)
            GestureDetector(
              onTap: () => setState(() => _adjustKey = a.$1),
              onDoubleTap: () => setState(() => _adjust = _adjust.set(a.$1, 0)),
              child: Container(
                width: 76,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Stack(clipBehavior: Clip.none, children: [
                    Icon(a.$3, color: _adjustKey == a.$1 ? Brand.primary : Colors.white, size: 26),
                    if (_adjust.get(a.$1) != 0)
                      Positioned(right: -4, top: -2, child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: Brand.primary, shape: BoxShape.circle))),
                  ]),
                  const SizedBox(height: 6),
                  Text(a.$2, style: TextStyle(color: _adjustKey == a.$1 ? Brand.primary : Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
        ]),
      ),
    ]);
  }

  Widget _filterPanel(ui.Image image) {
    return SizedBox(
      height: 112,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(10, 8, 10, 8), children: [
        for (var i = 0; i < _filters.length; i++)
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _filter = i);
            },
            child: Container(
              width: 70,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 64,
                  height: 64,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _filter == i ? Brand.primary : Colors.transparent, width: 2.5),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Stack(fit: StackFit.expand, children: [
                      ColorFiltered(colorFilter: ColorFilter.matrix(_filters[i].$2.matrix()), child: RawImage(image: image, fit: BoxFit.cover, filterQuality: FilterQuality.low)),
                      if (_filters[i].$2.vignette > 0) CustomPaint(painter: _VignettePainter(_filters[i].$2.vignette)),
                    ]),
                  ),
                ),
                const SizedBox(height: 6),
                Text(_filters[i].$1, style: TextStyle(color: _filter == i ? Brand.primary : Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _drawPanel() {
    const kinds = [(_Brush.pen, Icons.edit, 'Pen'), (_Brush.marker, Icons.brush, 'Marker'), (_Brush.neon, Icons.auto_awesome, 'Neon'), (_Brush.eraser, Icons.cleaning_services_outlined, 'Eraser')];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (final k in kinds) _RoundAction(icon: k.$2, label: k.$3, selected: _brushKind == k.$1, onTap: () => setState(() => _brushKind = k.$1)),
      ]),
      if (_brushKind != _Brush.eraser) ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: _color, shape: BoxShape.circle)),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(activeTrackColor: _color, inactiveTrackColor: Colors.white24, thumbColor: Colors.white, trackHeight: 3),
                child: Slider(min: 0.004, max: 0.04, value: _brush, onChanged: (v) => setState(() => _brush = v)),
              ),
            ),
            Container(width: 22, height: 22, decoration: BoxDecoration(color: _color, shape: BoxShape.circle)),
          ]),
        ),
        _ColorRow(selected: _color, onPick: (c) => setState(() => _color = c)),
      ] else
        const Padding(padding: EdgeInsets.all(10), child: Text('Rub over a line to remove it', style: TextStyle(color: Colors.white54))),
      const SizedBox(height: 6),
    ]);
  }

  Widget _textPanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Row(children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.white12, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(44)),
            onPressed: () => _editText(),
            icon: const Icon(Icons.text_fields),
            label: const Text('Add text'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.white12, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(44)),
            onPressed: _addEmoji,
            icon: const Icon(Icons.emoji_emotions_outlined),
            label: const Text('Emoji'),
          ),
        ),
      ]),
    );
  }

  Widget _toolBar() {
    Widget b(_Tool t, IconData i, String label) {
      final active = _tool == t;
      final edited = switch (t) {
        _Tool.crop => _crop != const Rect.fromLTRB(0, 0, 1, 1),
        _Tool.adjust => !_adjust.isNeutral,
        _Tool.filters => _filter != 0,
        _Tool.draw => _strokes.isNotEmpty,
        _Tool.text => _texts.isNotEmpty,
        _ => false,
      };
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _tool = active ? _Tool.none : t),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Stack(clipBehavior: Clip.none, children: [
                Icon(i, color: active ? Brand.primary : Colors.white),
                if (edited && !active)
                  Positioned(right: -5, top: -3, child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: Brand.primary, shape: BoxShape.circle))),
              ]),
              const SizedBox(height: 4),
              Text(active ? 'Done' : label, style: TextStyle(color: active ? Brand.primary : Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: Colors.white10))),
        child: Row(children: [
          b(_Tool.crop, Icons.crop_rotate, 'Crop'),
          b(_Tool.filters, Icons.auto_fix_high, 'Filters'),
          b(_Tool.adjust, Icons.tune, 'Adjust'),
          b(_Tool.draw, Icons.draw_outlined, 'Draw'),
          b(_Tool.text, Icons.title, 'Text'),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ small widgets
class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.icon, required this.label, required this.onTap, this.selected = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: selected ? Brand.primary : Colors.white12, shape: BoxShape.circle),
              child: Icon(icon, color: Colors.white, size: 21),
            ),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: selected ? Colors.white : Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: selected ? Brand.primary : Colors.white12, borderRadius: BorderRadius.circular(20)),
            child: Text(label, style: TextStyle(color: selected ? Colors.white : Colors.white70, fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ),
      );
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({required this.selected, required this.onPick});
  final Color selected;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final c in _palette)
            GestureDetector(
              onTap: () => onPick(c),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
                width: c == selected ? 32 : 28,
                height: c == selected ? 32 : 28,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: c == selected ? Colors.white : Colors.white30, width: c == selected ? 3 : 1),
                ),
              ),
            ),
        ]),
      );
}

class _StyleChip extends StatelessWidget {
  const _StyleChip({required this.style, required this.selected, required this.color, required this.onTap});
  final _TextStyle style;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 46,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? Brand.primary : Colors.white24, width: selected ? 2 : 1),
          ),
          child: Container(
            padding: style == _TextStyle.box ? const EdgeInsets.symmetric(horizontal: 6, vertical: 1) : null,
            decoration: style == _TextStyle.box ? BoxDecoration(color: color, borderRadius: BorderRadius.circular(5)) : null,
            child: Text('Aa', style: _textStyleFor(style, color, 15)),
          ),
        ),
      );
}

/// Text colour for each style ("box" puts readable text on a coloured label).
TextStyle _textStyleFor(_TextStyle s, Color color, double size) {
  final darkOn = color.computeLuminance() > 0.55;
  switch (s) {
    case _TextStyle.plain:
      return TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w800, shadows: [Shadow(color: Colors.black.withAlpha(150), blurRadius: size * 0.18)]);
    case _TextStyle.box:
      return TextStyle(color: darkOn ? Colors.black : Colors.white, fontSize: size, fontWeight: FontWeight.w800);
    case _TextStyle.outline:
      return TextStyle(
        color: color,
        fontSize: size,
        fontWeight: FontWeight.w900,
        shadows: [
          for (final o in const [Offset(1, 1), Offset(-1, 1), Offset(1, -1), Offset(-1, -1), Offset(0, 1.4), Offset(0, -1.4), Offset(1.4, 0), Offset(-1.4, 0)])
            Shadow(color: darkOn ? Colors.black : Colors.white, offset: o * (size / 16)),
        ],
      );
  }
}

void _paintVignette(Canvas c, Rect r, double amount) {
  if (amount <= 0) return;
  final shader = RadialGradient(
    radius: 0.75,
    colors: [Colors.transparent, Colors.black.withAlpha((amount * 200).round())],
    stops: const [0.45, 1.0],
  ).createShader(r);
  c.drawRect(r, Paint()..shader = shader);
}

class _VignettePainter extends CustomPainter {
  _VignettePainter(this.amount);
  final double amount;

  @override
  void paint(Canvas canvas, Size size) => _paintVignette(canvas, Offset.zero & size, amount);

  @override
  bool shouldRepaint(covariant _VignettePainter old) => old.amount != amount;
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter(this.strokes, this.texts, [this.rev = 0]);
  final List<_Stroke> strokes;
  final List<_TextItem> texts;
  final int rev;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      final width = s.width * size.width;
      Path path() {
        final p = Path()..moveTo(s.points.first.dx * size.width, s.points.first.dy * size.height);
        if (s.points.length == 1) {
          p.lineTo(s.points.first.dx * size.width + 0.01, s.points.first.dy * size.height);
        }
        // smooth the line through the midpoints
        for (var i = 1; i < s.points.length; i++) {
          final a = Offset(s.points[i - 1].dx * size.width, s.points[i - 1].dy * size.height);
          final b = Offset(s.points[i].dx * size.width, s.points[i].dy * size.height);
          final m = (a + b) / 2;
          p.quadraticBezierTo(a.dx, a.dy, m.dx, m.dy);
          if (i == s.points.length - 1) p.lineTo(b.dx, b.dy);
        }
        return p;
      }

      final base = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      switch (s.brush) {
        case _Brush.marker:
          canvas.drawPath(path(), base
            ..color = s.color.withAlpha(120)
            ..strokeWidth = width
            ..strokeCap = StrokeCap.square
            ..blendMode = BlendMode.srcOver);
        case _Brush.neon:
          canvas.drawPath(path(), Paint()
            ..color = s.color
            ..strokeWidth = width * 2.2
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 0.9));
          canvas.drawPath(path(), base
            ..color = Color.lerp(s.color, Colors.white, 0.75)!
            ..strokeWidth = width * 0.6);
        case _Brush.pen:
        case _Brush.eraser:
          canvas.drawPath(path(), base
            ..color = s.color
            ..strokeWidth = width);
      }
    }
    for (final t in texts) {
      final fontSize = t.size * size.width;
      final style = t.emoji ? TextStyle(fontSize: fontSize) : _textStyleFor(t.style, t.color, fontSize);
      final tp = TextPainter(text: TextSpan(text: t.text, style: style), textAlign: TextAlign.center, textDirection: TextDirection.ltr)
        ..layout(maxWidth: size.width * 0.9);
      canvas.save();
      canvas.translate(t.pos.dx * size.width, t.pos.dy * size.height);
      canvas.rotate(t.angle);
      if (!t.emoji && t.style == _TextStyle.box) {
        final pad = fontSize * 0.28;
        final r = Rect.fromCenter(center: Offset.zero, width: tp.width + pad * 2, height: tp.height + pad * 1.2);
        canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(fontSize * 0.3)), Paint()..color = t.color);
      }
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => old.rev != rev || old.strokes.length != strokes.length || old.texts.length != texts.length;
}

/// Darkens everything outside the crop rectangle.
class _ShadePainter extends CustomPainter {
  _ShadePainter(this.crop);
  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(crop.left * size.width, crop.top * size.height, crop.right * size.width, crop.bottom * size.height);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(outside, Paint()..color = Colors.black.withAlpha(150));
    canvas.drawRect(r, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _ShadePainter old) => old.crop != crop;
}

/// Crop box like Telegram: drag any corner or edge (big touch areas), drag inside to move,
/// rule-of-thirds grid while cropping, optional fixed shape ([lock] = width/height in 0..1 space).
class _CropOverlay extends StatelessWidget {
  const _CropOverlay({required this.rect, required this.size, required this.onChanged, this.lock});
  final Rect rect;
  final Size size;
  final double? lock;
  final ValueChanged<Rect> onChanged;

  static const _minPx = 48.0;

  Rect _drag(Offset d, {bool l = false, bool t = false, bool r = false, bool b = false}) {
    final minW = _minPx / size.width, minH = _minPx / size.height;
    var left = rect.left, top = rect.top, right = rect.right, bottom = rect.bottom;
    if (l) left = (left + d.dx).clamp(0.0, right - minW);
    if (r) right = (right + d.dx).clamp(left + minW, 1.0);
    if (t) top = (top + d.dy).clamp(0.0, bottom - minH);
    if (b) bottom = (bottom + d.dy).clamp(top + minH, 1.0);
    final n = lock;
    if (n == null) return Rect.fromLTRB(left, top, right, bottom);
    // fixed shape: follow the bigger movement, keep the opposite side (or the centre for edges) in place
    var w = right - left, h = bottom - top;
    final horizontal = (l || r) && (!(t || b) || d.dx.abs() * size.width >= d.dy.abs() * size.height);
    if (horizontal) {
      h = w / n;
    } else {
      w = h * n;
    }
    // shrink to fit the picture
    double ax = l ? rect.right : (r ? rect.left : rect.center.dx);
    double ay = t ? rect.bottom : (b ? rect.top : rect.center.dy);
    double maxW = l ? ax : (r ? 1 - ax : 2 * math.min(ax, 1 - ax));
    double maxH = t ? ay : (b ? 1 - ay : 2 * math.min(ay, 1 - ay));
    if (w > maxW) {
      w = maxW;
      h = w / n;
    }
    if (h > maxH) {
      h = maxH;
      w = h * n;
    }
    final nl = l ? ax - w : (r ? ax : ax - w / 2);
    final nt = t ? ay - h : (b ? ay : ay - h / 2);
    return Rect.fromLTWH(nl, nt, w, h);
  }

  @override
  Widget build(BuildContext context) {
    final r = Rect.fromLTRB(rect.left * size.width, rect.top * size.height, rect.right * size.width, rect.bottom * size.height);
    Offset norm(Offset d) => Offset(d.dx / size.width, d.dy / size.height);
    const hit = 44.0;
    Widget zone(Rect area, {bool l = false, bool t = false, bool rr = false, bool b = false}) => Positioned.fromRect(
          rect: area,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanUpdate: (d) => onChanged(_drag(norm(d.delta), l: l, t: t, r: rr, b: b)),
          ),
        );
    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(child: CustomPaint(painter: _ShadePainter(rect))),
      Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _CropFramePainter(r)))),
      // move: drag inside (kept inside the picture instead of stopping at the edge)
      Positioned.fromRect(
        rect: r.deflate(hit / 2),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) {
            final dd = norm(d.delta);
            final dx = dd.dx.clamp(-rect.left, 1 - rect.right);
            final dy = dd.dy.clamp(-rect.top, 1 - rect.bottom);
            onChanged(rect.shift(Offset(dx, dy)));
          },
        ),
      ),
      // edges
      zone(Rect.fromLTRB(r.left + hit / 2, r.top - hit / 2, r.right - hit / 2, r.top + hit / 2), t: true),
      zone(Rect.fromLTRB(r.left + hit / 2, r.bottom - hit / 2, r.right - hit / 2, r.bottom + hit / 2), b: true),
      zone(Rect.fromLTRB(r.left - hit / 2, r.top + hit / 2, r.left + hit / 2, r.bottom - hit / 2), l: true),
      zone(Rect.fromLTRB(r.right - hit / 2, r.top + hit / 2, r.right + hit / 2, r.bottom - hit / 2), rr: true),
      // corners (on top: they win where they overlap the edges)
      zone(Rect.fromCenter(center: r.topLeft, width: hit * 1.4, height: hit * 1.4), l: true, t: true),
      zone(Rect.fromCenter(center: r.topRight, width: hit * 1.4, height: hit * 1.4), rr: true, t: true),
      zone(Rect.fromCenter(center: r.bottomLeft, width: hit * 1.4, height: hit * 1.4), l: true, b: true),
      zone(Rect.fromCenter(center: r.bottomRight, width: hit * 1.4, height: hit * 1.4), rr: true, b: true),
    ]);
  }
}

/// White frame, thick corner brackets, edge ticks and a rule-of-thirds grid.
class _CropFramePainter extends CustomPainter {
  _CropFramePainter(this.r);
  final Rect r;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white.withAlpha(110)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = r.left + r.width * i / 3, y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), grid);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), grid);
    }
    canvas.drawRect(r, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
    final thick = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final c = math.min(22.0, math.min(r.width, r.height) / 3);
    for (final (p, dx, dy) in [(r.topLeft, 1.0, 1.0), (r.topRight, -1.0, 1.0), (r.bottomLeft, 1.0, -1.0), (r.bottomRight, -1.0, -1.0)]) {
      canvas.drawLine(p, p + Offset(c * dx, 0), thick);
      canvas.drawLine(p, p + Offset(0, c * dy), thick);
    }
    final t = math.min(16.0, math.min(r.width, r.height) / 4);
    canvas.drawLine(Offset(r.center.dx - t, r.top), Offset(r.center.dx + t, r.top), thick);
    canvas.drawLine(Offset(r.center.dx - t, r.bottom), Offset(r.center.dx + t, r.bottom), thick);
    canvas.drawLine(Offset(r.left, r.center.dy - t), Offset(r.left, r.center.dy + t), thick);
    canvas.drawLine(Offset(r.right, r.center.dy - t), Offset(r.right, r.center.dy + t), thick);
  }

  @override
  bool shouldRepaint(covariant _CropFramePainter old) => old.r != r;
}

class _RawImage {
  final int width;
  final int height;
  final Uint8List rgba;
  _RawImage(this.width, this.height, this.rgba);
}

Uint8List _encodeJpeg(_RawImage r) {
  final im = img.Image.fromBytes(width: r.width, height: r.height, bytes: r.rgba.buffer, numChannels: 4);
  return img.encodeJpg(im, quality: 88);
}

/// The round "1" icon for view-once media (filled when on).
class ViewOnceIcon extends StatelessWidget {
  const ViewOnceIcon({super.key, required this.on, this.size = 26, this.color = Colors.white});
  final bool on;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: on ? Brand.aurora : null,
          border: on ? null : Border.all(color: color, width: 1.8, strokeAlign: BorderSide.strokeAlignInside),
        ),
        child: Text('1', style: TextStyle(color: on ? Colors.white : color, fontWeight: FontWeight.w800, fontSize: size * 0.5, height: 1)),
      );
}
