import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../core/demo_backend.dart';
import '../core/prefs.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'sticker_maker.dart';

String stickerUrl(Message m) {
  final s = m.meta?['sticker'] as Map?;
  if (s?['url'] != null) return AppConfig.absolute('${s!['url']}');
  if (m.media != null) return AppConfig.absolute('/api/media/${m.media!.id}/public');
  return '';
}

/// A sticker in the chat: big, no bubble.
class StickerView extends StatelessWidget {
  const StickerView({super.key, required this.message, this.size = 150});
  final Message message;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = stickerUrl(message);
    final emoji = '${(message.meta?['sticker'] as Map?)?['emoji'] ?? '🙂'}';
    return SizedBox(
      width: size,
      height: size,
      child: url.isEmpty
          ? Center(child: Text(emoji, style: TextStyle(fontSize: size * 0.5)))
          : netImage(url, fit: BoxFit.contain, errorBuilder: (_, __, ___) => Center(child: Text(emoji, style: TextStyle(fontSize: size * 0.5)))),
    );
  }
}

/// A GIF in a bubble (data saver: the small preview until tapped).
class GifView extends StatefulWidget {
  const GifView({super.key, required this.message});
  final Message message;

  @override
  State<GifView> createState() => _GifViewState();
}

class _GifViewState extends State<GifView> {
  bool _full = false;

  @override
  Widget build(BuildContext context) {
    final g = Map<String, dynamic>.from((widget.message.meta?['gif'] as Map?) ?? const {});
    final saver = context.select<AppPrefs, bool>((p) => p.dataSaver);
    final w = (g['width'] as num?)?.toDouble() ?? 220;
    final h = (g['height'] as num?)?.toDouble() ?? 160;
    final showFull = !saver || _full;
    final url = '${showFull ? g['url'] : (g['preview'] ?? g['url'])}';
    return GestureDetector(
      onTap: saver && !_full ? () => setState(() => _full = true) : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240, maxHeight: 260),
            child: AspectRatio(
              aspectRatio: (w > 0 && h > 0) ? w / h : 1.3,
              child: Image.network(url, fit: BoxFit.cover, gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => Container(color: Colors.black12, child: const Center(child: Icon(Icons.gif_box_outlined)))),
            ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Text(saver && !_full ? 'GIF · tap' : 'GIF', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Bottom sheet from the composer: stickers and GIF search.
Future<void> showStickerGifSheet(BuildContext context, int chatId, {bool openGifs = false}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.62,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _StickerGifSheet(chatId: chatId, openGifs: openGifs),
      ),
    ),
  );
}

class _StickerGifSheet extends StatefulWidget {
  const _StickerGifSheet({required this.chatId, this.openGifs = false});
  final int chatId;
  final bool openGifs;

  @override
  State<_StickerGifSheet> createState() => _StickerGifSheetState();
}

class _StickerGifSheetState extends State<_StickerGifSheet> with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthState>();
    final gifs = auth.feature('gifs');
    final stickers = auth.feature('stickers');
    _tabs = TabController(length: (gifs ? 1 : 0) + (stickers ? 1 : 0), vsync: this, initialIndex: widget.openGifs && gifs && stickers ? 1 : 0);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final gifs = auth.feature('gifs');
    final stickers = auth.feature('stickers');
    if (!gifs && !stickers) return const Center(child: Text('Stickers are turned off'));
    void close() => Navigator.pop(context);
    return Column(children: [
      PanelTabs(
        controller: _tabs,
        tabs: [
          if (stickers) (Icons.sticky_note_2_rounded, 'Stickers'),
          if (gifs) (Icons.gif_box_rounded, 'GIFs'),
        ],
      ),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          if (stickers) StickerPanel(chatId: widget.chatId, onSent: close),
          if (gifs) GifPanel(chatId: widget.chatId, onSent: close, autofocus: widget.openGifs),
        ]),
      ),
    ]);
  }
}

