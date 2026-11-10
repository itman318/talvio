import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/screen_guard.dart';
import '../state/auth_state.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../wallet/tron_api.dart';
import '../wallet/tron_crypto.dart';
import '../wallet/wallet_store.dart';

// Wallet palette: deep night card, mint for "in", warm for "out". Values in US dollars.
const _mint = Color(0xFF12B89C);
const _out = Color(0xFFE5484D);
const _usdtColor = Color(0xFF26A17B);
const _trxColor = Color(0xFFEB0029);

final _usd = NumberFormat.currency(locale: 'en_US', symbol: r'$', decimalDigits: 2);
String usd(double v) => _usd.format(v);

String _short(String a) => a.length > 14 ? '${a.substring(0, 6)}…${a.substring(a.length - 6)}' : a;

/// Settings → Wallet. Your own TRON wallet (USDT & TRX): the keys stay on this phone.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  WalletStore? _store;

  @override
  void initState() {
    super.initState();
    final uid = context.read<AuthState>().me?.id ?? 0;
    _store = WalletStore(uid)..load();
  }

  @override
  void dispose() {
    _store?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _store!,
      child: Consumer<WalletStore>(
        builder: (_, w, __) {
          if (!w.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          return w.exists ? const _WalletHome() : const _Welcome();
        },
      ),
    );
  }
}

// ======================================================================== welcome
class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    final w = context.read<WalletStore>();
    Widget point(IconData i, String t, String s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: Brand.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Icon(i, color: Brand.primary, size: 21),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 2),
                Text(s, style: const TextStyle(color: Brand.muted, fontSize: 13.5, height: 1.35)),
              ]),
            ),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 6, 22, 24), children: [
          const _HeroCoin(),
          const SizedBox(height: 18),
          const Text('Your own crypto wallet', textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          const SizedBox(height: 6),
          const Text('Hold, send and receive USDT and TRX — right inside Hushavia.',
              textAlign: TextAlign.center, style: TextStyle(color: Brand.muted, fontSize: 15)),
          const SizedBox(height: 18),
          point(Icons.key_rounded, 'Only you hold the keys', 'Your 12-word recovery phrase stays on this phone. Hushavia never sees it and can’t move your money.'),
          point(Icons.fingerprint_rounded, 'Locked with your fingerprint', 'Every transfer is confirmed with your fingerprint or screen lock.'),
          point(Icons.bolt_rounded, 'USDT on TRON', 'Low fees, fast transfers, and the network most people use for USDT.'),
          const SizedBox(height: 18),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(54)),
            onPressed: () async {
              if (!await WalletStore.phoneIsLocked()) {
                if (context.mounted) showInfo(context, 'First set up a fingerprint or screen lock on this phone');
                return;
              }
              if (!context.mounted) return;
              Navigator.push(context, MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: _PhraseScreen(phrase: TronCrypto.newPhrase()))));
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('Create a new wallet'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(54)),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: const _ImportScreen()))),
            icon: const Icon(Icons.download_rounded),
            label: const Text('I already have a wallet'),
          ),
          const SizedBox(height: 16),
          const Text(
            'Crypto prices go up and down, and transfers can’t be reversed. Only send to people you trust.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Brand.faint, fontSize: 12, height: 1.4),
          ),
        ]),
      ),
    );
  }
}

/// A slowly turning coin with a soft glow (drawn, no image).
class _HeroCoin extends StatefulWidget {
  const _HeroCoin();
  @override
  State<_HeroCoin> createState() => _HeroCoinState();
}

class _HeroCoinState extends State<_HeroCoin> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 150,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            final t = _c.value * 2 * math.pi;
            final squash = 0.55 + 0.45 * math.cos(t).abs();
            return Stack(alignment: Alignment.center, children: [
              Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Brand.primary.withValues(alpha: 0.28), Colors.transparent])),
              ),
              Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(squash, 1, 1),
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(colors: [Color(0xFF9A82FF), Color(0xFF5232E0)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                    boxShadow: [BoxShadow(color: Brand.primary.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 10))],
                    border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 3),
                  ),
                  child: const Icon(Icons.account_balance_wallet_rounded, color: Colors.white, size: 44),
                ),
              ),
            ]);
          },
        ),
      );
}

// ======================================================================== recovery phrase
class _PhraseScreen extends StatefulWidget {
  const _PhraseScreen({required this.phrase, this.showOnly = false});
  final String phrase;
  final bool showOnly;

  @override
  State<_PhraseScreen> createState() => _PhraseScreenState();
}

class _PhraseScreenState extends State<_PhraseScreen> {
  bool _wrote = false;

  @override
  void initState() {
    super.initState();
    ScreenGuard.acquire(); // no screenshots of the phrase
  }

