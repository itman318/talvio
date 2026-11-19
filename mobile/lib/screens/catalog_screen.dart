import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../core/image_store.dart';
import '../core/services.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'chat_screen.dart';
import 'coins_screen.dart' show fmtCoins;
import 'orders_screen.dart';

/// One product of a business catalog.
class CatalogItem {
  CatalogItem.fromJson(Map<String, dynamic> j)
      : id = (j['id'] as num).toInt(),
        ownerId = (j['owner_id'] as num).toInt(),
        title = '${j['title']}',
        description = '${j['description'] ?? ''}',
        priceText = j['price_text'] as String?,
        priceCoins = (j['price_coins'] as num?)?.toInt(),
        photoUrl = j['photo_url'] as String?,
        soldOut = j['sold_out'] == true,
        sold = (j['sold'] as num?)?.toInt() ?? 0;
  final int id;
  final int ownerId;
  final String title;
  final String description;
  final String? priceText;
  final int? priceCoins;
  final String? photoUrl;
  final bool soldOut;
  final int sold;

  /// "Rs 2,500 · 500 🪙", "500 🪙", "Rs 2,500" or "Ask for price"
  String get price {
    final parts = [if (priceText != null && priceText!.isNotEmpty) priceText!, if (priceCoins != null) '${fmtCoins(priceCoins!)} 🪙'];
    return parts.isEmpty ? 'Ask for price' : parts.join(' · ');
  }
}

/// A business's products: a photo grid. Customers order in the chat or buy with coins;
/// the owner adds, edits and marks products sold out.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.userId, required this.name});
  final int userId;
  final String name;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  List<CatalogItem>? _items;
  bool _mine = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/users/${widget.userId}/catalog') as Map);
      if (!mounted) return;
      setState(() {
        _mine = r['mine'] == true;
        _items = [for (final j in r['items'] as List) CatalogItem.fromJson(Map<String, dynamic>.from(j as Map))];
      });
    } catch (e) {
      if (mounted) {
        setState(() => _items = const []);
        showError(context, e);
      }
    }
  }

  Future<void> _edit([CatalogItem? item]) async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => CatalogEditScreen(item: item)));
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: Text(_mine ? 'My catalog' : widget.name), actions: [
        IconButton(
          tooltip: _mine ? 'Customer orders' : 'My orders',
          icon: const Icon(Icons.receipt_long_rounded),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => OrdersScreen(seller: _mine))),
        ),
      ]),
      floatingActionButton: _mine
          ? FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(Icons.add_rounded), label: const Text('Add product'))
          : null,
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.storefront_rounded, size: 56, color: Brand.muted),
                      const SizedBox(height: 12),
                      Text(_mine ? 'Show what you sell' : 'No products yet',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text(
                        _mine
                            ? 'Add photos, prices and a short description. Customers open your catalog from your profile and order in the chat — or pay with coins.'
                            : 'This business hasn’t added products yet.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Brand.muted, height: 1.4),
                      ),
                    ]),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 96),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.72),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _Tile(
                      item: items[i],
                      onTap: () async {
                        if (_mine) {
                          await _edit(items[i]);
                        } else {
                          final changed = await showProductSheet(context, items[i], widget.name);
                          if (changed == true) _load();
                        }
                      },
                    ),
                  ),
                ),
    );
  }
}

class _Photo extends StatelessWidget {
  const _Photo({required this.url, this.radius = 16});
  final String? url;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final empty = Container(
      color: dark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFEEF0F6),
      alignment: Alignment.center,
      child: const Icon(Icons.shopping_bag_outlined, size: 36, color: Brand.muted),
    );
    if (url == null) return empty;
    return CachedNetworkImage(
      imageUrl: AppConfig.absolute(url!),
      cacheManager: imageStore,
      fit: BoxFit.cover,
      memCacheWidth: 600,
      placeholder: (_, __) => empty,
      errorWidget: (_, __, ___) => empty,
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.item, required this.onTap});
  final CatalogItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              _Photo(url: item.photoUrl),
              if (item.soldOut)
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(10)),
                    child: const Text('Sold out', style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 11),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
              const SizedBox(height: 3),
              Text(item.price, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Brand.primary, fontWeight: FontWeight.w800, fontSize: 13.5)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A product for a customer: big photo, price, description, "Order in chat" and "Buy with coins".
