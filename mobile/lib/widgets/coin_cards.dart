import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/services.dart';
import '../core/socket_service.dart';
import '../models/models.dart';
import '../screens/coins_screen.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';

/// A gift of coins in a private chat.
class GiftCard extends StatelessWidget {
  const GiftCard({super.key, required this.message, required this.isMine});
  final Message message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final g = (message.meta?['gift'] as Map?) ?? const {};
    final note = '${g['note'] ?? ''}';
    return Container(
      width: 220,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFFFFB347), Color(0xFFFF6FA0), Color(0xFF8F72FF)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.6, end: 1),
          duration: const Duration(milliseconds: 700),
          curve: Curves.elasticOut,
          builder: (_, v, child) => Transform.scale(scale: v, child: child),
          child: Text('${g['emoji'] ?? '🎁'}', style: const TextStyle(fontSize: 62, height: 1.1)),
        ),
        const SizedBox(height: 6),
        Text('${g['name'] ?? 'Gift'}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const CoinIcon(size: 16),
            const SizedBox(width: 6),
            Text('${fmtCoins(((g['coins'] as num?) ?? 0).toInt())} coins', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          ]),
        ),
        if (note.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(note, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.3)),
        ],
        const SizedBox(height: 6),
        Text(isMine ? 'You sent a gift' : 'The coins are in your balance', style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12)),
      ]),
    );
  }
}

/// A giveaway in a channel or group: join, watch the time, see the winners.
class GiveawayCard extends StatefulWidget {
  const GiveawayCard({super.key, required this.message});
  final Message message;

  @override
  State<GiveawayCard> createState() => _GiveawayCardState();
}

class _GiveawayCardState extends State<GiveawayCard> {
  Map<String, dynamic>? _g;
  bool _busy = false;
  Timer? _tick;
  StreamSubscription<SocketEvent>? _sub;

  Map get _meta => (widget.message.meta?['giveaway'] as Map?) ?? const {};
  int get _id => ((_meta['id'] as num?) ?? 0).toInt();

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      // the draw happens on the server a few seconds after the time is up
      if (_g?['status'] == 'open' && _left.inSeconds < -4 && _left.inSeconds % 8 == 0) _load();
    });
    _sub = context.read<AppServices>().socket.events.where((e) => e.name == 'giveaway:done' && '${e.data['giveaway_id']}' == '$_id').listen((_) => _load());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Duration get _left {
    final end = DateTime.tryParse('${_g?['ends_at'] ?? _meta['ends_at'] ?? ''}');
    return end == null ? Duration.zero : end.difference(DateTime.now());
  }

  Future<void> _load() async {
    if (_id == 0 || widget.message.isLocal) return;
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/coins/giveaways/$_id') as Map);
      if (mounted) setState(() => _g = r);
    } catch (_) {}
  }

  Future<void> _join() async {
    setState(() => _busy = true);
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.post('/coins/giveaways/$_id/join', {}) as Map);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _g = r);
      showInfo(context, 'You’re in! Winners are picked when the time is up 🍀');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _clock(Duration d) {
    if (d.inSeconds <= 0) return 'Picking winners…';
    if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h left';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)} left';
  }

  @override
  Widget build(BuildContext context) {
    final each = ((_meta['coins_each'] as num?) ?? 0).toInt();
    final winners = ((_meta['winners'] as num?) ?? 1).toInt();
    final g = _g;
    final done = g?['status'] == 'done';
    final joined = g?['joined'] == true;
    final mine = g?['mine'] == true || widget.message.senderId == context.read<ChatStore>().myId;
    final list = [for (final w in (g?['winner_list'] as List? ?? const [])) w as Map];
    return Container(
      width: 250,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF2B2350), Color(0xFF4A2FD8), Color(0xFF7C5CFF)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Text('🎉', style: TextStyle(fontSize: 26)),
          const SizedBox(width: 8),
          const Expanded(child: Text('Giveaway', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18))),
          if (g != null) Text('${g['entries']} joined', style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
        ]),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const CoinIcon(size: 30),
          const SizedBox(width: 8),
          Text(fmtCoins(each), style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
        ]),
        Text(winners == 1 ? 'for 1 winner' : 'each, for $winners winners', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 12),
        if (done) ...[
          Text(list.isEmpty ? 'Finished — nobody joined' : (list.length == 1 ? 'Winner' : 'Winners'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          for (final w in list.take(10))
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('🏆 ${'${w['name']}'.isEmpty ? '@${w['username']}' : w['name']}', textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
            ),
          if (list.length > 10) Text('and ${list.length - 10} more', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
        ] else ...[
          Text(_clock(_left), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(height: 10),
          if (mine)
            const Text('Your giveaway', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70))
          else
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: joined ? Colors.white24 : Colors.white, foregroundColor: joined ? Colors.white : Brand.primaryDeep, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              onPressed: joined || _busy || g == null || _left.inSeconds <= 0 ? null : _join,
              child: Text(joined ? 'You’re in ✓' : 'Join', style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
        ],
      ]),
    );
  }
}