  @override
  void dispose() {
    ScreenGuard.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final words = widget.phrase.split(' ');
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery phrase')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
          const Text('Write these 12 words on paper, in this order. They are the only way to get your wallet back if you lose this phone.',
              style: TextStyle(fontSize: 15, height: 1.4)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: dark ? const Color(0xFF161A2D) : const Color(0xFFF1EEFF), borderRadius: BorderRadius.circular(20)),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 3.6,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (var i = 0; i < words.length; i += 1)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(12)),
                    child: Row(children: [
                      SizedBox(width: 24, child: Text('${i + 1}', style: const TextStyle(color: Brand.faint, fontWeight: FontWeight.w600))),
                      Text(words[i], style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
                    ]),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _Warn(lines: [
            'Never share these words. Anyone who has them can take all your money.',
            'Hushavia staff will never ask for them.',
            'Don’t keep them in a screenshot, chat or email.',
          ]),
          const SizedBox(height: 14),
          if (!widget.showOnly) ...[
            CheckboxListTile(
              value: _wrote,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('I wrote the words down and keep them safe'),
              onChanged: (v) => setState(() => _wrote = v == true),
            ),
            const SizedBox(height: 6),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(52)),
              onPressed: !_wrote
                  ? null
                  : () => Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: context.read<WalletStore>(), child: _VerifyScreen(phrase: widget.phrase))),
                      ),
              child: const Text('Continue'),
            ),
          ] else
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
        ]),
      ),
    );
  }
}

class _Warn extends StatelessWidget {
  const _Warn({required this.lines});
  final List<String> lines;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: const Color(0xFFE08A1E).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
        child: Column(children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.shield_rounded, size: 17, color: Color(0xFFE08A1E))),
                const SizedBox(width: 8),
                Expanded(child: Text(l, style: const TextStyle(fontSize: 13.5, height: 1.35))),
              ]),
            ),
        ]),
      );
}

/// Checks three words, so nobody skips writing the phrase down.
class _VerifyScreen extends StatefulWidget {
  const _VerifyScreen({required this.phrase});
  final String phrase;
  @override
  State<_VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<_VerifyScreen> {
  late final List<String> _words = widget.phrase.split(' ');
  late final List<int> _ask;
  late final Map<int, List<String>> _options;
  final Map<int, String> _picked = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    ScreenGuard.acquire();
    final r = math.Random.secure();
    final idx = List.generate(_words.length, (i) => i)..shuffle(r);
    _ask = idx.take(3).toList()..sort();
    _options = {
      for (final i in _ask)
        i: ([_words[i], ...(_words.where((w) => w != _words[i]).toList()..shuffle(r)).take(3)]..shuffle(r)),
    };
  }

  @override
  void dispose() {
    ScreenGuard.release();
    super.dispose();
  }

  bool get _allRight => _ask.every((i) => _picked[i] == _words[i]);

  Future<void> _finish() async {
    setState(() => _saving = true);
    try {
      await context.read<WalletStore>().save(widget.phrase);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.pop(context);
      showInfo(context, 'Your wallet is ready');
    } catch (e) {
      if (mounted) showError(context, e);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Check your words')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
          const Text('Tap the right word for each number.', style: TextStyle(fontSize: 15)),
          const SizedBox(height: 14),
          for (final i in _ask) ...[
            Text('Word #${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final w in _options[i]!)
                ChoiceChip(
                  label: Text(w),
                  selected: _picked[i] == w,
                  onSelected: (_) => setState(() => _picked[i] = w),
                ),
            ]),
            if (_picked[i] != null && _picked[i] != _words[i])
              const Padding(padding: EdgeInsets.only(top: 6), child: Text('Not this one — check your paper', style: TextStyle(color: _out, fontSize: 13))),
            const SizedBox(height: 16),
          ],
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(52)),
            onPressed: _allRight && !_saving ? _finish : null,
            child: _saving ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)) : const Text('Create my wallet'),
          ),
        ]),
      ),
    );
  }
}

