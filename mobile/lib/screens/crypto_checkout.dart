import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../core/api_client.dart';
import '../core/services.dart';
import '../core/socket_service.dart';
import '../state/auth_state.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import 'wallet_screen.dart' show walletSendForChat;

/// Paying Hushavia (Plus, coins) with USDT from the person's own wallet.
///
/// The transaction id is written to the phone the moment the network accepts it, so a payment is
/// never lost if the app closes before the server hears about it ([resumeWalletPayment] sends it later).
String _pendingKey(BuildContext context) => 'plus_crypto_pending_${context.read<AuthState>().me?.id ?? 0}';

/// Tells the server which transaction paid the order. True when it no longer needs to be retried.
Future<bool> _submitTx(ApiClient api, String key, int orderId, String tx) async {
  try {
    await api.post('/payments/orders/$orderId/crypto', {'tx': tx});
  } on ApiException catch (e) {
    if (e.isNetwork || e.status >= 500 || e.status == 429) return false; // try again later
  } catch (_) {
    return false;
  }
  (await SharedPreferences.getInstance()).remove(key);
  return true;
}

/// A payment that was sent but not reported yet (the app was closed, no internet…). True when it got paid.
Future<bool> resumeWalletPayment(BuildContext context) async {
  try {
    final key = _pendingKey(context);
    final api = context.read<AppServices>().api;
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return false;
    final j = jsonDecode(raw) as Map;
    final orderId = (j['order'] as num).toInt();
    if (!await _submitTx(api, key, orderId, '${j['tx']}') || !context.mounted) return false;
    return await _wait(context, orderId);
  } catch (_) {
    return false;
  }
}

Future<bool> _wait(BuildContext context, int orderId) async =>
    await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => _WaitForNetwork(orderId: orderId)) == true;

/// [body]: what is bought — {'plan_id': 3} or {'coin_pack_id': 2}. [networks]: "crypto_networks" from the server.
/// Returns true when the payment was confirmed while the person waited.
Future<bool> payWithWallet(BuildContext context, {required Map<String, dynamic> body, required List networks, required String what}) async {
  final nets = [for (final n in networks) Map<String, dynamic>.from(n as Map)];
  if (nets.isEmpty) return false;
  final net = nets.length == 1
      ? nets.first
      : await showModalBottomSheet<Map<String, dynamic>>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 2),
                child: Align(alignment: Alignment.centerLeft, child: Text('Pay with USDT on…', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(alignment: Alignment.centerLeft, child: Text('Choose the network where your USDT is.', style: TextStyle(color: Brand.muted))),
              ),
              for (final n in nets)
                ListTile(
                  leading: const CircleAvatar(backgroundColor: Color(0xFF26A17B), child: Text('₮', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900))),
                  title: Text('${n['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${n['fee_hint'] ?? ''}'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pop(ctx, n),
                ),
              const SizedBox(height: 8),
            ]),
          ),
        );
  if (net == null || !context.mounted) return false;
  final api = context.read<AppServices>().api;
  final key = _pendingKey(context);
  try {
    final r = Map<String, dynamic>.from(await api.post('/payments/checkout', {...body, 'provider': 'crypto', 'network': net['id']}) as Map);
    final orderId = ((r['order'] as Map)['id'] as num).toInt();
    final c = Map<String, dynamic>.from(r['crypto'] as Map);
    if (!context.mounted) return false;
    String? sent;
    final card = await walletSendForChat(
      context,
      peerName: '${AppConfig.appName} $what',
      locked: true,
      request: {'network': c['network'], 'symbol': c['symbol'], 'amount': c['amount'], 'decimals': c['decimals'], 'to': c['to'], 'contract': c['contract']},
      onSent: (tx) async {
        sent = tx;
        await (await SharedPreferences.getInstance()).setString(key, jsonEncode({'order': orderId, 'tx': tx}));
      },
    );
    final tx = sent ?? (card == null ? null : '${card['tx']}');
    if (tx == null) {
      // nothing was sent: drop the order
      try {
        await api.post('/payments/orders/$orderId/cancel', {});
      } catch (_) {}
      return false;
    }
    if (!await _submitTx(api, key, orderId, tx)) {
      if (context.mounted) showInfo(context, 'Your payment was sent. We’ll confirm it as soon as you’re back online — open this page again.');
      return false;
    }
    if (!context.mounted) return false;
    return await _wait(context, orderId);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// Waits until the network confirmed the payment (socket event, or polling as a fallback).
class _WaitForNetwork extends StatefulWidget {
  const _WaitForNetwork({required this.orderId});
  final int orderId;

  @override
  State<_WaitForNetwork> createState() => _WaitForNetworkState();
}

class _WaitForNetworkState extends State<_WaitForNetwork> {
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
    final review = _status == 'review';
    return AlertDialog(
      title: Text(failed ? 'Payment not completed' : review ? 'We’re checking it' : 'Confirming…'),
      content: Row(children: [
        if (!failed && !review) const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        if (!failed && !review) const SizedBox(width: 16),
        Expanded(
          child: Text(failed
              ? 'The transaction failed on the network, so nothing was paid. You can try again.'
              : review
                  ? 'Your payment needs a look from our team. You’ll get a notification — nothing more to do.'
                  : 'Your payment was sent. The network is confirming it — usually about a minute. You can close this: it finishes by itself.'),
        ),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(failed || review ? 'OK' : 'Close'))],
    );
  }
}
