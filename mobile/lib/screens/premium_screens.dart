import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../core/services.dart';
import '../core/socket_service.dart';
import '../state/auth_state.dart';
import '../utils/format.dart';
import '../theme/brand.dart';
import '../widgets/mascot.dart';

const premiumColor = Brand.premium;

String _date(String? iso) {
  if (iso == null) return '';
  final d = DateTime.parse(iso).toLocal();
  return '${d.day}/${d.month}/${d.year}';
}

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  Map<String, dynamic>? _info;
  int? _planId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/premium') as Map);
      if (!mounted) return;
      setState(() {
        _info = r;
        final plans = (r['plans'] as List);
        _planId ??= plans.isEmpty ? null : ((plans.last as Map)['id'] as num).toInt();
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _pay(String provider) async {
    final planId = _planId;
    if (planId == null) return;
    setState(() => _busy = true);
    final services = context.read<AppServices>();
    try {
      final r = Map<String, dynamic>.from(await services.api.post('/payments/checkout', {'plan_id': planId, 'provider': provider}) as Map);
      final order = Map<String, dynamic>.from(r['order'] as Map);
      if (!mounted) return;
      if (provider == 'manual') {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ManualPaymentScreen(order: order, instructions: '${r['instructions'] ?? ''}')),
        );
      } else {
        await launchUrl(Uri.parse('${r['pay_url']}'), mode: LaunchMode.externalApplication);
        if (!mounted) return;
        final paid = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _WaitForPayment(orderId: (order['id'] as num).toInt()),
        );
        if (paid == true && mounted) {
          await context.read<AuthState>().refreshMe();
          if (mounted) showInfo(context, 'Talvio Plus is active ⭐');
        }
      }
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static const _perkIcons = {
    'badge': Icons.star_rounded,
    'uploads': Icons.cloud_upload_rounded,
    'folders': Icons.folder_special_rounded,
    'no_ads': Icons.block_rounded,
    'stickers': Icons.emoji_emotions_rounded,
    'themes': Icons.palette_rounded,
    'pins': Icons.push_pin_rounded,
    'accounts': Icons.switch_account_rounded,
    'bio': Icons.notes_rounded,
    'ring': Icons.blur_circular_rounded,
  };
  static const _perkColors = [Brand.amber, Brand.sky, Brand.violet, Color(0xFFE5484D), Brand.rose, Brand.primary, Brand.green, Color(0xFF3C83DE), Color(0xFF0FA3A3), Color(0xFFE07A2E)];

  String _price(Map<String, dynamic> plan) => '${plan['price_text'] ?? 'Rs ${plan['price_pkr']}'}';
  String _perMonth(Map<String, dynamic> plan) => '${plan['per_month_text'] ?? 'Rs ${plan['per_month_pkr']}'}';

  /// "Save 25%" on longer plans, compared with the 1-month price.
  int? _saving(List plans, Map<String, dynamic> plan) {
    Map? monthly;
    for (final p in plans) {
      if ((p as Map)['months'] == 1) monthly = p;
    }
    if (monthly == null || plan['months'] == 1) return null;
    final base = ((monthly['price'] ?? monthly['price_pkr']) as num).toDouble();
    final total = ((plan['price'] ?? plan['price_pkr']) as num).toDouble();
    final months = (plan['months'] as num).toInt();
    if (base <= 0) return null;
    final pct = ((1 - total / (base * months)) * 100).round();
    return pct >= 5 ? pct : null;
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Talvio Plus'),
        actions: [
          IconButton(
            tooltip: 'Payment history',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PaymentHistoryScreen())),
          ),
        ],
      ),
      body: info == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
              Container(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFFFFB347), Color(0xFFFF5E8A), Color(0xFF8E54E9)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [BoxShadow(color: const Color(0xFFFF5E8A).withValues(alpha: 0.3), blurRadius: 24, offset: const Offset(0, 10))],
                ),
                child: Column(children: [
                  const TaviMascot(pose: TaviPose.celebrate, size: 120),
                  const SizedBox(height: 6),
                  Text('${AppConfig.appName} Plus', style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
                  const SizedBox(height: 4),
                  Text(
                    info['is_premium'] == true
                        ? 'Active until ${_date(info['premium_until'] as String?)} — thank you! ⭐'
                        : 'More space, more style, no ads — and you support an independent app.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.35),
                  ),
                ]),
              ),
              const SizedBox(height: 18),
              Row(children: [
                Text(info['is_premium'] == true ? 'Extend your plan' : 'Choose a plan', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                const Spacer(),
                if (info['currency'] != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: premiumColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                    child: Text('Prices in ${info['currency']}', style: const TextStyle(color: premiumColor, fontWeight: FontWeight.w700, fontSize: 12)),
                  ),
              ]),
              const SizedBox(height: 10),
              ...(info['plans'] as List).map((p) {
                final plan = Map<String, dynamic>.from(p as Map);
                final id = (plan['id'] as num).toInt();
                final selected = id == _planId;
                final save = _saving(info['plans'] as List, plan);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => setState(() => _planId = id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
                      decoration: BoxDecoration(
                        color: dark ? const Color(0xFF1A1E33) : Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: selected ? premiumColor : (dark ? Colors.white12 : const Color(0xFFE3E6EF)), width: selected ? 2 : 1),
                      ),
                      child: Row(children: [
                        Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: selected ? premiumColor : Brand.muted),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Text('${plan['name']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                              if (save != null) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(color: Brand.green, borderRadius: BorderRadius.circular(8)),
                                  child: Text('Save $save%', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                                ),
                              ],
                            ]),
                            const SizedBox(height: 2),
                            Text('${_perMonth(plan)} / month', style: const TextStyle(color: Brand.muted, fontSize: 13)),
                          ]),
                        ),
                        Text(_price(plan), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                      ]),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 6),
              if (info['payments_note'] != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(color: Brand.amber.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                  child: Row(children: [
                    const Icon(Icons.info_outline_rounded, color: Brand.amber),
                    const SizedBox(width: 10),
                    Expanded(child: Text('${info['payments_note']}', style: const TextStyle(fontSize: 13.5))),
                  ]),
                )
              else if ((info['methods'] as List).isEmpty)
                const Padding(padding: EdgeInsets.only(bottom: 10), child: Text('Payments are not available right now.', textAlign: TextAlign.center)),
              ...(info['methods'] as List).map((m) {
                final method = Map<String, dynamic>.from(m as Map);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: premiumColor, minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    onPressed: _busy || _planId == null ? null : () => _pay('${method['id']}'),
                    icon: const Icon(Icons.lock_rounded, size: 18),
                    label: Text('Pay with ${method['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                );
              }),
              const SizedBox(height: 14),
              const Text('What you get', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(color: dark ? const Color(0xFF1A1E33) : Colors.white, borderRadius: BorderRadius.circular(20)),
                child: Column(children: [
                  for (final (i, p) in (info['perks'] as List).indexed)
                    ListTile(
                      leading: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(color: _perkColors[i % _perkColors.length], borderRadius: BorderRadius.circular(11)),
                        child: Icon(_perkIcons['${(p as Map)['key']}'] ?? Icons.check_rounded, color: Colors.white, size: 21),
                      ),
                      title: Text('${p['title']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${p['text']}'),
                    ),
                ]),
              ),
            ]),
    );
  }
}