class _ImportScreen extends StatefulWidget {
  const _ImportScreen();
  @override
  State<_ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<_ImportScreen> {
  final _text = TextEditingController();
  bool _saving = false;
  List<String> _suggest = const [];

  @override
  void initState() {
    super.initState();
    ScreenGuard.acquire();
    _text.addListener(() {
      final parts = _text.text.toLowerCase().split(RegExp(r'\s+'));
      final last = _text.text.endsWith(' ') ? '' : parts.last;
      final s = TronCrypto.suggest(last);
      if (s.join() != _suggest.join()) setState(() => _suggest = s);
      setState(() {});
    });
  }

  @override
  void dispose() {
    ScreenGuard.release();
    _text.dispose();
    super.dispose();
  }

  void _pick(String w) {
    final t = _text.text;
    final cut = t.lastIndexOf(RegExp(r'\s')) + 1;
    _text.text = '${t.substring(0, cut)}$w ';
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
  }

  Future<void> _go() async {
    if (!await WalletStore.phoneIsLocked()) {
      if (mounted) showInfo(context, 'First set up a fingerprint or screen lock on this phone');
      return;
    }
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      await context.read<WalletStore>().save(_text.text);
      if (!mounted) return;
      Navigator.pop(context);
      showInfo(context, 'Your wallet is back');
    } catch (e) {
      if (mounted) {
        showError(context, e);
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = TronCrypto.normalize(_text.text).split(' ').where((w) => w.isNotEmpty).length;
    final valid = TronCrypto.isValidPhrase(_text.text);
    return Scaffold(
      appBar: AppBar(title: const Text('Restore a wallet')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
          const Text('Type your 12 or 24 recovery words, with a space between them.', style: TextStyle(fontSize: 15)),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            minLines: 4,
            maxLines: 6,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(hintText: 'word1 word2 word3 …', counterText: '$n words', counterStyle: TextStyle(color: valid ? _mint : Brand.muted)),
          ),
          if (_suggest.isNotEmpty)
            Wrap(spacing: 8, children: [for (final w in _suggest) ActionChip(label: Text(w), onPressed: () => _pick(w))]),
          const SizedBox(height: 14),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(52)),
            onPressed: valid && !_saving ? _go : null,
            child: _saving ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)) : const Text('Restore'),
          ),
          if (n >= 12 && !valid)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('These words don’t make a valid phrase. Check the spelling and the order.', style: TextStyle(color: _out)),
            ),
        ]),
      ),
    );
  }
}

// ======================================================================== home
class _WalletHome extends StatefulWidget {
  const _WalletHome();
  @override
  State<_WalletHome> createState() => _WalletHomeState();
}