Future<bool?> showProductSheet(BuildContext context, CatalogItem item, String seller) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _ProductSheet(item: item, seller: seller),
  );
}

class _ProductSheet extends StatefulWidget {
  const _ProductSheet({required this.item, required this.seller});
  final CatalogItem item;
  final String seller;

  @override
  State<_ProductSheet> createState() => _ProductSheetState();
}

class _ProductSheetState extends State<_ProductSheet> {
  bool _busy = false;

  Future<void> _order() async {
    final it = widget.item;
    final details = await _askOrder(context, it);
    if (details == null || !mounted) return;
    final api = context.read<AppServices>().api;
    final store = context.read<ChatStore>();
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final r = Map<String, dynamic>.from(await api.post('/catalog/${it.id}/order', details) as Map);
      final chatId = (r['chat_id'] as num?)?.toInt();
      nav.pop();
      if (chatId != null) nav.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId, initial: store.chatById(chatId))));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// how many, and a note for the seller (size, colour, address…)
  static Future<Map<String, dynamic>?> _askOrder(BuildContext context, CatalogItem it) {
    var qty = 1;
    final note = TextEditingController();
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Order “${it.title}”'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(it.price, style: const TextStyle(fontWeight: FontWeight.w800, color: Brand.primary)),
            const SizedBox(height: 12),
            Row(children: [
              const Text('Quantity', style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton.filledTonal(onPressed: qty > 1 ? () => set(() => qty--) : null, icon: const Icon(Icons.remove_rounded, size: 18)),
              SizedBox(width: 34, child: Text('$qty', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
              IconButton.filledTonal(onPressed: qty < 99 ? () => set(() => qty++) : null, icon: const Icon(Icons.add_rounded, size: 18)),
            ]),
            const SizedBox(height: 8),
            TextField(
              controller: note,
              maxLength: 300,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(hintText: 'Note for the seller — size, colour, address (optional)'),
            ),
            const Text('The order is sent in your chat. You can follow it in Orders.', style: TextStyle(color: Brand.muted, fontSize: 12.5)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, {'qty': qty, 'note': note.text.trim()}), child: const Text('Send order')),
          ],
        ),
      ),
    );
  }

  Future<void> _buy() async {
    final it = widget.item;
    final ok = await confirm(context, 'Buy “${it.title}”?',
        '${fmtCoins(it.priceCoins!)} coins go to ${widget.seller} now. Your order is sent to them in the chat and you can follow it in Orders. If the seller cancels it, your coins come back.',
        ok: 'Pay ${fmtCoins(it.priceCoins!)} 🪙');
    if (!ok || !mounted) return;
    final api = context.read<AppServices>().api;
    final store = context.read<ChatStore>();
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final r = Map<String, dynamic>.from(await api.post('/catalog/${it.id}/buy', {'expected_coins': it.priceCoins}) as Map);
      final chatId = (r['chat_id'] as num?)?.toInt();
      nav.pop(true);
      if (chatId != null) nav.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId, initial: store.chatById(chatId))));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final coinsOn = context.read<AuthState>().feature('coins');
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        AspectRatio(aspectRatio: 1.2, child: _Photo(url: it.photoUrl, radius: 0)),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(it.title, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            const SizedBox(height: 6),
            Text(it.price, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Brand.primary)),
            if (it.sold > 0) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${it.sold} sold', style: const TextStyle(color: Brand.muted, fontSize: 13))),
            if (it.description.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(it.description, style: const TextStyle(fontSize: 15, height: 1.45)),
            ],
            const SizedBox(height: 20),
            if (it.soldOut)
              const Text('This product is sold out. You can still ask the seller in the chat.', style: TextStyle(color: Brand.muted)),
            if (it.soldOut) const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _order,
                  icon: const Icon(Icons.chat_bubble_outline_rounded, size: 19),
                  label: const Text('Order in chat'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: const StadiumBorder()),
                ),
              ),
              if (it.priceCoins != null && !it.soldOut && coinsOn) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _buy,
                    icon: const Icon(Icons.monetization_on_rounded, size: 19),
                    label: const Text('Buy with coins'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: const StadiumBorder()),
                  ),
                ),
              ],
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// Add or edit one product (owner).
class CatalogEditScreen extends StatefulWidget {
  const CatalogEditScreen({super.key, this.item});
  final CatalogItem? item;