/// Waits for the gateway result (socket event, or polling as a fallback).
class _WaitForPayment extends StatefulWidget {
  const _WaitForPayment({required this.orderId});
  final int orderId;

  @override
  State<_WaitForPayment> createState() => _WaitForPaymentState();
}

class _WaitForPaymentState extends State<_WaitForPayment> {
  StreamSubscription<SocketEvent>? _sub;
  Timer? _poll;
  String _status = 'pending';

  @override
  void initState() {
    super.initState();
    final services = context.read<AppServices>();
    _sub = services.socket.events.where((e) => e.name == 'payment:updated' && '${e.data['order_id']}' == '${widget.orderId}').listen((e) => _set('${e.data['status']}'));
    _poll = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        final o = await services.api.get('/payments/orders/${widget.orderId}') as Map;
        _set('${o['status']}');
      } catch (_) {}
    });
  }

  void _set(String s) {
    if (!mounted || s == _status) return;
    setState(() => _status = s);
    if (s == 'paid') Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failed = ['failed', 'cancelled', 'rejected'].contains(_status);
    return AlertDialog(
      title: Text(failed ? 'Payment not completed' : _status == 'review' ? 'Confirming…' : 'Waiting for payment'),
      content: Row(children: [
        if (!failed) const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        if (!failed) const SizedBox(width: 16),
        Expanded(
          child: Text(failed
              ? 'The payment did not go through. You can try again.'
              : _status == 'review'
                  ? 'We received your payment details and are confirming them. Talvio Plus will start shortly.'
                  : 'Finish the payment in your browser, then come back here.'),
        ),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(failed || _status == 'review' ? 'OK' : 'Close'))],
    );
  }
}