class _WalletHomeState extends State<_WalletHome> {
  WalletBalance? _bal;
  List<WalletTx>? _txs;
  Map<String, (double, double)> _px = const {};
  String? _error;
  bool _hidden = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final w = context.read<WalletStore>();
    try {
      final api = w.api;
      final results = await Future.wait([api.balance(w.address!), api.history(w.address!), Prices.current()]);
      if (!mounted) return;
      setState(() {
        _bal = results[0] as WalletBalance;
        _txs = results[1] as List<WalletTx>;
        _px = results[2] as Map<String, (double, double)>;
        _error = null;
      });
    } catch (e) {
      if (mounted && !quiet) setState(() => _error = e is WalletException ? e.message : 'Can’t reach the network. Pull to try again.');
    }
  }

  double get _usdtPx => _px['tether']?.$1 ?? 1.0;
  double get _trxPx => _px['tron']?.$1 ?? 0;
  double get _total => _bal == null ? 0 : Units.toDouble(_bal!.usdt) * _usdtPx + Units.toDouble(_bal!.trx) * _trxPx;

  void _menu() {
    final w = context.read<WalletStore>();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.key_rounded),
            title: const Text('Show recovery phrase'),
            onTap: () async {
              Navigator.pop(ctx);
              final p = await w.readPhrase(context, 'Show your recovery phrase');
              if (p == null || !mounted) return;
              Navigator.push(context, MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: _PhraseScreen(phrase: p, showOnly: true))));
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_rounded),
            title: const Text('Copy my address'),
            subtitle: Text(_short(w.address!)),
            onTap: () {
              Navigator.pop(ctx);
              Clipboard.setData(ClipboardData(text: w.address!));
              showInfo(context, 'Address copied');
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.science_rounded),
            title: const Text('Test network (Nile)'),
            subtitle: const Text('Free test coins, not real money'),
            value: w.net.isTest,
            onChanged: (v) async {
              Navigator.pop(ctx);
              await w.setNet(v ? TronNet.nile : TronNet.main);
              setState(() {
                _bal = null;
                _txs = null;
              });
              _load();
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: _out),
            title: const Text('Remove wallet from this phone', style: TextStyle(color: _out)),
            onTap: () async {
              Navigator.pop(ctx);
              final ok = await confirm(context, 'Remove the wallet?',
                  'Your money stays on the network, but without your 12 recovery words NOBODY can get it back — not even Hushavia. Make sure you have the words.',
                  ok: 'Remove', danger: true);
              if (!ok || !mounted) return;
              if (!await WalletStore.confirmOwner(context, 'Remove your wallet')) return;
              await w.remove();
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  void _openSend(String token) {
    final w = context.read<WalletStore>();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: _SendScreen(token: token, balance: _bal, prices: _px))),
    ).then((_) => _load(quiet: true));
  }

  @override
  Widget build(BuildContext context) {
    final w = context.watch<WalletStore>();
    final b = _bal;
    final change = _bal == null || _total == 0
        ? null
        : ((Units.toDouble(_bal!.trx) * _trxPx * (_px['tron']?.$2 ?? 0)) + (Units.toDouble(_bal!.usdt) * _usdtPx * (_px['tether']?.$2 ?? 0))) / _total;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet'),
        actions: [IconButton(onPressed: _menu, icon: const Icon(Icons.more_vert_rounded))],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.only(bottom: 28), children: [
          // ---- balance card
          Container(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: const LinearGradient(colors: [Color(0xFF1B1E3A), Color(0xFF2B1F63), Color(0xFF4A2FD8)], stops: [0, 0.55, 1], begin: Alignment.topLeft, end: Alignment.bottomRight),
              boxShadow: [BoxShadow(color: Brand.primary.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 10))],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('Total balance', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                InkWell(
                  onTap: () => setState(() => _hidden = !_hidden),
                  child: Icon(_hidden ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: Colors.white54, size: 18),
                ),
                const Spacer(),
                if (w.net.isTest)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(8)),
                    child: const Text('TEST NETWORK', style: TextStyle(color: Colors.amber, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
                  ),
              ]),
              const SizedBox(height: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  b == null ? '—' : (_hidden ? r'$ ••••' : usd(_total)),
                  key: ValueKey('${_hidden}_${_total.toStringAsFixed(2)}'),
                  style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: -1),
                ),
              ),
              if (change != null && !_hidden)
                Text('${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}% today',
                    style: TextStyle(color: change >= 0 ? const Color(0xFF7DF3DB) : const Color(0xFFFF9AA2), fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: w.address!));
                  showInfo(context, 'Address copied');
                },
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_short(w.address!), style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 13)),
                    const SizedBox(width: 6),
                    const Icon(Icons.copy_rounded, color: Colors.white54, size: 15),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              Row(children: [
                _CardAction(icon: Icons.arrow_upward_rounded, label: 'Send', onTap: () => _openSend('USDT')),
                const SizedBox(width: 10),
                _CardAction(
                  icon: Icons.arrow_downward_rounded,
                  label: 'Receive',
                  onTap: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _ReceiveSheet(address: w.address!, net: w.net)),
                ),
                const SizedBox(width: 10),
                _CardAction(icon: Icons.qr_code_scanner_rounded, label: 'Scan', onTap: () async {
                  final v = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const _ScanScreen()));
                  if (v != null && mounted) _openSendTo(v);
                }),
              ]),
            ]),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Text(_error!, style: const TextStyle(color: _out)),
            ),
          if (b != null && !b.activated)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: _Note(
                icon: Icons.info_rounded,
                text: 'New wallets wake up with their first deposit. To send USDT later you also need a little TRX (about 15–30 TRX) for the network fee.',
              ),
            ),
          const _Section('Assets'),
          _AssetTile(
            name: 'Tether',
            symbol: 'USDT',
            color: _usdtColor,
            glyph: '₮',
            amount: b?.usdt,
            price: _usdtPx,
            change: _px['tether']?.$2,
            hidden: _hidden,
            onTap: () => _openAsset('USDT'),
          ),
          _AssetTile(
            name: 'TRON',
            symbol: 'TRX',
            color: _trxColor,
            glyph: 'T',
            amount: b?.trx,
            price: _trxPx,
            change: _px['tron']?.$2,
            hidden: _hidden,
            onTap: () => _openAsset('TRX'),
          ),
          const _Section('Activity'),
          if (_txs == null && _error == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if ((_txs ?? const []).isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text('No transfers yet. Tap Receive to get your address.', style: TextStyle(color: Brand.muted)),
            )
          else
            for (final t in _txs!.take(30)) _TxTile(tx: t, me: w.address!, net: w.net, hidden: _hidden),
        ]),
      ),
    );
  }

  void _openSendTo(String scanned) {
    final w = context.read<WalletStore>();
    final addr = _addressFrom(scanned);
    if (addr == null) {
      showInfo(context, 'That QR code is not a TRON address');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: _SendScreen(token: 'USDT', balance: _bal, prices: _px, to: addr))),
    ).then((_) => _load(quiet: true));
  }

  void _openAsset(String token) {
    final w = context.read<WalletStore>();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider.value(
          value: w,
          child: _AssetScreen(token: token, balance: _bal, txs: _txs ?? const [], prices: _px, onSend: () => _openSend(token)),
        ),
      ),
    );
  }
}

String? _addressFrom(String raw) {
  var s = raw.trim();
  final m = RegExp(r'T[1-9A-HJ-NP-Za-km-z]{33}').firstMatch(s);
  if (m == null) return null;
  s = m.group(0)!;
  return TronCrypto.isValidAddress(s) ? s : null;
}

class _CardAction extends StatelessWidget {
  const _CardAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Material(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Column(children: [
                Icon(icon, color: Colors.white, size: 22),
                const SizedBox(height: 4),
                Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5)),
              ]),
            ),
          ),
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 6),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: -0.2)),
      );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.color = Brand.sky});
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.11), borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.35))),
        ]),
      );
}