/// Pill-shaped tab switcher (Emoji · Stickers · GIFs).
class PanelTabs extends StatelessWidget {
  const PanelTabs({super.key, required this.tabs, this.controller, this.selected, this.onSelect});
  final List<(IconData, String)> tabs;
  final TabController? controller;
  final int? selected;
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget bar(int sel) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFEEF0F6),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(children: [
            for (var i = 0; i < tabs.length; i++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    controller?.animateTo(i);
                    onSelect?.call(i);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    height: 36,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: i == sel ? Brand.aurora : null,
                      boxShadow: i == sel ? [BoxShadow(color: Brand.rose.withValues(alpha: 0.25), blurRadius: 10, offset: const Offset(0, 3))] : null,
                    ),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(tabs[i].$1, size: 18, color: i == sel ? Colors.white : Brand.muted),
                      const SizedBox(width: 6),
                      Text(tabs[i].$2,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: i == sel ? Colors.white : Brand.muted)),
                    ]),
                  ),
                ),
              ),
          ]),
        );
    final c = controller;
    if (c == null) return bar(selected ?? 0);
    return AnimatedBuilder(animation: c, builder: (_, __) => bar(c.index));
  }
}

// ------------------------------------------------------------------ recent stickers
class RecentStickers {
  RecentStickers._();
  static const _key = 'recent_stickers';
  static const max = 24;

  static Future<List<Map<String, dynamic>>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> add(Map<String, dynamic> sticker) async {
    final list = (await load()).where((s) => s['id'] != sticker['id']).toList()
      ..insert(0, {'id': sticker['id'], 'url': sticker['url'], 'emoji': sticker['emoji'], 'pack_id': sticker['pack_id']});
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(list.take(max).toList()));
    } catch (_) {}
  }
}

/// Stickers you starred (long-press a sticker → Add to favorites).
class FavoriteStickers {
  FavoriteStickers._();
  static const _key = 'favorite_stickers';
  static const max = 40;

  static Future<List<Map<String, dynamic>>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<bool> isFavorite(Map<String, dynamic> s) async => (await load()).any((x) => x['id'] == s['id']);

  /// Adds or removes; returns true when it is now a favorite.
  static Future<bool> toggle(Map<String, dynamic> s) async {
    final list = await load();
    final had = list.any((x) => x['id'] == s['id']);
    final next = had
        ? list.where((x) => x['id'] != s['id']).toList()
        : [{'id': s['id'], 'url': s['url'], 'emoji': s['emoji'], 'pack_id': s['pack_id']}, ...list].take(max).toList();
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(next));
    } catch (_) {}
    return !had;
  }
}

