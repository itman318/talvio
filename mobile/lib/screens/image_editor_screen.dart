import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../theme/brand.dart';

/// Photo editor before sending: crop, rotate, draw, add text. Returns the path of the edited JPEG
/// (or the original path if nothing was changed), or null when cancelled.
class ImageEditorScreen extends StatefulWidget {
  const ImageEditorScreen({super.key, required this.path, this.sendLabel = 'Send', this.viewOnce});

  /// When given, a "1" button turns the photo into a view-once photo.
  final ValueNotifier<bool>? viewOnce;
  final String path;
  final String sendLabel;

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

enum _Tool { none, crop, draw, text }

class _Stroke {
  final List<Offset> points; // normalised 0..1 in image space
  final Color color;
  final double width; // fraction of image width
  _Stroke(this.points, this.color, this.width);
}

class _TextItem {
  Offset pos; // normalised centre
  String text;
  Color color;
  double size; // fraction of image width
  _TextItem(this.pos, this.text, this.color, this.size);
}

const _palette = [Colors.white, Colors.black, Color(0xFFE53935), Color(0xFFFFB300), Color(0xFF43A047), Color(0xFF1E88E5), Color(0xFF8E24AA)];

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  ui.Image? _image;
  _Tool _tool = _Tool.none;
  final List<_Stroke> _strokes = [];
  final List<_TextItem> _texts = [];
  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1); // normalised
  String _aspect = 'free'; // free | original | 1:1 | 4:3 | 3:4 | 16:9 | 9:16
  Color _color = const Color(0xFFE53935);
  double _brush = 0.012;
  bool _changed = false;
  bool _saving = false;
  int? _dragText;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await File(widget.path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    var frame = (await codec.getNextFrame()).image;
    // keep editing fast: at most 2560 px on the long side
    final longSide = math.max(frame.width, frame.height);
    if (longSide > 2560) {
      final s = 2560 / longSide;
      frame = await _redraw(frame, (frame.width * s).round(), (frame.height * s).round(), (c, w, h) {
        c.drawImageRect(frame, Rect.fromLTWH(0, 0, frame.width.toDouble(), frame.height.toDouble()), Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..filterQuality = FilterQuality.high);
      });
    }
    if (mounted) setState(() => _image = frame);
  }

  Future<ui.Image> _redraw(ui.Image src, int w, int h, void Function(Canvas c, int w, int h) paint) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    paint(c, w, h);
    return rec.endRecording().toImage(w, h);
  }

  // ------------------------------------------------------------------ tools
  Future<void> _rotate() async {
    final src = _image;
    if (src == null) return;
    final rotated = await _redraw(src, src.height, src.width, (c, w, h) {
      c.translate(w.toDouble(), 0);
      c.rotate(math.pi / 2);
      c.drawImage(src, Offset.zero, Paint());
    });
    // rotate everything drawn on top by 90° clockwise too: (x, y) → (1 - y, x)
    Offset r(Offset p) => Offset(1 - p.dy, p.dx);
    final strokes = _strokes.map((s) => _Stroke(s.points.map(r).toList(), s.color, s.width * src.width / src.height)).toList();
    _strokes
      ..clear()
      ..addAll(strokes);
    for (final t in _texts) {
      t.pos = r(t.pos);
      t.size = t.size * src.width / src.height;
    }
    _crop = Rect.fromLTRB(1 - _crop.bottom, _crop.left, 1 - _crop.top, _crop.right);
    setState(() {
      _image = rotated;
      _changed = true;
    });
  }

  /// Mirror left ↔ right.
  Future<void> _flip() async {
    final src = _image;
    if (src == null) return;
    final flipped = await _redraw(src, src.width, src.height, (c, w, h) {
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
    }
    _crop = Rect.fromLTRB(1 - _crop.right, _crop.top, 1 - _crop.left, _crop.bottom);
    setState(() {
      _image = flipped;
      _changed = true;
    });
  }

  /// Width/height of the crop box in pixels for an aspect choice (null = free).
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

  /// The same ratio in normalised (0..1) crop space.
  double? get _lock {
    final r = _ratioFor(_aspect);
    final im = _image;
    if (r == null || im == null) return null;
    return r * im.height / im.width;
  }

  void _setAspect(String a) {
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
      var l = (c.dx - w / 2).clamp(0.0, 1 - w), t = (c.dy - h / 2).clamp(0.0, 1 - h);
      _crop = Rect.fromLTWH(l, t, w, h);
    });
  }

  void _resetCrop() => setState(() {
        _crop = const Rect.fromLTRB(0, 0, 1, 1);
        _aspect = 'free';
      });

  Future<void> _addText() async {
    final ctrl = TextEditingController();
    final t = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add text'),
        content: TextField(controller: ctrl, autofocus: true, maxLength: 120, textCapitalization: TextCapitalization.sentences),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (t == null || t.isEmpty) return;
    setState(() {
      _texts.add(_TextItem(const Offset(0.5, 0.5), t, _color, 0.07));
      _tool = _Tool.text;
      _changed = true;
    });
  }

  void _undo() {
    setState(() {
      if (_tool == _Tool.text && _texts.isNotEmpty) {
        _texts.removeLast();
      } else if (_strokes.isNotEmpty) {
        _strokes.removeLast();
      } else if (_texts.isNotEmpty) {
        _texts.removeLast();
      }
    });
  }

  // ------------------------------------------------------------------ export
  Future<void> _done() async {
    final src = _image;
    if (src == null) return;
    if (!_changed && _crop == const Rect.fromLTRB(0, 0, 1, 1)) {
      Navigator.pop(context, widget.path);
      return;
    }
    setState(() => _saving = true);
    try {
      final w = src.width;
      final h = src.height;
      final full = await _redraw(src, w, h, (c, _, __) {
        c.drawImage(src, Offset.zero, Paint());
        _OverlayPainter(_strokes, _texts).paint(c, Size(w.toDouble(), h.toDouble()));
      });
      final cr = Rect.fromLTRB(_crop.left * w, _crop.top * h, _crop.right * w, _crop.bottom * h);
      final cw = math.max(1, cr.width.round());
      final ch = math.max(1, cr.height.round());
      final cropped = await _redraw(full, cw, ch, (c, _, __) {
        c.drawImageRect(full, cr, Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()), Paint());
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

  // ------------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (_strokes.isNotEmpty || _texts.isNotEmpty) IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: _undo),
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
          TextButton(
            onPressed: _saving ? null : _done,
            child: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(widget.sendLabel, style: const TextStyle(color: Brand.primary, fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: image == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(child: LayoutBuilder(builder: (ctx, box) => _canvas(image, box))),
              if (_tool == _Tool.draw || _tool == _Tool.text) _colorBar(),
              if (_tool == _Tool.crop) _cropBar(),
              _toolBar(),
            ]),
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

    return Center(
      child: SizedBox(
        width: w,
        height: h,
        child: GestureDetector(
          onPanStart: (d) {
            final p = norm(d.localPosition);
            if (_tool == _Tool.draw) {
              setState(() {
                _strokes.add(_Stroke([p], _color, _brush));
                _changed = true;
              });
            } else if (_tool == _Tool.text || _tool == _Tool.none) {
              // grab the nearest text label
              for (var i = _texts.length - 1; i >= 0; i--) {
                if ((_texts[i].pos - p).distance < 0.12) {
                  _dragText = i;
                  break;
                }
              }
            }
          },
          onPanUpdate: (d) {
            final p = norm(d.localPosition);
            if (_tool == _Tool.draw && _strokes.isNotEmpty) {
              setState(() => _strokes.last.points.add(p));
            } else if (_dragText != null) {
              setState(() => _texts[_dragText!].pos = p);
            }
          },
          onPanEnd: (_) => _dragText = null,
          child: Stack(children: [
            Positioned.fill(child: RawImage(image: image, fit: BoxFit.fill)),
            Positioned.fill(child: CustomPaint(painter: _OverlayPainter(_strokes, _texts))),
            if (_tool == _Tool.crop) Positioned.fill(child: _CropOverlay(rect: _crop, size: size, lock: _lock, onChanged: (r) => setState(() => _crop = r)))
            else if (_crop != const Rect.fromLTRB(0, 0, 1, 1)) Positioned.fill(child: CustomPaint(painter: _ShadePainter(_crop))),
          ]),
        ),
      ),
    );
  }

  Widget _cropBar() {
    const opts = [('free', 'Free'), ('original', 'Original'), ('1:1', 'Square'), ('4:3', '4:3'), ('3:4', '3:4'), ('16:9', '16:9'), ('9:16', '9:16')];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(tooltip: 'Rotate', onPressed: _rotate, icon: const Icon(Icons.rotate_90_degrees_cw_outlined, color: Colors.white)),
        IconButton(tooltip: 'Mirror', onPressed: _flip, icon: const Icon(Icons.flip, color: Colors.white)),
        TextButton(onPressed: _resetCrop, child: const Text('Reset', style: TextStyle(color: Colors.white70))),
      ]),
      SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final o in opts)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text(o.$2),
                selected: _aspect == o.$1,
                onSelected: (_) => _setAspect(o.$1),
                labelStyle: TextStyle(color: _aspect == o.$1 ? Colors.white : Colors.white70, fontWeight: FontWeight.w600),
                selectedColor: Brand.primary,
                backgroundColor: Colors.white12,
                side: BorderSide.none,
                showCheckmark: false,
              ),
            ),
        ]),
      ),
      const SizedBox(height: 4),
    ]);
  }

  Widget _colorBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        ..._palette.map((c) => GestureDetector(
              onTap: () => setState(() {
                _color = c;
                if (_tool == _Tool.text && _texts.isNotEmpty) _texts.last.color = c;
              }),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 5),
                width: 28,
                height: 28,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: c == _color ? Brand.primary : Colors.white54, width: c == _color ? 3 : 1)),
              ),
            )),
        if (_tool == _Tool.draw)
          SizedBox(
            width: 100,
            child: Slider(min: 0.004, max: 0.04, value: _brush, onChanged: (v) => setState(() => _brush = v)),
          ),
      ]),
    );
  }

  Widget _toolBar() {
    Widget b(IconData i, String label, VoidCallback onTap, {bool active = false}) => Expanded(
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(i, color: active ? Brand.primary : Colors.white),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(color: active ? Brand.primary : Colors.white70, fontSize: 12)),
              ]),
            ),
          ),
        );
    return SafeArea(
      top: false,
      child: Row(children: [
        b(Icons.crop, _tool == _Tool.crop ? 'Done' : 'Crop', () => setState(() => _tool = _tool == _Tool.crop ? _Tool.none : _Tool.crop), active: _tool == _Tool.crop),
        b(Icons.rotate_90_degrees_cw_outlined, 'Rotate', _rotate),
        b(Icons.brush_outlined, 'Draw', () => setState(() => _tool = _tool == _Tool.draw ? _Tool.none : _Tool.draw), active: _tool == _Tool.draw),
        b(Icons.text_fields, 'Text', _addText, active: _tool == _Tool.text),
      ]),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter(this.strokes, this.texts);
  final List<_Stroke> strokes;
  final List<_TextItem> texts;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.width * size.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (s.points.length == 1) {
        canvas.drawCircle(Offset(s.points.first.dx * size.width, s.points.first.dy * size.height), paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
        continue;
      }
      final path = Path()..moveTo(s.points.first.dx * size.width, s.points.first.dy * size.height);
      for (final p in s.points.skip(1)) {
        path.lineTo(p.dx * size.width, p.dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
    for (final t in texts) {
      final fontSize = t.size * size.width;
      final tp = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            color: t.color,
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            shadows: [Shadow(color: Colors.black.withAlpha(140), blurRadius: fontSize * 0.15)],
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width * 0.9);
      tp.paint(canvas, Offset(t.pos.dx * size.width - tp.width / 2, t.pos.dy * size.height - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
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