class _TokenIcon extends StatelessWidget {
  const _TokenIcon({required this.color, required this.glyph, this.size = 44});
  final Color color;
  final String glyph;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [Color.lerp(color, Colors.white, 0.15)!, color], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: Text(glyph, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * 0.46)),
      );
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({
    required this.name,
    required this.symbol,
    required this.color,
    required this.glyph,
    required this.amount,
    required this.price,
    required this.change,
    required this.hidden,
    required this.onTap,
  });
  final String name;
  final String symbol;
  final Color color;
  final String glyph;
  final BigInt? amount;
  final double price;
  final double? change;
  final bool hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final value = amount == null ? null : Units.toDouble(amount!) * price;
    final up = (change ?? 0) >= 0;
    return ListTile(
      onTap: onTap,
      leading: _TokenIcon(color: color, glyph: glyph),
      title: Text(name),
      subtitle: Row(children: [
        Text(price > 0 ? usd(price) : '—'),
        if (change != null) ...[
          const SizedBox(width: 6),
          Text('${up ? '+' : ''}${change!.toStringAsFixed(2)}%', style: TextStyle(color: up ? _mint : _out, fontWeight: FontWeight.w600)),
        ],
      ]),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(amount == null ? '—' : (hidden ? '••••' : '${Units.format(amount!, maxFraction: 4)} $symbol'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        if (value != null && !hidden) Text(usd(value), style: const TextStyle(color: Brand.muted, fontSize: 13)),
      ]),
    );
  }
}

class _TxTile extends StatelessWidget {
  const _TxTile({required this.tx, required this.me, required this.net, required this.hidden});
  final WalletTx tx;
  final String me;
  final TronNet net;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final incoming = tx.to == me;
    final other = incoming ? tx.from : tx.to;
    final color = !tx.ok ? Brand.muted : (incoming ? _mint : Theme.of(context).colorScheme.onSurface);
    return ListTile(
      onTap: () => _txSheet(context, tx, me, net),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: (incoming ? _mint : Brand.primary).withValues(alpha: 0.12), shape: BoxShape.circle),
        child: Icon(!tx.ok ? Icons.error_outline_rounded : (incoming ? Icons.south_west_rounded : Icons.north_east_rounded), color: incoming ? _mint : Brand.primary, size: 20),
      ),
      title: Text(!tx.ok ? 'Failed' : (incoming ? 'Received' : 'Sent')),
      subtitle: Text('${incoming ? 'From' : 'To'} ${_short(other)} · ${DateFormat('d MMM, HH:mm').format(tx.time)}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(hidden ? '••••' : '${incoming ? '+' : '−'}${Units.format(tx.amount, maxFraction: 4)} ${tx.token}',
          style: TextStyle(fontWeight: FontWeight.w700, color: color)),
    );
  }
}

void _txSheet(BuildContext context, WalletTx tx, String me, TronNet net) {
  final incoming = tx.to == me;
  Widget row(String k, String v, {bool copy = false}) => ListTile(
        dense: true,
        title: Text(k, style: const TextStyle(color: Brand.muted, fontSize: 13)),
        subtitle: SelectableText(v, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
        trailing: copy
            ? IconButton(
                icon: const Icon(Icons.copy_rounded, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: v));
                  showInfo(context, 'Copied');
                },
              )
            : null,
      );
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('${incoming ? '+' : '−'}${Units.format(tx.amount)} ${tx.token}',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: incoming ? _mint : null)),
        Text(tx.ok ? (incoming ? 'Received' : 'Sent') : 'Failed', style: const TextStyle(color: Brand.muted)),
        const SizedBox(height: 8),
        row('Date', DateFormat('d MMMM y, HH:mm').format(tx.time)),
        row(incoming ? 'From' : 'To', incoming ? tx.from : tx.to, copy: true),
        row('Transaction', tx.id, copy: true),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            onPressed: () => launchUrl(Uri.parse('${net.explorer}${tx.id}'), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('View on Tronscan'),
          ),
        ),
      ]),
    ),
  );
}

// ======================================================================== receive
class _ReceiveSheet extends StatelessWidget {
  const _ReceiveSheet({required this.address, required this.net});
  final String address;
  final TronNet net;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Receive', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('USDT (TRC-20) and TRX on ${net.name}', style: const TextStyle(color: Brand.muted)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 18)]),
              child: Stack(alignment: Alignment.center, children: [
                QrImageView(
                  data: address,
                  size: 220,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Brand.primary),
                  dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Brand.ink),
                  errorCorrectionLevel: QrErrorCorrectLevel.H,
                ),
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  child: const _TokenIcon(color: _usdtColor, glyph: '₮', size: 40),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            SelectableText(address, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'monospace', fontSize: 14.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(50)),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: address));
                HapticFeedback.selectionClick();
                showInfo(context, 'Address copied');
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy address'),
            ),
            const SizedBox(height: 12),
            const _Note(
              icon: Icons.warning_amber_rounded,
              color: Color(0xFFE08A1E),
              text: 'Send only USDT (TRC-20) or TRX on the TRON network here. Coins sent from another network (ERC-20, BEP-20 …) are lost.',
            ),
          ]),
        ),
      );
}