/// Pick a gift for the person in this private chat. Returns true when it was sent.
Future<bool> sendGiftFlow(BuildContext context, int chatId, String peerName) async {
  final api = context.read<AppServices>().api;
  List gifts;
  int balance;
  try {
    gifts = await api.get('/coins/gifts') as List;
    balance = (((await api.get('/coins') as Map)['balance'] as num?) ?? 0).toInt();
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  if (!context.mounted) return false;
  final note = TextEditingController();
  final pick = await showModalBottomSheet<Map>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('A gift for $peerName', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
              const CoinIcon(size: 16),
              const SizedBox(width: 5),
              Text(fmtCoins(balance), style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 2),
            const Text('They receive the coins of the gift.', style: TextStyle(color: Brand.muted, fontSize: 13)),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.95,
              children: [
                for (final raw in gifts)
                  Builder(builder: (_) {
                    final g = raw as Map;
                    final can = balance >= (g['coins'] as num);
                    return Opacity(
                      opacity: can ? 1 : 0.45,
                      child: Material(
                        color: Theme.of(ctx).brightness == Brightness.dark ? const Color(0xFF1A1E33) : const Color(0xFFF3F1FF),
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => Navigator.pop(ctx, g),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text('${g['emoji']}', style: const TextStyle(fontSize: 36)),
                            const SizedBox(height: 2),
                            Text('${g['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 3),
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              const CoinIcon(size: 13),
                              const SizedBox(width: 4),
                              Text(fmtCoins((g['coins'] as num).toInt()), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                            ]),
                          ]),
                        ),
                      ),
                    );
                  }),
              ],
            ),
            const SizedBox(height: 10),
            TextField(controller: note, maxLength: 120, decoration: const InputDecoration(hintText: 'Add a message (optional)', counterText: '')),
          ]),
        ),
      ),
    ),
  );
  if (pick == null || !context.mounted) return false;
  final price = (pick['coins'] as num).toInt();
  if (balance < price) {
    final go = await confirm(context, 'Not enough coins', '${pick['name']} costs ${fmtCoins(price)} coins and you have ${fmtCoins(balance)}. Get more coins?', ok: 'Get coins');
    if (go && context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const CoinsScreen()));
    return false;
  }
  try {
    await api.post('/coins/gift', {'chat_id': chatId, 'gift_id': pick['id'], if (note.text.trim().isNotEmpty) 'note': note.text.trim()});
    HapticFeedback.heavyImpact();
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// Coins for a channel post.
Future<void> tipFlow(BuildContext context, Message m) async {
  final api = context.read<AppServices>().api;
  final custom = TextEditingController();
  final amount = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Tip this post', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            const Text('Your coins go to the channel — a thank-you for good posts.', style: TextStyle(color: Brand.muted, fontSize: 13)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final a in const [10, 50, 100, 500])
                ActionChip(avatar: const CoinIcon(size: 16), label: Text(fmtCoins(a), style: const TextStyle(fontWeight: FontWeight.w800)), onPressed: () => Navigator.pop(ctx, a)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: custom,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                  decoration: const InputDecoration(hintText: 'Another amount'),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(custom.text) ?? 0), child: const Text('Tip')),
            ]),
          ]),
        ),
      ),
    ),
  );
  if (amount == null || amount < 1 || !context.mounted) return;
  try {
    final r = await api.post('/coins/tip', {'message_id': m.id, 'amount': amount}) as Map;
    m.tips = ((r['tips'] as num?) ?? m.tips).toInt();
    if (!context.mounted) return;
    HapticFeedback.mediumImpact();
    showInfo(context, '${fmtCoins(amount)} coins tipped 🪙');
  } on ApiException catch (e) {
    if (!context.mounted) return;
    if (e.code == 'not_enough_coins') {
      final go = await confirm(context, 'Not enough coins', 'Get more coins to tip this post?', ok: 'Get coins');
      if (go && context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const CoinsScreen()));
    } else {
      showError(context, e);
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Start a giveaway in this channel or group. Returns true when it was posted.
Future<bool> giveawayFlow(BuildContext context, int chatId) async {
  final each = TextEditingController(text: '100');
  final winners = TextEditingController(text: '3');
  var hours = 24.0;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final e = int.tryParse(each.text) ?? 0;
        final w = int.tryParse(winners.text) ?? 0;
        return AlertDialog(
          title: const Text('New giveaway'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: each,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                onChanged: (_) => set(() {}),
                decoration: const InputDecoration(labelText: 'Coins for each winner', prefixIcon: Padding(padding: EdgeInsets.all(12), child: CoinIcon(size: 20))),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: winners,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                onChanged: (_) => set(() {}),
                decoration: const InputDecoration(labelText: 'Number of winners (1–100)'),
              ),
              const SizedBox(height: 14),
              const Text('Ends in', style: TextStyle(color: Brand.muted, fontSize: 13)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                for (final (h, label) in const [(1.0, '1 hour'), (6.0, '6 hours'), (24.0, '1 day'), (72.0, '3 days'), (168.0, '7 days')])
                  ChoiceChip(label: Text(label), selected: hours == h, onSelected: (_) => set(() => hours = h)),
              ]),
              const SizedBox(height: 14),
              Text('${fmtCoins(e * w)} coins are taken from your balance now and held until the draw. Coins for prizes nobody wins come back to you.',
                  style: const TextStyle(color: Brand.muted, fontSize: 12.5, height: 1.35)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: e >= 1 && w >= 1 && w <= 100 ? () => Navigator.pop(ctx, true) : null, child: const Text('Start')),
          ],
        );
      },
    ),
  );
  if (go != true || !context.mounted) return false;
  try {
    await context.read<AppServices>().api.post('/coins/giveaways', {'chat_id': chatId, 'coins_each': int.parse(each.text), 'winners': int.parse(winners.text), 'hours': hours});
    HapticFeedback.heavyImpact();
    return true;
  } on ApiException catch (e) {
    if (!context.mounted) return false;
    if (e.code == 'not_enough_coins') {
      final more = await confirm(context, 'Not enough coins', 'You need ${fmtCoins(int.parse(each.text) * int.parse(winners.text))} coins for this giveaway. Get more coins?', ok: 'Get coins');
      if (more && context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const CoinsScreen()));
    } else {
      showError(context, e);
    }
    return false;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// Joining a channel that may be paid: [join] is tried first; when the server answers