  @override
  State<CatalogEditScreen> createState() => _CatalogEditScreenState();
}

class _CatalogEditScreenState extends State<CatalogEditScreen> {
  late final _title = TextEditingController(text: widget.item?.title ?? '');
  late final _desc = TextEditingController(text: widget.item?.description ?? '');
  late final _price = TextEditingController(text: widget.item?.priceText ?? '');
  late final _coins = TextEditingController(text: widget.item?.priceCoins?.toString() ?? '');
  late bool _soldOut = widget.item?.soldOut ?? false;
  late String? _photoUrl = widget.item?.photoUrl;
  int? _photoId;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _price.dispose();
    _coins.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1400, imageQuality: 85);
    if (x == null || !mounted) return;
    final api = context.read<AppServices>().api;
    setState(() => _busy = true);
    try {
      final m = await api.upload(x.path, kind: 'image');
      if (!mounted) return;
      setState(() {
        _photoId = (m['id'] as num).toInt();
        _photoUrl = '/api/media/$_photoId';
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      showInfo(context, 'Give the product a name');
      return;
    }
    final api = context.read<AppServices>().api;
    final body = {
      'title': _title.text.trim(),
      'description': _desc.text.trim(),
      'price_text': _price.text.trim().isEmpty ? null : _price.text.trim(),
      'price_coins': _coins.text.trim().isEmpty ? null : int.tryParse(_coins.text.trim()),
      'sold_out': _soldOut,
      if (_photoId != null) 'photo_media_id': _photoId,
    };
    setState(() => _busy = true);
    try {
      if (widget.item == null) {
        await api.post('/me/catalog', body);
      } else {
        await api.put('/me/catalog/${widget.item!.id}', body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (!await confirm(context, 'Delete “${widget.item!.title}”?', 'It disappears from your catalog.', ok: 'Delete', danger: true)) return;
    if (!mounted) return;
    try {
      await context.read<AppServices>().api.delete('/me/catalog/${widget.item!.id}');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration dec(String label, {String? hint, IconData? icon}) => InputDecoration(labelText: label, hintText: hint, prefixIcon: icon == null ? null : Icon(icon));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.item == null ? 'New product' : 'Edit product'),
        actions: [
          if (widget.item != null) IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete),
          TextButton(onPressed: _busy ? null : _save, child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
        GestureDetector(
          onTap: _busy ? null : _pick,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: AspectRatio(
              aspectRatio: 1.4,
              child: Stack(fit: StackFit.expand, children: [
                if (_photoId != null)
                  Container(
                    color: Brand.primary.withValues(alpha: 0.08),
                    alignment: Alignment.center,
                    child: const Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.check_circle_rounded, color: Brand.accent, size: 40),
                      SizedBox(height: 6),
                      Text('New photo ready', style: TextStyle(fontWeight: FontWeight.w700)),
                    ]),
                  )
                else
                  _Photo(url: _photoUrl, radius: 0),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(20)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.add_a_photo_rounded, color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Text(_photoUrl == null ? 'Add photo' : 'Change photo', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                    ]),
                  ),
                ),
                if (_busy) const Center(child: CircularProgressIndicator()),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(controller: _title, maxLength: 80, textCapitalization: TextCapitalization.sentences, decoration: dec('Name', icon: Icons.shopping_bag_outlined)),
        TextField(controller: _price, maxLength: 40, decoration: dec('Price (optional)', hint: 'e.g. Rs 2,500', icon: Icons.sell_outlined)),
        TextField(
          controller: _coins,
          keyboardType: TextInputType.number,
          decoration: dec('Price in coins (optional)', hint: 'Lets customers buy right away', icon: Icons.monetization_on_outlined),
        ),
        const SizedBox(height: 14),
        TextField(controller: _desc, maxLength: 1000, minLines: 3, maxLines: 8, textCapitalization: TextCapitalization.sentences, decoration: dec('Description', hint: 'Size, colour, delivery…')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _soldOut,
          onChanged: (v) => setState(() => _soldOut = v),
          title: const Text('Sold out'),
          subtitle: const Text('Stays in the catalog, but can’t be bought'),
        ),
      ]),
    );
  }
}