class _ScanScreen extends StatefulWidget {
  const _ScanScreen();
  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan an address')),
        body: Stack(fit: StackFit.expand, children: [
          MobileScanner(
            controller: _controller,
            onDetect: (c) {
              final v = c.barcodes.firstOrNull?.rawValue;
              if (v == null || _done) return;
              _done = true;
              HapticFeedback.mediumImpact();
              Navigator.pop(context, v);
            },
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(24)),
            ),
          ),
        ]),
      );
}

// ======================================================================== send
class _SendScreen extends StatefulWidget {
  const _SendScreen({required this.token, required this.balance, required this.prices, this.to});
  final String token;
  final WalletBalance? balance;
  final Map<String, (double, double)> prices;
  final String? to;

  @override
  State<_SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<_SendScreen> {
  late String _token = widget.token;
  late final _to = TextEditingController(text: widget.to ?? '');
  final _amount = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _to.addListener(() => setState(() {}));
    _amount.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _to.dispose();
    _amount.dispose();
    super.dispose();
  }

  BigInt get _have => _token == 'USDT' ? (widget.balance?.usdt ?? BigInt.zero) : (widget.balance?.trx ?? BigInt.zero);
  double get _price => _token == 'USDT' ? (widget.prices['tether']?.$1 ?? 1) : (widget.prices['tron']?.$1 ?? 0);

  String? get _toError {
    final t = _to.text.trim();
    if (t.isEmpty) return null;
    if (!TronCrypto.isValidAddress(t)) return 'Not a TRON address (they start with T)';
    if (t == context.read<WalletStore>().address) return 'This is your own address';
    return null;
  }

  BigInt? get _units => Units.parse(_amount.text);

  String? get _amountError {
    if (_amount.text.trim().isEmpty) return null;
    final u = _units;
    if (u == null || u <= BigInt.zero) return 'Enter an amount';
    if (u > _have) return 'More than you have';
    return null;
  }

  bool get _ready => _toError == null && _amountError == null && _to.text.trim().isNotEmpty && (_units ?? BigInt.zero) > BigInt.zero;

  void _max() {
    var v = _have;
    if (_token == 'TRX') v -= BigInt.from(1100000); // keep a little for the fee
    if (v < BigInt.zero) v = BigInt.zero;
    _amount.text = Units.format(v).replaceAll(',', '');
  }