/// "subscription_required" the person is asked, pays with coins and gets in.
/// Returns the chat id that was joined by paying, or null when [join] itself did the job / nothing happened.
Future<int?> subscribeIfNeeded(BuildContext context, ApiException e, {String? invite}) async {
  if (e.code != 'subscription_required') return null;
  final price = ((e.extra['price'] as num?) ?? 0).toInt();
  final chatId = ((e.extra['chat_id'] as num?) ?? 0).toInt();
  final ok = await confirm(context, '${e.extra['title'] ?? 'This channel'} is a paid channel',
      'Joining costs ${fmtCoins(price)} coins for ${e.extra['days'] ?? 30} days. It renews from your balance; leave the channel to stop.', ok: 'Pay ${fmtCoins(price)} coins');
  if (!ok || !context.mounted) return null;
  try {
    await context.read<AppServices>().api.post('/chats/$chatId/subscribe', {if (invite != null) 'invite': invite});
    HapticFeedback.heavyImpact();
    return chatId;
  } on ApiException catch (e2) {
    if (!context.mounted) return null;
    if (e2.code == 'not_enough_coins') {
      final more = await confirm(context, 'Not enough coins', 'You need ${fmtCoins(price)} coins to join. Get more coins?', ok: 'Get coins');
      if (more && context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const CoinsScreen()));
    } else {
      showError(context, e2);
    }
    return null;
  } catch (e2) {
    if (context.mounted) showError(context, e2);
    return null;
  }
}