/// Photo → sticker (background removal, shape, outline) → added to the user's own pack ("My stickers"
/// unless [packId] is given). Returns true when a sticker was added.
Future<bool> makeStickerFromPhoto(BuildContext context, {int? packId}) async {
  final api = context.read<AppServices>().api;
  final me = context.read<AuthState>().me?.id;
  final x = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (x == null || !context.mounted) return false;
  final made = await Navigator.push<MadeSticker>(context, MaterialPageRoute(builder: (_) => StickerMakerScreen(path: x.path)));
  if (made == null || !context.mounted) return false;
  try {
    var id = packId;
    if (id == null) {
      final packs = (await api.get('/stickers/packs') as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final mine = packs.where((p) => p['owner_id'] == me).toList();
      final named = mine.where((p) => '${p['title']}' == 'My stickers').toList();
      final pick = named.isNotEmpty ? named.first : (mine.isNotEmpty ? mine.first : null);
      id = pick == null
          ? ((Map<String, dynamic>.from(await api.post('/stickers/packs', {'title': 'My stickers'}) as Map))['id'] as num).toInt()
          : (pick['id'] as num).toInt();
    }
    final up = await api.upload(made.path, kind: 'sticker', mime: 'image/png');
    await api.post('/stickers/packs/$id/stickers', {'media_id': up['id'], 'emoji': made.emoji});
    if (context.mounted) showInfo(context, 'Sticker added to your pack');
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// Stickers: pack bar on top (Recent first), a grid below. Tap sends, long-press previews.
class StickerPanel extends StatefulWidget {
  const StickerPanel({super.key, required this.chatId, this.onSent});
  final int chatId;
  final VoidCallback? onSent;

  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel> {
  List<Map<String, dynamic>>? _packs;
  List<Map<String, dynamic>> _recent = [];
  List<Map<String, dynamic>> _favs = [];
  int _sel = 0; // -1 = favorites, 0 = recent (when there are recents), otherwise pack index + 1

  @override
  void initState() {
    super.initState();
    context.read<ChatStore>().sendTyping(widget.chatId, action: 'choosing_sticker');
    _load();
  }

  Future<void> _load() async {
    final recent = await RecentStickers.load();
    final favs = await FavoriteStickers.load();
    if (mounted) setState(() => _favs = favs);
    try {
      final r = await context.read<AppServices>().api.get('/stickers/packs') as List;
      if (!mounted) return;
      setState(() {
        _recent = recent;
        _packs = r.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _sel = recent.isEmpty ? 1 : 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recent = recent;
        _packs = [];
        _sel = 0;
      });
      if (recent.isEmpty) showError(context, e);
    }
  }

  void _send(Map<String, dynamic> sticker) {
    final store = context.read<ChatStore>();
    HapticFeedback.selectionClick();
    widget.onSent?.call();
    store.sendSticker(widget.chatId, sticker);
    RecentStickers.add(sticker);
  }

  Future<void> _preview(Map<String, dynamic> sticker) async {
    HapticFeedback.mediumImpact();
    final send = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: 0.55),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, __) => Material(
        type: MaterialType.transparency,
        child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 230,
            height: 230,
            child: netImage(AppConfig.absolute('${sticker['url']}'), fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Center(child: Text('${sticker['emoji']}', style: const TextStyle(fontSize: 120)))),
          ),
          const SizedBox(height: 10),
          Text('${sticker['emoji'] ?? ''}', style: const TextStyle(fontSize: 30)),
          const SizedBox(height: 14),
          SizedBox(width: 180, child: AuroraButtonLite(label: 'Send sticker', onPressed: () => Navigator.pop(ctx, true))),
          const SizedBox(height: 8),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () async {
              final on = await FavoriteStickers.toggle(sticker);
              final favs = await FavoriteStickers.load();
              if (mounted) setState(() => _favs = favs);
              if (ctx.mounted) Navigator.pop(ctx, false);
              if (mounted) showInfo(context, on ? 'Added to favorites ⭐' : 'Removed from favorites');
            },
            icon: Icon(_favs.any((x) => x['id'] == sticker['id']) ? Icons.star_rounded : Icons.star_outline_rounded),
            label: Text(_favs.any((x) => x['id'] == sticker['id']) ? 'Remove from favorites' : 'Add to favorites'),
          ),
        ]),
        ),
      ),
      transitionBuilder: (_, a, __, child) => ScaleTransition(
        scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
        child: FadeTransition(opacity: a, child: child),
      ),
    );
    if (send == true && mounted) _send(sticker);
  }

  @override
  Widget build(BuildContext context) {
    final packs = _packs;
    if (packs == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hasRecent = _recent.isNotEmpty;
    final List<Map<String, dynamic>> stickers;
    String title;
    if (_sel == -1 && _favs.isNotEmpty) {
      stickers = _favs;
      title = 'Favorites';
    } else if (_sel == 0 && hasRecent) {
      stickers = _recent;
      title = 'Recently used';
    } else {
      final idx = (_sel - 1).clamp(0, packs.isEmpty ? 0 : packs.length - 1);
      final current = packs.isEmpty ? null : packs[idx];
      stickers = ((current?['stickers'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      title = '${current?['title'] ?? 'Stickers'}';
    }
    Widget packButton({required bool selected, required Widget child, required VoidCallback onTap, String? tooltip}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
          child: Tooltip(
            message: tooltip ?? '',
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 46,
                decoration: BoxDecoration(
                  gradient: selected ? Brand.auroraSoft(dark) : null,
                  borderRadius: BorderRadius.circular(14),
                  border: selected ? Border.all(color: Brand.primary.withValues(alpha: 0.35), width: 1.4) : null,
                ),
                padding: const EdgeInsets.all(5),
                child: child,
              ),
            ),
          ),
        );
    return Column(children: [
      SizedBox(
        height: 56,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          packButton(
            selected: false,
            tooltip: 'Make a sticker from a photo',
            onTap: () async {
              if (await makeStickerFromPhoto(context) && mounted) _load();
            },
            child: const Icon(Icons.auto_fix_high_rounded, color: Brand.primary),
          ),
          if (_favs.isNotEmpty)
            packButton(
              selected: _sel == -1,
              tooltip: 'Favorites',
              onTap: () => setState(() => _sel = -1),
              child: Icon(Icons.star_rounded, color: _sel == -1 ? Brand.amber : Brand.muted),
            ),
          if (hasRecent)
            packButton(
              selected: _sel == 0,
              tooltip: 'Recent',
              onTap: () => setState(() => _sel = 0),
              child: Icon(Icons.access_time_rounded, color: _sel == 0 ? Brand.primary : Brand.muted),
            ),
          for (var i = 0; i < packs.length; i++)
            packButton(
              selected: _sel == i + 1 || (!hasRecent && _sel == 0 && i == 0),
              tooltip: '${packs[i]['title'] ?? ''}',
              onTap: () => setState(() => _sel = i + 1),
              child: packs[i]['cover_url'] == null
                  ? const Icon(Icons.emoji_emotions_outlined)
                  : netImage(AppConfig.absolute('${packs[i]['cover_url']}'), fit: BoxFit.contain),
            ),
          packButton(
            selected: false,
            tooltip: 'Sticker packs',
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const StickerPacksScreen()));
              if (mounted) _load();
            },
            child: const Icon(Icons.add_rounded, color: Brand.muted),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(title.toUpperCase(), style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: Brand.muted)),
        ),
      ),
      Expanded(
        child: stickers.isEmpty
            ? const Center(child: Text('No stickers here yet', style: TextStyle(color: Brand.muted)))
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 86, mainAxisSpacing: 6, crossAxisSpacing: 6),
                itemCount: stickers.length,
                itemBuilder: (_, i) => _StickerCell(
                  sticker: stickers[i],
                  onTap: () => _send(stickers[i]),
                  onLongPress: () => _preview(stickers[i]),
                ),
              ),
      ),
    ]);
  }
}