  Future<void> _review() async {
    FocusScope.of(context).unfocus();
    final w = context.read<WalletStore>();
    setState(() => _busy = true);
    PreparedTx p;
    try {
      final to = _to.text.trim();
      p = _token == 'USDT' ? await w.api.prepareUsdt(w.address!, to, _units!) : await w.api.prepareTrx(w.address!, to, _units!);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showInfo(context, e is WalletException ? e.message : 'Can’t reach the network. Try again.');
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final trxPx = widget.prices['tron']?.$1 ?? 0;
    final trxHave = widget.balance?.trx ?? BigInt.zero;
    final needTrx = p.feeSun + (_token == 'TRX' ? p.amount : BigInt.zero);
    final short = needTrx > trxHave;
    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ConfirmSheet(p: p, price: _price, trxPrice: trxPx, shortOfTrx: short, trxHave: trxHave),
    );
    if (go != true || !mounted) return;
    final phrase = await w.readPhrase(context, 'Confirm sending ${Units.format(p.amount)} ${p.token}');
    if (phrase == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final key = TronCrypto.privateKey(phrase);
      final id = await w.api.broadcast(p, key);
      key.fillRange(0, key.length, 0); // wipe the key from memory
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => _SentScreen(p: p, id: id, net: w.net)));
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showInfo(context, e is WalletException ? e.message : 'Sending failed. Nothing was taken.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = _units;
    return Scaffold(
      appBar: AppBar(title: const Text('Send')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 24), children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'USDT', label: Text('USDT'), icon: _TokenIcon(color: _usdtColor, glyph: '₮', size: 20)),
              ButtonSegment(value: 'TRX', label: Text('TRX'), icon: _TokenIcon(color: _trxColor, glyph: 'T', size: 20)),
            ],
            selected: {_token},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() {
              _token = s.first;
              _amount.clear();
            }),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _to,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14.5),
            decoration: InputDecoration(
              labelText: 'To (TRON address)',
              errorText: _toError,
              suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: () async {
                    final d = await Clipboard.getData('text/plain');
                    final a = _addressFrom(d?.text ?? '');
                    if (a != null) {
                      _to.text = a;
                    } else if (mounted) {
                      showInfo(context, 'No TRON address in the clipboard');
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Scan QR',
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  onPressed: () async {
                    final v = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const _ScanScreen()));
                    final a = v == null ? null : _addressFrom(v);
                    if (a != null) _to.text = a;
                    if (v != null && a == null && mounted) showInfo(context, 'That QR code is not a TRON address');
                  },
                ),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
            decoration: InputDecoration(
              labelText: 'Amount',
              suffixText: _token,
              errorText: _amountError,
              helperText: u != null && u > BigInt.zero && _price > 0 ? '≈ ${usd(Units.toDouble(u) * _price)}' : null,
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text('Available: ${Units.format(_have, maxFraction: 4)} $_token', style: const TextStyle(color: Brand.muted)),
            const Spacer(),
            TextButton(onPressed: _max, child: const Text('Max')),
          ]),
          const SizedBox(height: 10),
          if (_token == 'USDT')
            const _Note(icon: Icons.local_gas_station_rounded, text: 'Sending USDT costs a network fee paid in TRX (usually 15–30 TRX). You’ll see the exact amount before you confirm.'),
          const SizedBox(height: 18),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(54)),
            onPressed: _ready && !_busy ? _review : null,
            child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)) : const Text('Review'),
          ),
        ]),
      ),
    );
  }
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.p, required this.price, required this.trxPrice, required this.shortOfTrx, required this.trxHave});
  final PreparedTx p;
  final double price;
  final double trxPrice;
  final bool shortOfTrx;
  final BigInt trxHave;

  @override
  Widget build(BuildContext context) {
    Widget row(String k, Widget v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 90, child: Text(k, style: const TextStyle(color: Brand.muted))),
            Expanded(child: Align(alignment: Alignment.centerRight, child: v)),
          ]),
        );
    final feeTrx = Units.format(p.feeSun, maxFraction: 3);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Confirm transfer', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          Text('${Units.format(p.amount)} ${p.token}', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
          if (price > 0) Text('≈ ${usd(Units.toDouble(p.amount) * price)}', style: const TextStyle(color: Brand.muted)),
          const SizedBox(height: 14),
          row('To', SelectableText(p.to, textAlign: TextAlign.right, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600))),
          row('Network fee', Text('≈ $feeTrx TRX${trxPrice > 0 ? '  (${usd(Units.toDouble(p.feeSun) * trxPrice)})' : ''}', style: const TextStyle(fontWeight: FontWeight.w600))),
          row('Network', const Text('TRON', style: TextStyle(fontWeight: FontWeight.w600))),
          const SizedBox(height: 8),
          if (shortOfTrx)
            _Note(
              icon: Icons.error_outline_rounded,
              color: _out,
              text: 'You have ${Units.format(trxHave, maxFraction: 2)} TRX, but this needs about $feeTrx TRX for the fee. Add TRX first.',
            )
          else
            const _Note(icon: Icons.verified_user_rounded, color: _mint, text: 'Check the address. Transfers can’t be undone.'),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(52)),
                onPressed: shortOfTrx ? null : () => Navigator.pop(context, true),
                icon: const Icon(Icons.fingerprint_rounded),
                label: const Text('Send'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _SentScreen extends StatelessWidget {
  const _SentScreen({required this.p, required this.id, required this.net});
  final PreparedTx p;
  final String id;
  final TronNet net;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(26),
            child: Column(children: [
              const Spacer(),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 600),
                curve: Curves.elasticOut,
                builder: (_, v, c) => Transform.scale(scale: v, child: c),
                child: Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: _mint.withValues(alpha: 0.14)),
                  child: const Icon(Icons.check_rounded, color: _mint, size: 64),
                ),
              ),
              const SizedBox(height: 22),
              const Text('Sent', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text('${Units.format(p.amount)} ${p.token} to ${_short(p.to)}', style: const TextStyle(color: Brand.muted, fontSize: 15)),
              const SizedBox(height: 4),
              const Text('It usually arrives within a minute.', style: TextStyle(color: Brand.faint)),
              const Spacer(),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: () => launchUrl(Uri.parse('${net.explorer}$id'), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('View on Tronscan'),
              ),
              const SizedBox(height: 10),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(52)),
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ]),
          ),
        ),
      );
}

// ======================================================================== asset + chart
class _AssetScreen extends StatefulWidget {
  const _AssetScreen({required this.token, required this.balance, required this.txs, required this.prices, required this.onSend});
  final String token;
  final WalletBalance? balance;
  final List<WalletTx> txs;
  final Map<String, (double, double)> prices;
  final VoidCallback onSend;

  @override
  State<_AssetScreen> createState() => _AssetScreenState();
}

class _AssetScreenState extends State<_AssetScreen> {
  int _days = 7;
  List<PricePoint>? _pts;
  String? _err;
  int? _touch;

