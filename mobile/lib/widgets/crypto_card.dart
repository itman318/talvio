import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../screens/wallet_screen.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../theme/chat_theme.dart';
import '../wallet/evm.dart';
import '../wallet/tron_crypto.dart';
import '../wallet/utxo.dart';
import '../wallet/verify.dart';
import '../wallet/wallet_store.dart';

/// "Sent 5 USDT" / "Asks for 10 USDT" inside a chat. A sent card is CHECKED on the network
/// (it only says Confirmed when that transfer really happened); a request can be paid in one tap.
class CryptoCard extends StatefulWidget {
  const CryptoCard({super.key, required this.message, required this.isMine, required this.chat});
  final Message message;
  final bool isMine;
  final Chat chat;

  @override
  State<CryptoCard> createState() => _CryptoCardState();
}

class _CryptoCardState extends State<CryptoCard> {
  CardCheck _check = CardCheck.checking;
  static final Map<int, (String?, String?)> _mine = {}; // my wallet addresses, per account
  static final Map<int, Set<String>> _utxoMine = {};

  Map<String, dynamic> get c => Map<String, dynamic>.from((widget.message.meta?['crypto'] as Map?) ?? const {});

  @override
  void initState() {
    super.initState();
    if (c['kind'] == 'sent' || _paidTx != null) _verify();
    _loadMine();
  }

  /// a request / invoice that was paid from this chat (the server links the reply that paid it)
  String? get _paidTx => c['kind'] == 'request' && (c['paid_tx'] ?? '').toString().isNotEmpty ? '${c['paid_tx']}' : null;
  Map<String, dynamic>? get _inv => c['invoice'] is Map ? Map<String, dynamic>.from(c['invoice'] as Map) : null;

  @override
  void didUpdateWidget(covariant CryptoCard old) {
    super.didUpdateWidget(old);
    final was = (old.message.meta?['crypto'] as Map?)?['paid_tx'];
    if (was == null && _paidTx != null) {
      _check = CardCheck.checking;
      _verify();
    }
  }

  Future<void> _loadMine() async {
    final uid = context.read<AuthState>().me?.id ?? 0;
    if (_mine.containsKey(uid)) return;
    final w = WalletStore(uid);
    await w.load();
    _mine[uid] = (w.address, w.evmAddress);
    _utxoMine[uid] = {...w.utxoAddr.values.map((x) => x.toLowerCase()), if (w.solAddress != null) w.solAddress!.toLowerCase()};
    if (mounted) setState(() {});
  }

  Future<void> _verify() async {
    if (widget.message.isLocal) return;
    final r = await CryptoVerify.check(_paidTx != null ? {...c, 'tx': _paidTx} : c);
    if (!mounted) return;
    setState(() => _check = r);
    if (r == CardCheck.pending) {
      await Future<void>.delayed(const Duration(seconds: 20));
      if (mounted) _verify();
    }
  }

  bool get _toMe {
    final m = _mine[context.read<AuthState>().me?.id ?? 0];
    final to = '${c['to']}'.toLowerCase();
    return m != null && (m.$1?.toLowerCase() == to || m.$2?.toLowerCase() == to || (_utxoMine[context.read<AuthState>().me?.id ?? 0]?.contains(to) ?? false));
  }

  String get _network => '${c['network']}' == 'tron'
      ? 'TRON'
      : '${c['network']}' == 'sol'
      ? 'Solana'
      : (UtxoChain.byId('${c['network']}')?.name ?? EvmChain.byId('${c['network']}')?.name ?? '${c['network']}');

  String get _amount {
    final u = BigInt.tryParse('${c['amount']}') ?? BigInt.zero;
    return Units.format(u, decimals: (c['decimals'] as num?)?.toInt() ?? 6, maxFraction: 6);
  }

  String? get _explorer {
    final tx = c['tx'] ?? _paidTx;
    if (tx == null) return null;
    if ('${c['network']}' == 'tron') return 'https://tronscan.org/#/transaction/$tx';
    final u = UtxoChain.byId('${c['network']}');
    if (u != null) return u.txUrl('$tx');
    if ('${c['network']}' == 'sol') return 'https://solscan.io/tx/$tx';
    final ch = EvmChain.byId('${c['network']}');
    return ch == null ? null : '${ch.explorer}/tx/$tx';
  }

  Future<void> _pay() async {
    final store = context.read<ChatStore>();
    final result = await walletSendForChat(context, request: c, peerName: widget.message.sender?.firstName);
    if (result == null || !mounted) return;
    await store.sendSpecial(widget.chat.id, 'crypto', {'crypto': result}, meta: {'crypto': result}, replyTo: widget.message);
  }