/// A sticker in the picker: shrinks a little while pressed.
class _StickerCell extends StatefulWidget {
  const _StickerCell({required this.sticker, required this.onTap, required this.onLongPress});
  final Map<String, dynamic> sticker;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_StickerCell> createState() => _StickerCellState();
}

class _StickerCellState extends State<_StickerCell> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.sticker;
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      onLongPress: () {
        setState(() => _down = false);
        widget.onLongPress();
      },
      child: AnimatedScale(
        scale: _down ? 0.86 : 1,
        duration: const Duration(milliseconds: 120),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: netImage(AppConfig.absolute('${s['url']}'), fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Center(child: Text('${s['emoji']}', style: const TextStyle(fontSize: 36)))),
        ),
      ),
    );
  }
}

/// GIFs: trending + search. [searchOnly] = a tap on the search field opens the full sheet (the inline panel hides
/// while the keyboard is up, so typing happens in the sheet).
class GifPanel extends StatefulWidget {
  const GifPanel({super.key, required this.chatId, this.onSent, this.onSearchTap, this.autofocus = false});
  final int chatId;
  final VoidCallback? onSent;
  final VoidCallback? onSearchTap;
  final bool autofocus;

  @override
  State<GifPanel> createState() => _GifPanelState();
}

class _GifPanelState extends State<GifPanel> {
  final _q = TextEditingController();
  final _results = <Map<String, dynamic>>[];
  String? _next;
  bool _loading = false;
  bool _loadedOnce = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _search({bool more = false}) async {
    if (_loading || (more && _next == null)) return;
    setState(() => _loading = true);
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/gifs', query: {
        if (_q.text.trim().isNotEmpty) 'q': _q.text.trim(),
        if (more && _next != null) 'pos': _next!,
      }) as Map);
      if (!mounted) return;
      setState(() {
        if (!more) _results.clear();
        _results.addAll((r['results'] as List).map((e) => Map<String, dynamic>.from(e as Map)));
        _next = r['next'] as String?;
      });
    } catch (e) {
      if (mounted && !more) showError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadedOnce = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final placeholder = dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFEEF0F6);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        child: TextField(
          controller: _q,
          autofocus: widget.autofocus,
          readOnly: widget.onSearchTap != null,
          onTap: widget.onSearchTap,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: 'Search GIFs',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 11),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: const BorderSide(color: Brand.primary, width: 1.4)),
            suffixIcon: _q.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () {
                      _q.clear();
                      _search();
                    },
                  ),
          ),
          onChanged: (_) {
            setState(() {});
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 450), _search);
          },
        ),
      ),
      Expanded(
        child: _loadedOnce && !_loading && _results.isEmpty
            ? Center(child: Text(_q.text.isEmpty ? 'GIFs are not available right now' : 'No GIFs found', style: const TextStyle(color: Brand.muted)))
            : NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.metrics.extentAfter < 300) _search(more: true);
                  return false;
                },
                child: GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 150, mainAxisSpacing: 6, crossAxisSpacing: 6),
                  itemCount: _results.isEmpty && _loading ? 9 : _results.length,
                  itemBuilder: (_, i) {
                    if (_results.isEmpty) {
                      return DecoratedBox(decoration: BoxDecoration(color: placeholder, borderRadius: BorderRadius.circular(12)));
                    }
                    final g = _results[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        final store = context.read<ChatStore>();
                        widget.onSent?.call();
                        store.sendGif(widget.chatId, {
                          'url': g['url'],
                          'preview': g['preview'],
                          'mp4': g['mp4'],
                          'width': g['width'],
                          'height': g['height'],
                        });
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: ColoredBox(
                          color: placeholder,
                          child: Image.network('${g['preview']}', fit: BoxFit.cover, gaplessPlayback: true,
                              errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.gif_box_outlined, color: Brand.muted))),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
      if (_loading && _results.isNotEmpty) const LinearProgressIndicator(minHeight: 2),
      const Padding(padding: EdgeInsets.only(bottom: 4, top: 2), child: Text('Powered by Tenor', style: TextStyle(fontSize: 10.5, color: Brand.muted))),
    ]);
  }
}