  String get _coin => widget.token == 'USDT' ? 'tether' : 'tron';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _pts = null;
      _err = null;
    });
    try {
      final p = await Prices.chart(_coin, _days);
      if (mounted) setState(() => _pts = p);
    } catch (e) {
      if (mounted) setState(() => _err = 'Price chart is not available right now');
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = context.read<WalletStore>();
    final usdt = widget.token == 'USDT';
    final amount = usdt ? widget.balance?.usdt : widget.balance?.trx;
    final pts = _pts;
    final shown = pts != null && pts.isNotEmpty ? pts[(_touch ?? pts.length - 1).clamp(0, pts.length - 1)] : null;
    final first = pts != null && pts.isNotEmpty ? pts.first.usd : null;
    final now = shown?.usd ?? widget.prices[_coin]?.$1;
    final ch = first != null && now != null && first > 0 ? (now - first) / first * 100 : null;
    final up = (ch ?? 0) >= 0;
    final txs = widget.txs.where((t) => t.token == widget.token).toList();
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          _TokenIcon(color: usdt ? _usdtColor : _trxColor, glyph: usdt ? '₮' : 'T', size: 30),
          const SizedBox(width: 10),
          Text(usdt ? 'Tether' : 'TRON'),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(now == null ? '—' : usd(now), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
            Row(children: [
              if (ch != null) Text('${up ? '+' : ''}${ch.toStringAsFixed(2)}%', style: TextStyle(color: up ? _mint : _out, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Text(shown != null && _touch != null ? DateFormat('d MMM, HH:mm').format(shown.time) : _label(_days), style: const TextStyle(color: Brand.muted)),
            ]),
          ]),
        ),
        SizedBox(
          height: 210,
          child: pts == null
              ? Center(child: _err != null ? Text(_err!, style: const TextStyle(color: Brand.muted)) : const CircularProgressIndicator())
              : LayoutBuilder(
                  builder: (ctx, box) => GestureDetector(
                    onHorizontalDragUpdate: (d) => setState(() => _touch = (d.localPosition.dx / box.maxWidth * (pts.length - 1)).round().clamp(0, pts.length - 1)),
                    onHorizontalDragEnd: (_) => setState(() => _touch = null),
                    onTapDown: (d) => setState(() => _touch = (d.localPosition.dx / box.maxWidth * (pts.length - 1)).round().clamp(0, pts.length - 1)),
                    onTapUp: (_) => setState(() => _touch = null),
                    child: CustomPaint(size: Size(box.maxWidth, 210), painter: _ChartPainter(pts, up ? _mint : _out, _touch, Theme.of(context).brightness == Brightness.dark)),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            for (final d in const [1, 7, 30, 365])
              ChoiceChip(
                label: Text(_chip(d)),
                selected: _days == d,
                onSelected: (_) {
                  setState(() => _days = d);
                  _load();
                },
              ),
          ]),
        ),
        const SizedBox(height: 16),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(20)),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Your balance', style: TextStyle(color: Brand.muted)),
                const SizedBox(height: 2),
                Text(amount == null ? '—' : '${Units.format(amount, maxFraction: 4)} ${widget.token}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                if (amount != null && (widget.prices[_coin]?.$1 ?? 0) > 0)
                  Text(usd(Units.toDouble(amount) * widget.prices[_coin]!.$1), style: const TextStyle(color: Brand.muted)),
              ]),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Brand.primary),
              onPressed: () {
                Navigator.pop(context);
                widget.onSend();
              },
              icon: const Icon(Icons.arrow_upward_rounded, size: 18),
              label: const Text('Send'),
            ),
          ]),
        ),
        const _Section('History'),
        if (txs.isEmpty)
          const Padding(padding: EdgeInsets.fromLTRB(20, 4, 20, 0), child: Text('No transfers yet.', style: TextStyle(color: Brand.muted)))
        else
          for (final t in txs.take(40)) _TxTile(tx: t, me: w.address!, net: w.net, hidden: false),
      ]),
    );
  }

  static String _chip(int d) => switch (d) { 1 => '1D', 7 => '1W', 30 => '1M', _ => '1Y' };
  static String _label(int d) => switch (d) { 1 => 'today', 7 => 'this week', 30 => 'this month', _ => 'this year' };
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.pts, this.color, this.touch, this.dark);
  final List<PricePoint> pts;
  final Color color;
  final int? touch;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (pts.length < 2) return;
    var lo = pts.first.usd;
    var hi = lo;
    for (final p in pts) {
      lo = math.min(lo, p.usd);
      hi = math.max(hi, p.usd);
    }
    if (hi - lo < 1e-9) {
      hi += 0.001;
      lo -= 0.001;
    }
    const top = 16.0;
    final h = size.height - top - 12;
    Offset at(int i) => Offset(i / (pts.length - 1) * size.width, top + (1 - (pts[i].usd - lo) / (hi - lo)) * h);
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < pts.length; i += 1) {
      final a = at(i - 1);
      final b = at(i);
      final mid = (a.dx + b.dx) / 2;
      path.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()..shader = LinearGradient(colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0)], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
    final i = touch ?? pts.length - 1;
    final p = at(i);
    if (touch != null) {
      canvas.drawLine(Offset(p.dx, 0), Offset(p.dx, size.height), Paint()..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.15));
    }
    canvas.drawCircle(p, 7, Paint()..color = color.withValues(alpha: 0.25));
    canvas.drawCircle(p, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => old.pts != pts || old.touch != touch || old.color != color;
}