/// Manual payment: send the money, then upload the screenshot + transaction id.
class ManualPaymentScreen extends StatefulWidget {
  const ManualPaymentScreen({super.key, required this.order, required this.instructions});
  final Map<String, dynamic> order;
  final String instructions;

  @override
  State<ManualPaymentScreen> createState() => _ManualPaymentScreenState();
}

class _ManualPaymentScreenState extends State<ManualPaymentScreen> {
  final _txn = TextEditingController();
  final _sender = TextEditingController();
  String? _shot;
  bool _busy = false;

  Future<void> _submit() async {
    if (_shot == null || _txn.text.trim().length < 4) {
      showInfo(context, 'Add the screenshot and the transaction ID');
      return;
    }
    setState(() => _busy = true);
    final api = context.read<AppServices>().api;
    try {
      final m = await api.upload(_shot!, kind: 'image');
      await api.post('/payments/orders/${widget.order['id']}/proof', {
        'media_id': m['id'],
        'txn_id': _txn.text.trim(),
        if (_sender.text.trim().isNotEmpty) 'sender': _sender.text.trim(),
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Sent for review'),
          content: const Text('Thanks! We will check your payment and turn on Talvio Plus — usually within a few hours.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    return Scaffold(
      appBar: AppBar(title: const Text('Manual payment')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text('Amount: ${o['amount_text'] ?? 'Rs ${o['amount_pkr']}'}', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Row(children: [
          Text('Reference: ${o['txn_ref']}'),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: '${o['txn_ref']}'));
              if (context.mounted) showInfo(context, 'Copied');
            },
          ),
        ]),
        const SizedBox(height: 8),
        Card(child: Padding(padding: const EdgeInsets.all(14), child: SelectableText(widget.instructions))),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          icon: Icon(_shot == null ? Icons.add_photo_alternate_outlined : Icons.check_circle, color: _shot == null ? null : Brand.accent),
          label: Text(_shot == null ? 'Add payment screenshot' : 'Screenshot added'),
          onPressed: () async {
            final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1600);
            if (x != null) setState(() => _shot = x.path);
          },
        ),
        const SizedBox(height: 12),
        TextField(controller: _txn, decoration: const InputDecoration(labelText: 'Transaction ID (TID)', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(
          controller: _sender,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Sent from (number / account) — optional', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: premiumColor, minimumSize: const Size.fromHeight(48)),
          onPressed: _busy ? null : _submit,
          child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Submit'),
        ),
      ]),
    );
  }
}

class PaymentHistoryScreen extends StatelessWidget {
  const PaymentHistoryScreen({super.key});

  static const _labels = {
    'pending': 'Waiting for payment',
    'review': 'Being checked',
    'paid': 'Paid',
    'failed': 'Failed',
    'cancelled': 'Cancelled',
    'rejected': 'Rejected',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment history')),
      body: FutureBuilder<dynamic>(
        future: context.read<AppServices>().api.get('/payments/orders'),
        builder: (ctx, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = (snap.data as List).map((x) => Map<String, dynamic>.from(x as Map)).toList();
          if (list.isEmpty) return const Center(child: Text('No payments yet'));
          return ListView(
            children: list.map((o) {
              final st = '${o['status']}';
              return ListTile(
                leading: Icon(
                  st == 'paid' ? Icons.check_circle : (['failed', 'rejected', 'cancelled'].contains(st) ? Icons.cancel : Icons.schedule),
                  color: st == 'paid' ? Brand.accent : (['failed', 'rejected'].contains(st) ? Colors.red : null),
                ),
                title: Text('${o['amount_text'] ?? 'Rs ${o['amount_pkr']}'} · ${o['months']} month${o['months'] == 1 ? '' : 's'}'),
                subtitle: Text([_labels[st] ?? st, '${o['provider']}', _date(o['created_at'] as String?), if (o['review_note'] != null) '${o['review_note']}'].join(' · ')),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}