/// Small gradient button used inside dialogs of this file (keeps widgets/premium.dart free of a cycle).
class AuroraButtonLite extends StatelessWidget {
  const AuroraButtonLite({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Ink(
            height: 48,
            decoration: BoxDecoration(gradient: Brand.aurora, borderRadius: BorderRadius.circular(16)),
            child: Center(child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15))),
          ),
        ),
      );
}

// ------------------------------------------------------------------ manage packs
class StickerPacksScreen extends StatefulWidget {
  const StickerPacksScreen({super.key});

  @override
  State<StickerPacksScreen> createState() => _StickerPacksScreenState();
}

class _StickerPacksScreenState extends State<StickerPacksScreen> {
  List<Map<String, dynamic>>? _mine;
  List<Map<String, dynamic>> _found = [];
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppServices>().api;
    try {
      final mine = await api.get('/stickers/packs') as List;
      final found = await api.get('/stickers/search', query: {'q': _q.text.trim()}) as List;
      if (!mounted) return;
      setState(() {
        _mine = mine.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        final ids = _mine!.map((p) => p['id']).toSet();
        _found = found.map((e) => Map<String, dynamic>.from(e as Map)).where((p) => !ids.contains(p['id'])).toList();
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _create() async {
    final ctrl = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New sticker pack'),
        content: TextField(controller: ctrl, autofocus: true, maxLength: 64, decoration: const InputDecoration(hintText: 'Pack name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    if (title == null || title.isEmpty || !mounted) return;
    try {
      final p = Map<String, dynamic>.from(await context.read<AppServices>().api.post('/stickers/packs', {'title': title}) as Map);
      if (!mounted) return;
      await Navigator.push(context, MaterialPageRoute(builder: (_) => StickerPackScreen(packId: (p['id'] as num).toInt())));
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _tile(Map<String, dynamic> p, {required bool installed}) {
    final me = context.read<AuthState>().me?.id;
    final own = p['owner_id'] == me;
    return ListTile(
      leading: SizedBox(
        width: 44,
        height: 44,
        child: p['cover_url'] == null ? const Icon(Icons.emoji_emotions_outlined) : netImage(AppConfig.absolute('${p['cover_url']}')),
      ),
      title: Text('${p['title']}'),
      subtitle: Text(p['is_official'] == true ? 'Official · ${(p['stickers'] as List?)?.length ?? 0} stickers' : own ? 'Your pack' : '${p['installs']} people use it'),
      trailing: p['is_official'] == true
          ? null
          : installed
              ? (own ? const Icon(Icons.chevron_right) : TextButton(onPressed: () => _toggle(p, false), child: const Text('Remove')))
              : FilledButton.tonal(onPressed: () => _toggle(p, true), child: const Text('Add')),
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => StickerPackScreen(packId: (p['id'] as num).toInt())));
        _load();
      },
    );
  }

  Future<void> _toggle(Map<String, dynamic> p, bool add) async {
    try {
      await context.read<AppServices>().api.post('/stickers/packs/${p['id']}/${add ? 'install' : 'uninstall'}');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mine = _mine;
    return Scaffold(
      appBar: AppBar(title: const Text('Stickers')),
      floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('New pack')),
      body: mine == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text('My stickers', style: TextStyle(fontWeight: FontWeight.w700))),
              ...mine.map((p) => _tile(p, installed: true)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: TextField(
                  controller: _q,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Find sticker packs', isDense: true),
                  onSubmitted: (_) => _load(),
                ),
              ),
              ..._found.map((p) => _tile(p, installed: false)),
              const SizedBox(height: 90),
            ]),
    );
  }
}

/// One pack: view its stickers; the owner can add (from the gallery) and remove stickers.
class StickerPackScreen extends StatefulWidget {
  const StickerPackScreen({super.key, required this.packId});
  final int packId;

