import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../theme/brand.dart';
import 'image_editor_screen.dart';

/// What to send from [AlbumSendScreen].
class AlbumSendResult {
  const AlbumSendResult(this.paths, this.caption);
  final List<String> paths;
  final String caption;
}

/// Several photos picked: look through them, edit any one (crop, draw, text), remove some,
/// add more, write a caption — then send them together as one album.
class AlbumSendScreen extends StatefulWidget {
  const AlbumSendScreen({super.key, required this.paths, this.caption = '', this.maxCount = 10, this.imageQuality, this.maxSide});
  final List<String> paths;
  final String caption;
  final int maxCount;
  final int? imageQuality;
  final double? maxSide;

  @override
  State<AlbumSendScreen> createState() => _AlbumSendScreenState();
}

class _AlbumSendScreenState extends State<AlbumSendScreen> {
  late final List<String> _paths = [...widget.paths];
  late final _caption = TextEditingController(text: widget.caption);
  final _pager = PageController();
  int _index = 0;

  @override
  void dispose() {
    _caption.dispose();
    _pager.dispose();
    super.dispose();
  }

  Future<void> _edit() async {
    final path = _paths[_index];
    final edited = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => ImageEditorScreen(path: path, sendLabel: 'Done')));
    if (edited != null && mounted) {
      setState(() => _paths[_index] = edited);
      imageCache.evict(FileImage(File(edited)));
    }
  }

  void _remove(int i) {
    setState(() {
      _paths.removeAt(i);
      if (_index >= _paths.length) _index = _paths.length - 1;
    });
    if (_paths.isEmpty) {
      Navigator.pop(context);
      return;
    }
    _pager.jumpToPage(_index);
  }

  Future<void> _addMore() async {
    final room = widget.maxCount - _paths.length;
    if (room <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Up to ${widget.maxCount} photos in one album')));
      return;
    }
    final more = await ImagePicker().pickMultiImage(imageQuality: widget.imageQuality, maxWidth: widget.maxSide, maxHeight: widget.maxSide, limit: room);
    if (more.isEmpty || !mounted) return;
    setState(() => _paths.addAll(more.take(room).map((x) => x.path)));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} of ${_paths.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(tooltip: 'Edit this photo', icon: const Icon(Icons.tune_rounded), onPressed: _edit),
          IconButton(tooltip: 'Remove this photo', icon: const Icon(Icons.delete_outline_rounded), onPressed: () => _remove(_index)),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: PageView.builder(
            controller: _pager,
            itemCount: _paths.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => GestureDetector(
              onDoubleTap: _edit,
              child: InteractiveViewer(
                child: Center(child: Image.file(File(_paths[i]), key: ValueKey(_paths[i]), fit: BoxFit.contain)),
              ),
            ),
          ),
        ),
        // thumbnails: tap to look, long-press to remove, "+" to add more
        SizedBox(
          height: 74,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            children: [
              for (var i = 0; i < _paths.length; i++)
                GestureDetector(
                  onTap: () {
                    setState(() => _index = i);
                    _pager.animateToPage(i, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
                  },
                  onLongPress: () => _remove(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 58,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: i == _index ? Brand.primaryLight : Colors.transparent, width: 2.4),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(File(_paths[i]), key: ValueKey('t${_paths[i]}'), fit: BoxFit.cover, cacheWidth: 160),
                    ),
                  ),
                ),
              if (_paths.length < widget.maxCount)
                GestureDetector(
                  onTap: _addMore,
                  child: Container(
                    width: 58,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white24, width: 1.4)),
                    child: const Icon(Icons.add_photo_alternate_rounded, color: Colors.white70),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(10, 4, 10, 10 + (bottom > 0 ? 0 : MediaQuery.paddingOf(context).bottom)),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _caption,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.white,
                decoration: InputDecoration(
                  hintText: 'Add a caption…',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.1),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: const BorderSide(color: Colors.white38)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Material(
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: Ink(
                decoration: const BoxDecoration(gradient: Brand.aurora, shape: BoxShape.circle),
                child: InkWell(
                  onTap: () => Navigator.pop(context, AlbumSendResult(List.of(_paths), _caption.text.trim())),
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: Stack(alignment: Alignment.center, children: [
                      const Icon(Icons.send_rounded, color: Colors.white),
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                          child: Text('${_paths.length}', style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, color: Brand.ink)),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
