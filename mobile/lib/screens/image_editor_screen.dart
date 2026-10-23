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
  const ImageEditorScreen({super.key, required this.path, this.sendLabel = 'Send'});
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
              _toolBar(),
            ]),
    );
  }

  Widget _canvas(ui.Image image, BoxConstraints box) {
    final ratio = image.width / image.height;
    var w = box.maxWidth - 24;
    var h = w / ratio;
    if (h > box.maxHeight - 24) {
      h = box.maxHeight - 24;
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
            if (_tool == _Tool.crop) Positioned.fill(child: _CropOverlay(rect: _crop, size: size, onChanged: (r) => setState(() => _crop = r)))
            else if (_crop != const Rect.fromLTRB(0, 0, 1, 1)) Positioned.fill(child: CustomPaint(painter: _ShadePainter(_crop))),
          ]),
        ),
      ),
    );
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
        b(Icons.crop, 'Crop', () => setState(() => _tool = _tool == _Tool.crop ? _Tool.none : _Tool.crop), active: _tool == _Tool.crop),
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

/// Crop rectangle with four corner handles (drag the middle to move it).
class _CropOverlay extends StatelessWidget {
  const _CropOverlay({required this.rect, required this.size, required this.onChanged});
  final Rect rect;
  final Size size;
  final ValueChanged<Rect> onChanged;

  static const _min = 0.1;

  @override
  Widget build(BuildContext context) {
    final r = Rect.fromLTRB(rect.left * size.width, rect.top * size.height, rect.right * size.width, rect.bottom * size.height);
    Widget handle(Alignment a, void Function(Offset delta) move) => Positioned(
          left: (a.x < 0 ? r.left : r.right) - 18,
          top: (a.y < 0 ? r.top : r.bottom) - 18,
          child: GestureDetector(
            onPanUpdate: (d) => move(Offset(d.delta.dx / size.width, d.delta.dy / size.height)),
            child: Container(width: 36, height: 36, alignment: Alignment.center, child: Container(width: 18, height: 18, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle))),
          ),
        );
    double cl(double v) => v.clamp(0.0, 1.0);
    return Stack(children: [
      Positioned.fill(child: CustomPaint(painter: _ShadePainter(rect))),
      Positioned.fromRect(
        rect: r,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) {
            final dx = d.delta.dx / size.width;
            final dy = d.delta.dy / size.height;
            final moved = rect.shift(Offset(dx, dy));
            if (moved.left >= 0 && moved.top >= 0 && moved.right <= 1 && moved.bottom <= 1) onChanged(moved);
          },
        ),
      ),
      handle(Alignment.topLeft, (d) => onChanged(Rect.fromLTRB(cl(math.min(rect.left + d.dx, rect.right - _min)), cl(math.min(rect.top + d.dy, rect.bottom - _min)), rect.right, rect.bottom))),
      handle(Alignment.topRight, (d) => onChanged(Rect.fromLTRB(rect.left, cl(math.min(rect.top + d.dy, rect.bottom - _min)), cl(math.max(rect.right + d.dx, rect.left + _min)), rect.bottom))),
      handle(Alignment.bottomLeft, (d) => onChanged(Rect.fromLTRB(cl(math.min(rect.left + d.dx, rect.right - _min)), rect.top, rect.right, cl(math.max(rect.bottom + d.dy, rect.top + _min))))),
      handle(Alignment.bottomRight, (d) => onChanged(Rect.fromLTRB(rect.left, rect.top, cl(math.max(rect.right + d.dx, rect.left + _min)), cl(math.max(rect.bottom + d.dy, rect.top + _min))))),
    ]);
  }
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
