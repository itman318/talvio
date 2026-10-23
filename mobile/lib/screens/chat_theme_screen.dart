import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../core/prefs.dart';
import '../theme/brand.dart';
import '../theme/chat_theme.dart';
import '../utils/format.dart';

/// Theme & wallpaper for one chat ([chatId]) or for all chats (null).
class ChatThemeScreen extends StatefulWidget {
  const ChatThemeScreen({super.key, this.chatId, this.title});
  final int? chatId;
  final String? title;

  @override
  State<ChatThemeScreen> createState() => _ChatThemeScreenState();
}

class _ChatThemeScreenState extends State<ChatThemeScreen> {
  late ChatAppearance _look;

  @override
  void initState() {
    super.initState();
    _look = context.read<AppPrefs>().chatAppearance(widget.chatId);
  }

  void _set(ChatAppearance look) {
    setState(() => _look = look);
    context.read<AppPrefs>().setChatAppearance(widget.chatId, look);
  }

  Future<void> _pickPhoto() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2000, maxHeight: 2000, imageQuality: 88);
      if (x == null) return;
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/wallpapers');
      await dir.create(recursive: true);
      final target = '${dir.path}/wp_${widget.chatId ?? 'all'}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(x.path).copy(target);
      final old = _look.photoPath;
      _set(_look.copyWith(photoPath: target));
      if (old != null && old != target) File(old).delete().catchError((_) => File(old));
    } catch (e) {
      if (mounted) showInfo(context, 'Could not use this photo');
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPrefs>();
    final perChat = widget.chatId != null;
    return Scaffold(
      appBar: AppBar(title: Text(perChat ? 'Theme & wallpaper' : 'Chat theme & wallpaper')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        // live preview
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: SizedBox(
              height: 230,
              child: ChatThemeScope(
                appearance: _look,
                child: ChatBackground(appearance: _look, child: const _Preview()),
              ),
            ),
          ),
        ),
        _label('THEME'),
        SizedBox(
          height: 92,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final t in chatThemes)
                GestureDetector(
                  onTap: () => _set(_look.copyWith(themeId: t.id, clearPhoto: true)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(children: [
                      Container(
                        width: 58,
                        height: 58,
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: _look.themeId == t.id && _look.photoPath == null ? Brand.primary : Colors.transparent, width: 3),
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(colors: [t.light.first, t.mine.last], begin: Alignment.topLeft, end: Alignment.bottomRight),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(t.name, style: const TextStyle(fontSize: 12)),
                    ]),
                  ),
                ),
            ],
          ),
        ),
        _label('BACKGROUND'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'doodle', label: Text('Doodles'), icon: Icon(Icons.gesture_rounded)),
              ButtonSegment(value: 'dots', label: Text('Dots'), icon: Icon(Icons.grain_rounded)),
              ButtonSegment(value: 'none', label: Text('Plain'), icon: Icon(Icons.crop_square_rounded)),
            ],
            selected: {_look.photoPath != null ? '' : _look.pattern},
            emptySelectionAllowed: true,
            onSelectionChanged: (v) {
              if (v.isNotEmpty) _set(_look.copyWith(pattern: v.first, clearPhoto: true));
            },
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.wallpaper_rounded),
          title: Text(_look.photoPath == null ? 'Choose a photo' : 'Change photo'),
          onTap: _pickPhoto,
        ),
        if (_look.photoPath != null) ...[
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('Dim'),
            subtitle: Slider(
              value: _look.dim,
              max: 0.7,
              onChanged: (v) => setState(() => _look = _look.copyWith(dim: v)),
              onChangeEnd: (v) => _set(_look.copyWith(dim: v)),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.blur_on_rounded),
            title: const Text('Blur'),
            value: _look.blur,
            onChanged: (v) => _set(_look.copyWith(blur: v)),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Remove photo'),
            onTap: () => _set(_look.copyWith(clearPhoto: true)),
          ),
        ],
        const Divider(height: 24),
        if (perChat && prefs.hasOwnChatAppearance(widget.chatId!))
          ListTile(
            leading: const Icon(Icons.restart_alt_rounded),
            title: const Text('Use the same look as other chats'),
            onTap: () {
              prefs.setChatAppearance(widget.chatId, null);
              setState(() => _look = prefs.chatAppearance(widget.chatId));
            },
          ),
        if (perChat)
          ListTile(
            leading: const Icon(Icons.done_all_rounded),
            title: const Text('Apply to all chats'),
            onTap: () {
              prefs.setChatAppearance(null, _look);
              prefs.setChatAppearance(widget.chatId, null);
              showInfo(context, 'Applied to all chats');
            },
          ),
        if (!perChat)
          ListTile(
            leading: const Icon(Icons.restart_alt_rounded),
            title: const Text('Reset to default'),
            onTap: () {
              prefs.setChatAppearance(null, null);
              setState(() => _look = const ChatAppearance());
            },
          ),
      ]),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.6, fontSize: 12, color: Brand.muted)),
      );
}

class _Preview extends StatelessWidget {
  const _Preview();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mine = mineGradientOf(context);
    Widget bubble(String text, bool me) => Align(
          alignment: me ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: me ? null : (dark ? const Color(0xFF171A2C) : Colors.white),
              gradient: me ? mine : null,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(me ? 20 : 8),
                topRight: Radius.circular(me ? 8 : 20),
                bottomLeft: const Radius.circular(20),
                bottomRight: const Radius.circular(20),
              ),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: Text(text, style: TextStyle(color: me || dark ? Colors.white : Brand.ink, fontSize: 15)),
          ),
        );
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      bubble('Hey! How do you like the new look? 🎨', false),
      bubble('Looks amazing 😍', true),
      bubble('Pick any theme you like ✨', false),
    ]);
  }
}
