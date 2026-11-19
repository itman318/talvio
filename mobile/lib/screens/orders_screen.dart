import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services.dart';
import '../models/models.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import 'chat_screen.dart';
import 'coins_screen.dart' show fmtCoins;

/// Order tracker: what I ordered, and (for a business) what customers ordered from me.
/// received → packed → shipped → delivered; the seller moves it, both see each step.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key, this.seller = false});
  final bool seller; // open on "Customer orders"

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

const _steps = ['received', 'packed', 'shipped', 'delivered'];
const _labels = {
  'received': 'Received',
  'packed': 'Packed',
  'shipped': 'Shipped',
  'delivered': 'Delivered',
  'cancelled': 'Cancelled',
};
const _icons = {
  'received': Icons.inbox_rounded,
  'packed': Icons.inventory_2_rounded,
  'shipped': Icons.local_shipping_rounded,
  'delivered': Icons.check_circle_rounded,
  'cancelled': Icons.cancel_rounded,
};

Color _colorOf(String s) => switch (s) {
      'delivered' => Brand.green,
      'cancelled' => Brand.rose,
      'shipped' => Brand.sky,
      'packed' => Brand.amber,
      _ => Brand.violet,
    };

class _OrdersScreenState extends State<OrdersScreen> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: widget.seller ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Orders'),
          bottom: const TabBar(tabs: [Tab(text: 'My orders'), Tab(text: 'Customer orders')]),
        ),
        body: const TabBarView(children: [_OrderList(role: 'buyer'), _OrderList(role: 'seller')]),
      ),
    );
  }
}

class _OrderList extends StatefulWidget {
  const _OrderList({required this.role});
  final String role;

  @override
  State<_OrderList> createState() => _OrderListState();
}

class _OrderListState extends State<_OrderList> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>>? _orders;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/me/orders?role=${widget.role}') as Map);
      if (mounted) setState(() => _orders = [for (final o in r['orders'] as List) Map<String, dynamic>.from(o as Map)]);
    } catch (e) {
      if (mounted) {
        setState(() => _orders ??= const []);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final list = _orders;
    if (list == null) return const Center(child: CircularProgressIndicator());
    if (list.isEmpty) {
      final seller = widget.role == 'seller';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(seller ? Icons.storefront_rounded : Icons.shopping_bag_outlined, size: 56, color: Brand.muted),
            const SizedBox(height: 12),
            Text(seller ? 'No customer orders yet' : 'No orders yet', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              seller
                  ? 'When someone orders from your catalog, it shows here. Update each order and the customer sees where it is.'
                  : 'Order from a business catalog and follow it here — packed, shipped, delivered.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Brand.muted, height: 1.4),
            ),
          ]),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 30),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _OrderCard(
          order: list[i],
          seller: widget.role == 'seller',
          onChanged: (o) => setState(() => list[i] = {...list[i], ...o}),
        ),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.seller, required this.onChanged});
  final Map<String, dynamic> order;
  final bool seller;
  final ValueChanged<Map<String, dynamic>> onChanged;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final status = '${o['status']}';
    final peerJson = (seller ? o['buyer'] : o['seller']) as Map?;
    final peer = peerJson == null ? null : AppUser.fromJson(Map<String, dynamic>.from(peerJson));
    final qty = (o['qty'] as num?)?.toInt() ?? 1;
    final coins = (o['coins'] as num?)?.toInt() ?? 0;
    final price = coins > 0 ? '${fmtCoins(coins)} coins 🪙' : (o['price_text'] as String? ?? 'Price agreed in chat');
    final color = _colorOf(status);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openOrder(context, o, seller, onChanged),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('#${o['id']}', style: const TextStyle(color: Brand.muted, fontWeight: FontWeight.w700, fontSize: 12.5)),
              const SizedBox(width: 8),
              Text(_day(o['created_at'] as String?), style: const TextStyle(color: Brand.muted, fontSize: 12.5)),
              const Spacer(),
              _StatusChip(status: status),
            ]),
            const SizedBox(height: 8),
            Text('${o['title']}${qty > 1 ? '  × $qty' : ''}', style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(price, style: TextStyle(color: color == Brand.rose ? Brand.muted : Brand.primary, fontWeight: FontWeight.w700)),
            if (peer != null) ...[
              const SizedBox(height: 10),
              Row(children: [
                Avatar(id: peer.id, name: peer.name, url: peer.avatarAbsolute, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${seller ? 'From' : 'Sold by'} ${peer.name}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: Brand.muted)),
                ),
              ]),
            ],
            const SizedBox(height: 12),
            _Progress(status: status),
          ]),
        ),
      ),
    );
  }
}

