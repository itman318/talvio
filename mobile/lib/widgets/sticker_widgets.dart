import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/demo_backend.dart';
import '../core/prefs.dart';
import '../core/services.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';

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
Future<void> showStickerGifSheet(BuildContext context, int chatId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SizedBox(height: MediaQuery.of(context).size.height * 0.55, child: _StickerGifSheet(chatId: chatId)),
  );
}

class _StickerGifSheet extends StatefulWidget {
  const _StickerGifSheet({required this.chatId});
  final int chatId;

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
    _tabs = TabController(length: (gifs ? 1 : 0) + (stickers ? 1 : 0), vsync: this);
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
    return Column(children: [
      TabBar(
        controller: _tabs,
        dividerColor: Colors.transparent,
        tabs: [if (stickers) const Tab(text: 'Stickers'), if (gifs) const Tab(text: 'GIFs')],
      ),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          if (stickers) _StickerTab(chatId: widget.chatId),
          if (gifs) _GifTab(chatId: widget.chatId),
        ]),
      ),
    ]);
  }
}

class _StickerTab extends StatefulWidget {
  const _StickerTab({required this.chatId});
  final int chatId;

  @override
  State<_StickerTab> createState() => _StickerTabState();
}

class _StickerTabState extends State<_StickerTab> {
  List<Map<String, dynamic>>? _packs;
  int _sel = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppServices>().api.get('/stickers/packs') as List;
      if (mounted) setState(() => _packs = r.map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } catch (e) {
      if (mounted) {
        setState(() => _packs = []);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final packs = _packs;
    if (packs == null) return const Center(child: CircularProgressIndicator());
    final current = packs.isEmpty ? null : packs[_sel.clamp(0, packs.length - 1)];
    final stickers = ((current?['stickers'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return Column(children: [
      SizedBox(
        height: 56,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          for (var i = 0; i < packs.length; i++)
            Padding(
              padding: const EdgeInsets.all(4),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _sel = i),
                child: Container(
                  width: 48,
                  decoration: BoxDecoration(
                    color: i == _sel ? Theme.of(context).colorScheme.surfaceContainerHighest : null,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(5),
                  child: packs[i]['cover_url'] == null
                      ? const Icon(Icons.emoji_emotions_outlined)
                      : netImage(AppConfig.absolute('${packs[i]['cover_url']}')),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Sticker packs',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const StickerPacksScreen()));
              _load();
            },
          ),
        ]),
      ),
      Expanded(
        child: stickers.isEmpty
            ? const Center(child: Text('No stickers in this pack yet'))
            : GridView.builder(
                padding: const EdgeInsets.all(10),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 90, mainAxisSpacing: 8, crossAxisSpacing: 8),
                itemCount: stickers.length,
                itemBuilder: (_, i) => InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.pop(context);
                    context.read<ChatStore>().sendSticker(widget.chatId, stickers[i]);
                  },
                  child: netImage(AppConfig.absolute('${stickers[i]['url']}'), errorBuilder: (_, __, ___) => Center(child: Text('${stickers[i]['emoji']}'))),
                ),
              ),
      ),
    ]);
  }
}

class _GifTab extends StatefulWidget {
  const _GifTab({required this.chatId});
  final int chatId;

  @override
  State<_GifTab> createState() => _GifTabState();
}

class _GifTabState extends State<_GifTab> {
  final _q = TextEditingController();
  final _results = <Map<String, dynamic>>[];
  String? _next;
  bool _loading = false;
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
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: TextField(
          controller: _q,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search GIFs', isDense: true),
          onChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 450), _search);
          },
        ),
      ),
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.extentAfter < 300) _search(more: true);
            return false;
          },
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 160, mainAxisSpacing: 6, crossAxisSpacing: 6),
            itemCount: _results.length,
            itemBuilder: (_, i) {
              final g = _results[i];
              return InkWell(
                onTap: () {
                  Navigator.pop(context);
                  context.read<ChatStore>().sendGif(widget.chatId, {
                    'url': g['url'],
                    'preview': g['preview'],
                    'mp4': g['mp4'],
                    'width': g['width'],
                    'height': g['height'],
                  });
                },
                child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.network('${g['preview']}', fit: BoxFit.cover)),
              );
            },
          ),
        ),
      ),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      const Padding(padding: EdgeInsets.only(bottom: 6), child: Text('Powered by Tenor', style: TextStyle(fontSize: 11, color: Brand.muted))),
    ]);
  }
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

  /// Picks a picture, makes it a 512×512 PNG sticker and uploads it.
  Future<void> _add() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null || !mounted) return;
    final emoji = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Pick an emoji for it'),
        children: [
          Wrap(alignment: WrapAlignment.center, children: [
            for (final e in const ['😀', '😂', '😍', '😎', '🤔', '😢', '😡', '👍', '🙏', '🎉', '❤️', '🔥', '👋', '😴', '☕', '🌙'])
              InkWell(onTap: () => Navigator.pop(ctx, e), child: Padding(padding: const EdgeInsets.all(10), child: Text(e, style: const TextStyle(fontSize: 28)))),
          ]),
        ],
      ),
    );
    if (emoji == null || !mounted) return;
    setState(() => _busy = true);
    final api = context.read<AppServices>().api;
    try {
      final bytes = await File(x.path).readAsBytes();
      final png = await Future(() {
        final src = img.decodeImage(bytes);
        if (src == null) throw Exception('This picture could not be read');
        final fitted = img.copyResize(src, width: src.width >= src.height ? 512 : null, height: src.height > src.width ? 512 : null, interpolation: img.Interpolation.average);
        return img.encodePng(fitted, level: 6);
      });
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/sticker_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(png);
      final up = await api.upload(f.path, kind: 'sticker', mime: 'image/png');
      await api.post('/stickers/packs/${widget.packId}/stickers', {'media_id': up['id'], 'emoji': emoji});
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
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