  @override
  Widget build(BuildContext context) {
    final sent = c['kind'] == 'sent';
    final inv = _inv;
    final paid = _paidTx != null;
    final onDark = widget.isMine && !softMineOf(context); // my bubbles are dark, unless a light chat theme is on
    final fg = onDark ? Colors.white : Theme.of(context).colorScheme.onSurface;
    final sub = onDark ? Colors.white70 : Brand.muted;
    final (icon, label, color) = switch (_check) {
      CardCheck.confirmed when paid => (Icons.verified_rounded, 'Paid · confirmed on the network', const Color(0xFF12B89C)),
      CardCheck.pending when paid => (Icons.schedule_rounded, 'Paid · waiting for the network…', const Color(0xFFE0A43A)),
      CardCheck.confirmed => (Icons.verified_rounded, 'Confirmed on the network', const Color(0xFF12B89C)),
      CardCheck.pending => (Icons.schedule_rounded, 'Waiting for the network…', const Color(0xFFE0A43A)),
      CardCheck.failed => (Icons.cancel_rounded, 'This transfer failed', const Color(0xFFE5484D)),
      CardCheck.mismatch => (Icons.gpp_bad_rounded, 'Not confirmed — don’t trust this card', const Color(0xFFE5484D)),
      CardCheck.checking => (Icons.sync_rounded, 'Checking on the network…', sub),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 260),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: sent ? const [Color(0xFF3FD8C0), Color(0xFF12B89C)] : const [Color(0xFF9A82FF), Color(0xFF6D4AFF)]),
            ),
            child: Icon(sent ? Icons.north_east_rounded : (inv != null ? Icons.receipt_long_rounded : Icons.request_page_rounded), color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              sent
                  ? (_toMe ? 'Sent to you' : (widget.isMine ? 'You sent' : 'Sent'))
                  : inv != null
                  ? 'Invoice${inv['number'] != null ? ' · ${inv['number']}' : ''}'
                  : (widget.isMine ? 'You asked for' : 'Payment request'),
              style: TextStyle(color: sub, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          if (paid)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFF12B89C).withValues(alpha: .16), borderRadius: BorderRadius.circular(20)),
              child: const Text('PAID', style: TextStyle(color: Color(0xFF12B89C), fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: .6)),
            ),
        ]),
        if (inv != null) ...[
          const SizedBox(height: 10),
          Text('${inv['title'] ?? ''}', style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w700)),
          for (final l in (inv['lines'] as List? ?? const []))
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('•  ', style: TextStyle(color: sub)),
                Expanded(child: Text('$l', style: TextStyle(color: fg.withValues(alpha: .85), fontSize: 13.5))),
              ]),
            ),
          const SizedBox(height: 8),
          Divider(height: 1, color: sub.withValues(alpha: .3)),
          const SizedBox(height: 6),
          Text('Total', style: TextStyle(color: sub, fontSize: 12)),
        ] else
          const SizedBox(height: 8),
        Text('$_amount ${c['symbol']}', style: TextStyle(color: fg, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        Text('on $_network · to ${_short('${c['to']}')}', style: TextStyle(color: sub, fontSize: 12.5)),
        if ((c['note'] ?? '').toString().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('${c['note']}', style: TextStyle(color: fg, fontSize: 14.5)),
        ],
        const SizedBox(height: 10),
        if (sent || paid)
          InkWell(
            onTap: _explorer == null ? null : () => launchUrl(Uri.parse(_explorer!), mode: LaunchMode.externalApplication),
            child: Row(children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12.5))),
              Icon(Icons.open_in_new_rounded, size: 14, color: sub),
            ]),
          )
        else if (widget.isMine)
          Text(inv != null ? 'Not paid yet' : 'Waiting for payment', style: TextStyle(color: sub, fontSize: 12.5, fontStyle: FontStyle.italic))
        else
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(42)),
              onPressed: _pay,
              icon: const Icon(Icons.arrow_upward_rounded, size: 18),
              label: Text(inv != null ? 'Pay invoice' : 'Pay $_amount ${c['symbol']}'),
            ),
          ),
      ]),
    );
  }

  static String _short(String a) => a.length > 14 ? '${a.substring(0, 6)}…${a.substring(a.length - 4)}' : a;
}

/// Text for chat lists and replies.
String cryptoLabel(Map<String, dynamic>? meta) {
  final c = meta?['crypto'];
  if (c is! Map) return '💸 Crypto';
  final u = BigInt.tryParse('${c['amount']}') ?? BigInt.zero;
  final amt = Units.format(u, decimals: (c['decimals'] as num?)?.toInt() ?? 6, maxFraction: 6);
  if (c['kind'] == 'request' && c['invoice'] is Map) return '🧾 Invoice: $amt ${c['symbol']}${c['paid_tx'] != null ? ' · paid' : ''}';
  return c['kind'] == 'request' ? '💸 Request: $amt ${c['symbol']}' : '💸 Sent $amt ${c['symbol']}';
}