String _day(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  return d == null ? '' : shortDate(d);
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final c = _colorOf(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: .14), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_icons[status] ?? Icons.circle, size: 14, color: c),
        const SizedBox(width: 4),
        Text(_labels[status] ?? status, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12)),
      ]),
    );
  }
}

/// four dots joined by a line; done steps are filled
class _Progress extends StatelessWidget {
  const _Progress({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    if (status == 'cancelled') {
      return const Text('This order was cancelled', style: TextStyle(color: Brand.muted, fontSize: 13));
    }
    final at = _steps.indexOf(status);
    final track = Theme.of(context).colorScheme.outlineVariant;
    return Row(children: [
      for (var i = 0; i < _steps.length; i++) ...[
        Column(children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(shape: BoxShape.circle, color: i <= at ? _colorOf(_steps[at]) : track.withValues(alpha: .5)),
            child: Icon(_icons[_steps[i]], size: 14, color: i <= at ? Colors.white : Brand.muted),
          ),
          const SizedBox(height: 4),
          Text(_labels[_steps[i]]!, style: TextStyle(fontSize: 10.5, color: i <= at ? null : Brand.muted, fontWeight: i == at ? FontWeight.w800 : FontWeight.w500)),
        ]),
        if (i < _steps.length - 1)
          Expanded(
            child: Container(
              height: 3,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(color: i < at ? _colorOf(_steps[at]) : track.withValues(alpha: .5), borderRadius: BorderRadius.circular(2)),
            ),
          ),
      ],
    ]);
  }
}

Future<void> _openOrder(BuildContext context, Map<String, dynamic> o, bool seller, ValueChanged<Map<String, dynamic>> onChanged) async {
  final status = '${o['status']}';
  final open = status != 'delivered' && status != 'cancelled';
  final at = _steps.indexOf(status);
  final next = open && at >= 0 && at < _steps.length - 1 ? _steps[at + 1] : null;
  final canCancel = open && (seller || status == 'received');
  final history = [for (final h in (o['history'] as List? ?? const [])) Map<String, dynamic>.from(h as Map)];
  final coins = (o['coins'] as num?)?.toInt() ?? 0;

  Future<void> setStatus(BuildContext ctx, String to) async {
    if (to == 'cancelled') {
      final ok = await confirm(ctx, 'Cancel order #${o['id']}?',
          coins > 0 ? '${fmtCoins(coins)} coins go back to the customer.' : 'The other side is told in your chat.',
          ok: 'Cancel order', danger: true);
      if (!ok || !ctx.mounted) return;
    }
    try {
      final r = Map<String, dynamic>.from(await ctx.read<AppServices>().api.post('/catalog/orders/${o['id']}/status', {'status': to}) as Map);
      onChanged(Map<String, dynamic>.from(r['order'] as Map)..remove('buyer')..remove('seller'));
      if (ctx.mounted) Navigator.pop(ctx);
    } catch (e) {
      if (ctx.mounted) showError(ctx, e);
    }
  }

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Order #${o['id']}', style: const TextStyle(color: Brand.muted, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('${o['title']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          if ((o['note'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Note: ${o['note']}', style: const TextStyle(fontSize: 14.5)),
          ],
          const SizedBox(height: 16),
          for (final h in history)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                Icon(_icons[h['status']] ?? Icons.circle, size: 20, color: _colorOf('${h['status']}')),
                const SizedBox(width: 10),
                Expanded(child: Text(_labels[h['status']] ?? '${h['status']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                Text(_when(h['at'] as String?), style: const TextStyle(color: Brand.muted, fontSize: 12.5)),
              ]),
            ),
          const SizedBox(height: 8),
          if (seller && next != null)
            FilledButton.icon(
              onPressed: () => setStatus(ctx, next),
              icon: Icon(_icons[next], size: 19),
              label: Text('Mark as ${_labels[next]!.toLowerCase()}'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: const StadiumBorder()),
            ),
          if (o['chat_id'] != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                final id = (o['chat_id'] as num).toInt();
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: id, initial: context.read<ChatStore>().chatById(id))));
              },
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 19),
              label: const Text('Open chat'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: const StadiumBorder()),
            ),
          ],
          if (canCancel)
            TextButton(
              onPressed: () => setStatus(ctx, 'cancelled'),
              style: TextButton.styleFrom(foregroundColor: Brand.rose),
              child: const Text('Cancel order'),
            ),
        ]),
      ),
    ),
  );
}

String _when(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  if (d == null) return '';
  final hh = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${_day(iso)}, $hh:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}