  @override
  State<StickerPackScreen> createState() => _StickerPackScreenState();
}

class _StickerPackScreenState extends State<StickerPackScreen> {
  Map<String, dynamic>? _pack;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/stickers/packs/${widget.packId}') as Map);
      if (mounted) setState(() => _pack = p);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Photo → sticker maker (background removal, shape, outline) → this pack.
  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      if (await makeStickerFromPhoto(context, packId: widget.packId)) await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _pack;
    final me = context.read<AuthState>().me?.id;
    final own = p != null && p['owner_id'] == me;
    final list = ((p?['stickers'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(p == null ? 'Sticker pack' : '${p['title']}'),
        actions: [
          if (own)
            IconButton(
              tooltip: 'Delete pack',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (!await confirm(context, 'Delete this pack?', 'Stickers you already sent stay in the chats.', ok: 'Delete', danger: true)) return;
                if (!context.mounted) return;
                try {
                  await context.read<AppServices>().api.delete('/stickers/packs/${widget.packId}');
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
            ),
        ],
      ),
      floatingActionButton: own
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _add,
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add sticker'),
            )
          : null,
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
              ? Center(child: Text(own ? 'Add pictures to make your stickers.\nTip: PNGs with a transparent background look best.' : 'No stickers yet', textAlign: TextAlign.center))
              : GridView.builder(
                  padding: const EdgeInsets.all(14),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 110, mainAxisSpacing: 10, crossAxisSpacing: 10),
                  itemCount: list.length,
                  itemBuilder: (_, i) => GestureDetector(
                    onLongPress: !own
                        ? null
                        : () async {
                            if (!await confirm(context, 'Remove this sticker?', '', ok: 'Remove', danger: true)) return;
                            if (!context.mounted) return;
                            try {
                              await context.read<AppServices>().api.delete('/stickers/packs/${widget.packId}/stickers/${list[i]['id']}');
                              _load();
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          },
                    child: netImage(AppConfig.absolute('${list[i]['url']}')),
                  ),
                ),
    );
  }
}
