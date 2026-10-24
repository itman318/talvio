import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../theme/brand.dart';
import '../utils/format.dart';
import 'premium.dart';

/// Result of the sticker maker: a 512×512 transparent PNG and its emoji.
class MadeSticker {
  MadeSticker(this.path, this.emoji);
  final String path;
  final String emoji;
}

/// Turns a photo into a sticker: remove the background (on the phone, ML Kit),
/// pick a shape, add a white outline, choose an emoji.
class StickerMakerScreen extends StatefulWidget {
  const StickerMakerScreen({super.key, required this.path});
  final String path;

  @override
  State<StickerMakerScreen> createState() => _StickerMakerScreenState();
}

class _StickerMakerScreenState extends State<StickerMakerScreen> {
  static const _emojis = ['😀', '😂', '😍', '😎', '🤔', '😢', '😡', '👍', '🙏', '🎉', '❤️', '🔥', '👋', '😴', '☕', '🌙', '🥳', '😮'];

  Uint8List? _photo; // the photo, at most 768 px, as PNG
  Uint8List? _cutout; // the photo without background (PNG with alpha)
  Uint8List? _preview; // finished sticker
  bool _removeBg = false;
  bool _outline = true;
  String _shape = 'original';
  String _emoji = '😀';
  bool _busy = true;
  String? _note;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      _photo = await Isolate.run(() {
        final src = img.decodeImage(bytes);
        if (src == null) throw Exception('This picture could not be read');
        final oriented = img.bakeOrientation(src);
        final scale = 768 / math.max(oriented.width, oriented.height);
        final small = scale < 1 ? img.copyResize(oriented, width: (oriented.width * scale).round(), height: (oriented.height * scale).round()) : oriented;
        return Uint8List.fromList(img.encodePng(small, level: 1));
      });
      await _render();
    } catch (e) {
      if (mounted) {
        showError(context, e);
        Navigator.pop(context);
      }
    }
  }

  /// On-device background removal (Google ML Kit subject segmentation).
  Future<bool> _makeCutout() async {
    if (_cutout != null) return true;
    final photo = _photo!;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/sticker_src_${DateTime.now().millisecondsSinceEpoch}.png');
    await f.writeAsBytes(photo);
    final seg = SubjectSegmenter(
      options: SubjectSegmenterOptions(
        enableForegroundBitmap: false,
        enableForegroundConfidenceMask: true,
        enableMultipleSubjects: SubjectResultOptions(enableConfidenceMask: false, enableSubjectBitmap: false),
      ),
    );
    try {
      final r = await seg.processImage(InputImage.fromFilePath(f.path));
      final mask = r.foregroundConfidenceMask;
      if (mask == null || mask.isEmpty) return false;
      _cutout = await Isolate.run(() {
        final im = img.decodePng(photo)!.convert(numChannels: 4);
        if (mask.length != im.width * im.height) throw Exception('mask size');
        for (var y = 0; y < im.height; y++) {
          for (var x = 0; x < im.width; x++) {
            final c = mask[y * im.width + x];
            final p = im.getPixel(x, y);
            p.a = (c < 0.25 ? 0 : (c > 0.75 ? 1.0 : (c - 0.25) * 2)) * 255;
          }
        }
        return Uint8List.fromList(img.encodePng(im, level: 1));
      });
      return true;
    } finally {
      seg.close();
      f.delete().catchError((_) => f);
    }
  }

  Future<void> _render() async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      if (_removeBg && !await _makeCutout()) {
        _removeBg = false;
        _note = 'No person or object found to cut out';
      }
    } catch (e) {
      _removeBg = false;
      _note = '$e'.contains('download') || '$e'.contains('Waiting')
          ? 'Background removal is getting ready on this phone — try again in a minute'
          : 'Background removal is not available on this phone';
    }
    final source = _removeBg ? _cutout! : _photo!;
    final shape = _shape;
    final outline = _outline;
    final out = await Isolate.run(() => _compose(source, shape, outline));
    if (!mounted) return;
    setState(() {
      _preview = out;
      _busy = false;
    });
  }

  /// Fits the picture into 512×512, cuts the shape and draws a white outline around what is visible.
  static Uint8List _compose(Uint8List source, String shape, bool outline) {
    var im = img.decodePng(source)!.convert(numChannels: 4);
    // trim transparent edges (cut-outs)
    var minX = im.width, minY = im.height, maxX = -1, maxY = -1;
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        if (im.getPixel(x, y).a > 20) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX > minX && maxY > minY) im = img.copyCrop(im, x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1);
    if (shape != 'original') {
      final side = math.min(im.width, im.height);
      im = img.copyCrop(im, x: (im.width - side) ~/ 2, y: (im.height - side) ~/ 2, width: side, height: side);
    }
    const canvas = 512;
    final pad = outline ? 22 : 8;
    final scale = (canvas - pad * 2) / math.max(im.width, im.height);
    im = img.copyResize(im, width: (im.width * scale).round(), height: (im.height * scale).round(), interpolation: img.Interpolation.average);
    // shape mask
    if (shape != 'original') {
      final w = im.width, h = im.height;
      final r = shape == 'circle' ? w / 2 : w * 0.22;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final dx = math.max(0.0, math.max(r - x, x - (w - 1 - r)));
          final dy = math.max(0.0, math.max(r - y, y - (h - 1 - r)));
          final d = math.sqrt(dx * dx + dy * dy);
          if (d > r) {
            im.getPixel(x, y).a = 0;
          } else if (d > r - 1.5) {
            final p = im.getPixel(x, y);
            p.a = p.a * (r - d) / 1.5;
          }
        }
      }
    }
    final out = img.Image(width: canvas, height: canvas, numChannels: 4);
    final ox = (canvas - im.width) ~/ 2, oy = (canvas - im.height) ~/ 2;
    if (outline) {
      // white silhouette, stamped around in a circle = outline
      const radius = 9;
      final sil = img.Image(width: im.width, height: im.height, numChannels: 4);
      for (var y = 0; y < im.height; y++) {
        for (var x = 0; x < im.width; x++) {
          final a = im.getPixel(x, y).a;
          if (a > 30) sil.setPixelRgba(x, y, 255, 255, 255, 255);
        }
      }
      for (var k = 0; k < 24; k++) {
        final ang = k / 24 * math.pi * 2;
        img.compositeImage(out, sil, dstX: ox + (math.cos(ang) * radius).round(), dstY: oy + (math.sin(ang) * radius).round());
      }
      img.compositeImage(out, sil, dstX: ox, dstY: oy);
    }
    img.compositeImage(out, im, dstX: ox, dstY: oy);
    return Uint8List.fromList(img.encodePng(out, level: 6));
  }

  Future<void> _save() async {
    final png = _preview;
    if (png == null) return;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/sticker_${DateTime.now().millisecondsSinceEpoch}.png');
    await f.writeAsBytes(png);
    if (mounted) Navigator.pop(context, MadeSticker(f.path, _emoji));
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget chip(String label, bool on, VoidCallback tap, {IconData? icon}) => Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 8),
          child: ChoiceChip(
            avatar: icon == null ? null : Icon(icon, size: 18, color: on ? Colors.white : Brand.muted),
            label: Text(label),
            selected: on,
            onSelected: _busy ? null : (_) => tap(),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Make a sticker')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), color: dark ? const Color(0xFF161A2E) : const Color(0xFFF1F2F7)),
            clipBehavior: Clip.antiAlias,
            child: CustomPaint(
              painter: _Checker(dark),
              child: Stack(fit: StackFit.expand, children: [
                if (_preview != null) Padding(padding: const EdgeInsets.all(18), child: Image.memory(_preview!, gaplessPlayback: true)),
                if (_busy) const Center(child: CircularProgressIndicator()),
              ]),
            ),
          ),
        ),
        if (_note != null)
          Padding(padding: const EdgeInsets.only(top: 10), child: Text(_note!, textAlign: TextAlign.center, style: const TextStyle(color: Brand.muted))),
        const SizedBox(height: 16),
        const Text('Background', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(children: [
          chip('Keep', !_removeBg, () {
            _removeBg = false;
            _render();
          }, icon: Icons.image_rounded),
          chip('Remove', _removeBg, () {
            _removeBg = true;
            _render();
          }, icon: Icons.auto_fix_high_rounded),
        ]),
        const SizedBox(height: 6),
        const Text('Shape', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(children: [
          for (final (id, label) in const [('original', 'Original'), ('circle', 'Circle'), ('rounded', 'Rounded')])
            chip(label, _shape == id, () {
              _shape = id;
              _render();
            }),
          chip('White outline', _outline, () {
            _outline = !_outline;
            _render();
          }, icon: Icons.border_outer_rounded),
        ]),
        const SizedBox(height: 6),
        const Text('Emoji', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(spacing: 4, runSpacing: 4, children: [
          for (final e in _emojis)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _emoji = e),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _emoji == e ? Brand.primary : Colors.transparent, width: 2),
                ),
                child: Text(e, style: const TextStyle(fontSize: 26)),
              ),
            ),
        ]),
        const SizedBox(height: 20),
        AuroraButton(label: 'Add to my stickers', icon: Icons.check_rounded, busy: _busy, onPressed: _preview == null ? null : _save),
      ]),
    );
  }
}

class _Checker extends CustomPainter {
  _Checker(this.dark);
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = dark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.04);
    const s = 16.0;
    for (var y = 0.0; y < size.height; y += s) {
      for (var x = ((y / s).floor().isOdd ? s : 0.0); x < size.width; x += s * 2) {
        canvas.drawRect(Rect.fromLTWH(x, y, s, s), p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Checker old) => old.dark != dark;
}
