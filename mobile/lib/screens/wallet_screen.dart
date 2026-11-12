import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/screen_guard.dart';
import '../state/auth_state.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../core/services.dart';
import '../wallet/address_book.dart';
import '../wallet/evm.dart';
import '../wallet/portfolio.dart';
import '../wallet/tron_api.dart';
import '../wallet/tron_crypto.dart';
import '../wallet/solana.dart';
import '../wallet/utxo.dart';
import '../wallet/wallet_store.dart';
import 'receiving_screen.dart';

// Wallet palette: deep night card, mint for "in", warm for "out". Values in US dollars.
const _mint = Color(0xFF12B89C);
const _out = Color(0xFFE5484D);
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
    _store = WalletStore(uid);
    _store!.load().then((_) {
      if (mounted && _store!.exists && _store!.lockOnOpen) _unlock();
    });
  }

  bool _unlocked = false;

  Future<void> _unlock() async {
    final ok = await WalletStore.confirmOwner(context, 'Open your wallet');
    if (ok && mounted) setState(() => _unlocked = true);
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
          if (!context.watch<AuthState>().feature('wallet')) {
            return Scaffold(
              appBar: AppBar(title: const Text('Wallet')),
              body: const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('The wallet is switched off for now. Your coins are safe on the networks — your 12 words still open them in any wallet.',
                      textAlign: TextAlign.center, style: TextStyle(color: Brand.muted, fontSize: 15)),
                ),
              ),
            );
          }
          if (!w.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          if (w.exists && w.lockOnOpen && !_unlocked) {
            return Scaffold(
              appBar: AppBar(title: const Text('Wallet')),
              body: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: Brand.primary.withValues(alpha: 0.12)),
                    child: const Icon(Icons.lock_rounded, color: Brand.primary, size: 42),
                  ),
                  const SizedBox(height: 16),
                  const Text('Wallet is locked', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Brand.primary),
                    onPressed: _unlock,
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: const Text('Unlock'),
                  ),
                ]),
              ),
            );
          }
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
          const Text('Hold, send and receive BTC, ETH, USDT, BNB, SOL and more — right inside Hushavia.',
              textAlign: TextAlign.center, style: TextStyle(color: Brand.muted, fontSize: 15)),
          const SizedBox(height: 18),
          point(Icons.key_rounded, 'Only you hold the keys', 'Your 12-word recovery phrase stays on this phone. Hushavia never sees it and can’t move your money.'),
          point(Icons.fingerprint_rounded, 'Locked with your fingerprint', 'Every transfer is confirmed with your fingerprint or screen lock.'),
          point(Icons.hub_rounded, 'Many networks, one phrase', 'Bitcoin, Ethereum, BNB Chain, TRON, Solana, Litecoin, Dogecoin and more — plus any token you add.'),
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
  List<WalletAsset> _assets = const [];
  List<WalletTx>? _txs;
  bool _loading = true;
  String? _error;
  bool _hidden = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final w = context.read<WalletStore>();
    if (!quiet) setState(() => _loading = true);
    final assets = Portfolio.build(tron: w.net, custom: w.customTokens);
    // keep showing the last numbers while new ones load
    for (final a in assets) {
      final old = _assets.where((x) => x.key == a.key).firstOrNull;
      if (old != null) {
        a.balance = old.balance;
        a.price = old.price;
        a.change = old.change;
      }
    }
    try {
      final tronTxs = w.api.history(w.address!).catchError((_) => <WalletTx>[]);
      final utxoTxs = Future.wait([
        for (final c in UtxoChain.all)
          if (w.utxoAddr[c.id] != null) UtxoApi(c).history(w.utxoAddr[c.id]!).catchError((_) => <WalletTx>[]),
        if (w.solAddress != null) SolApi().history(w.solAddress!).catchError((_) => <WalletTx>[]),
      ]);
      final sent = SentLog(w.userId).load();
      await Portfolio.load(assets, tronAddress: w.address!, evmAddress: w.evmAddress!, tron: w.net, utxoAddr: w.utxoAddr, solAddress: w.solAddress);
      // a TRON transfer sent from here is in both lists: keep the network's copy (it has the final status)
      final net = await tronTxs;
      final ids = net.map((t) => t.id.toLowerCase()).toSet();
      final utxoList = [for (final l in await utxoTxs) ...l];
      ids.addAll(utxoList.map((t) => t.id.toLowerCase()));
      final txs = [...net, ...utxoList, ...(await sent).where((t) => !ids.contains(t.id.toLowerCase()))]..sort((a, b) => b.time.compareTo(a.time));
      if (!mounted) return;
      setState(() {
        _assets = assets;
        _txs = txs;
        _loading = false;
        _error = assets.every((a) => a.balance == null) ? 'Can’t reach the networks. Pull down to try again.' : null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          if (!quiet) _error = 'Can’t reach the networks. Pull down to try again.';
        });
      }
    }
  }

  double get _total => _assets.fold(0.0, (s, a) => s + a.value);

  double? get _change {
    final t = _total;
    if (t <= 0) return null;
    return _assets.fold<double>(0, (s, a) => s + a.value * (a.change ?? 0)) / t;
  }

  List<WalletAsset> get _shown {
    final w = context.read<WalletStore>();
    final byKey = {for (final a in _assets) a.key.toLowerCase(): a};
    final out = <WalletAsset>[
      for (final k in w.shown)
        if (byKey[k.toLowerCase()] != null) byKey[k.toLowerCase()]!,
    ];
    // coins that hold money always show (after the chosen ones, biggest first); so do added tokens
    final extra = _assets.where((a) => !out.contains(a) && ((a.balance ?? BigInt.zero) > BigInt.zero || a.custom)).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [...out, ...extra];
  }

  void _menu() {
    final w = context.read<WalletStore>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.add_circle_outline_rounded),
              title: const Text('Add a token'),
              subtitle: const Text('Any token on Ethereum, BNB Chain, Polygon …'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: const _AddTokenScreen()))).then((_) => _load());
              },
            ),
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Manage coins'),
              subtitle: const Text('Choose which coins show on the list'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: _ManageCoinsScreen(assets: _assets))))
                    .then((_) => setState(() {}));
              },
            ),
            ListTile(
              leading: const Icon(Icons.contacts_rounded),
              title: const Text('Address book'),
              subtitle: const Text('Saved addresses with names'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: _AddressBookScreen(onSend: (addr) => _openSend(to: addr)))),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.storefront_rounded),
              title: const Text('Receive coin payments'),
              subtitle: const Text('For the Hushavia team: receiving key and collecting deposits'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: const ReceivingScreen())));
              },
            ),
            _ShareSwitch(store: w),
            StatefulBuilder(
              builder: (c2, set2) => SwitchListTile(
                secondary: const Icon(Icons.lock_rounded),
                title: const Text('Lock wallet with fingerprint'),
                subtitle: const Text('Ask every time the wallet is opened'),
                value: w.lockOnOpen,
                onChanged: (v) async {
                  if (!await WalletStore.confirmOwner(context, v ? 'Turn on the wallet lock' : 'Turn off the wallet lock')) return;
                  await w.setLockOnOpen(v);
                  set2(() {});
                },
              ),
            ),
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
            SwitchListTile(
              secondary: const Icon(Icons.science_rounded),
              title: const Text('TRON test network (Nile)'),
              subtitle: const Text('Free test coins for trying the wallet'),
              value: w.net.isTest,
              onChanged: (v) async {
                Navigator.pop(ctx);
                await w.setNet(v ? TronNet.nile : TronNet.main);
                _load();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: _out),
              title: const Text('Remove wallet from this phone', style: TextStyle(color: _out)),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await confirm(context, 'Remove the wallet?',
                    'Your money stays on the networks, but without your 12 recovery words NOBODY can get it back — not even Hushavia. Make sure you have the words.',
                    ok: 'Remove', danger: true);
                if (!ok || !mounted) return;
                if (!await WalletStore.confirmOwner(context, 'Remove your wallet')) return;
                await w.remove();
              },
            ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }

  Future<void> _openSend({WalletAsset? asset, String? to}) async {
    final w = context.read<WalletStore>();
    var a = asset;
    if (a == null) {
      final withMoney = _assets.where((x) => (x.balance ?? BigInt.zero) > BigInt.zero).toList()..sort((x, y) => y.value.compareTo(x.value));
      a = await _pickAsset(context, withMoney.isEmpty ? _assets : withMoney, title: 'Send which coin?', toAddress: to);
      if (a == null || !mounted) return;
    }
    final feeAsset = _assets.firstWhere((x) => x.network == a!.network && x.isNative);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: _SendScreen(asset: a!, feeAsset: feeAsset, to: to))),
    );
    _load(quiet: true);
  }

  void _openAsset(WalletAsset a) {
    final w = context.read<WalletStore>();
    final txs = (_txs ?? const <WalletTx>[]).where((t) => t.network == a.network && t.token == a.symbol).toList();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: _AssetScreen(asset: a, txs: txs, onSend: () => _openSend(asset: a)))),
    ).then((_) => _load(quiet: true));
  }

  @override
  Widget build(BuildContext context) {
    final w = context.watch<WalletStore>();
    final change = _change;
    final shown = _shown;
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
                    child: const Text('TRON TEST', style: TextStyle(color: Colors.amber, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
                  ),
                if (_loading && _assets.isNotEmpty)
                  const Padding(padding: EdgeInsets.only(left: 8), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54))),
              ]),
              const SizedBox(height: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  _assets.isEmpty ? '—' : (_hidden ? r'$ ••••' : usd(_total)),
                  key: ValueKey('${_hidden}_${_total.toStringAsFixed(2)}'),
                  style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: -1),
                ),
              ),
              if (change != null && !_hidden)
                Text('${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}% today',
                    style: TextStyle(color: change >= 0 ? const Color(0xFF7DF3DB) : const Color(0xFFFF9AA2), fontWeight: FontWeight.w600)),
              const SizedBox(height: 18),
              Row(children: [
                _CardAction(icon: Icons.arrow_upward_rounded, label: 'Send', onTap: () => _openSend()),
                const SizedBox(width: 10),
                _CardAction(
                  icon: Icons.arrow_downward_rounded,
                  label: 'Receive',
                  onTap: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => _ReceiveSheet(tron: w.address!, evm: w.evmAddress!, utxo: w.utxoAddr, sol: w.solAddress)),
                ),
                const SizedBox(width: 10),
                _CardAction(icon: Icons.qr_code_scanner_rounded, label: 'Scan', onTap: () async {
                  final v = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const _ScanScreen()));
                  if (v == null || !mounted) return;
                  final addr = _addressFrom(v);
                  if (addr == null) {
                    showInfo(context, 'That QR code is not a wallet address');
                    return;
                  }
                  _openSend(to: addr);
                }),
              ]),
            ]),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 0), child: Text(_error!, style: const TextStyle(color: _out))),
          if (_error == null && !_loading && _assets.any((a) => a.balance == null))
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: _Note(icon: Icons.cloud_off_rounded, color: Color(0xFFE08A1E), text: 'Some networks didn’t answer just now — their balances show “—”. Pull down to try again; your coins are safe.'),
            ),
          if (w.recoveredPhrase != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Material(
                color: const Color(0xFFE08A1E).withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(14),
                child: ListTile(
                  leading: const Icon(Icons.history_edu_rounded, color: Color(0xFFE08A1E)),
                  title: const Text('An earlier wallet was found on this phone', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                  subtitle: const Text('Tap to see its 12 words and write them down — its coins are still there.'),
                  onTap: () async {
                    if (!await WalletStore.confirmOwner(context, 'Show the earlier wallet’s recovery phrase') || !mounted) return;
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: _PhraseScreen(phrase: w.recoveredPhrase!, showOnly: true))));
                    if (!mounted) return;
                    final done = await confirm(context, 'Did you write the words down?',
                        'If yes, this reminder goes away. The words themselves are then removed from this phone — make sure they are on paper.', ok: 'Yes, remove the reminder');
                    if (done) await w.forgetRecovered();
                  },
                ),
              ),
            ),
          _Section('Assets', trailing: TextButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: const _AddTokenScreen()))).then((_) => _load()),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Token'),
          )),
          if (_assets.isEmpty && _loading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else
            for (final a in shown) _AssetTile(asset: a, hidden: _hidden, onTap: () => _openAsset(a)),
          if (_assets.isNotEmpty)
            Center(
              child: TextButton.icon(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChangeNotifierProvider.value(value: w, child: _ManageCoinsScreen(assets: _assets))))
                    .then((_) => setState(() {})),
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('Manage coins'),
              ),
            ),
          const _Section('Activity'),
          if (_txs == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_txs!.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text('No transfers yet. Tap Receive to get your addresses.', style: TextStyle(color: Brand.muted)),
            )
          else
            for (final t in _txs!.take(30)) _TxTile(tx: t, me: w.addressFor(t.network) ?? '', hidden: _hidden, tronNet: w.net),
        ]),
      ),
    );
  }
}

// ======================================================================== manage coins
/// Which coins show on the main list, and in what order (drag to sort). Coins with money always show.
class _ManageCoinsScreen extends StatefulWidget {
  const _ManageCoinsScreen({required this.assets});
  final List<WalletAsset> assets;
  @override
  State<_ManageCoinsScreen> createState() => _ManageCoinsScreenState();
}

class _ManageCoinsScreenState extends State<_ManageCoinsScreen> {
  late List<String> _on = [...context.read<WalletStore>().shown.map((k) => k.toLowerCase())];
  String _q = '';

  void _save() => context.read<WalletStore>().setShown(_on);

  @override
  Widget build(BuildContext context) {
    final byKey = {for (final a in widget.assets) a.key.toLowerCase(): a};
    final on = [for (final k in _on) if (byKey[k] != null) byKey[k]!];
    final q = _q.toLowerCase();
    final off = widget.assets
        .where((a) => !_on.contains(a.key.toLowerCase()))
        .where((a) => q.isEmpty || a.symbol.toLowerCase().contains(q) || a.name.toLowerCase().contains(q) || a.networkName.toLowerCase().contains(q))
        .toList();
    Widget tile(WalletAsset a, bool isOn, {Widget? drag}) => ListTile(
          key: ValueKey(a.key),
          leading: _TokenIcon.of(a, size: 38),
          title: Row(children: [
            Text(a.symbol),
            const SizedBox(width: 6),
            Text(a.networkName, style: const TextStyle(color: Brand.muted, fontSize: 12.5)),
          ]),
          subtitle: a.balance != null && a.balance! > BigInt.zero ? Text('${Units.format(a.balance!, decimals: a.decimals, maxFraction: 4)} ${a.symbol}') : null,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Switch(
              value: isOn,
              onChanged: (v) {
                setState(() => v ? _on.add(a.key.toLowerCase()) : _on.remove(a.key.toLowerCase()));
                _save();
              },
            ),
            if (drag != null) drag,
          ]),
        );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage coins'),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _on = [...WalletStore.defaultShown]);
              _save();
            },
            child: const Text('Reset'),
          ),
        ],
      ),
      body: CustomScrollView(slivers: [
        const SliverToBoxAdapter(child: _Section('On your list')),
        SliverReorderableList(
          itemCount: on.length,
          onReorder: (from, to) {
            setState(() {
              final k = _on.removeAt(_on.indexOf(on[from].key.toLowerCase()));
              final target = to > from ? to - 1 : to;
              _on.insert(target.clamp(0, _on.length), k);
            });
            _save();
          },
          itemBuilder: (ctx, i) => Material(
            key: ValueKey(on[i].key),
            color: Colors.transparent,
            child: tile(on[i], true, drag: ReorderableDragStartListener(index: i, child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle_rounded)))),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Find a coin or network'),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: _Section('More coins')),
        SliverList.list(children: [for (final a in off) tile(a, false)]),
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 32),
            child: Text('A coin you hold always shows, even when it’s off here. Need another token? Wallet → ⋮ → Add a token.',
                style: TextStyle(color: Brand.muted, fontSize: 13)),
          ),
        ),
      ]),
    );
  }
}

// ======================================================================== address book
class _AddressBookScreen extends StatefulWidget {
  const _AddressBookScreen({required this.onSend});
  final void Function(String address) onSend;
  @override
  State<_AddressBookScreen> createState() => _AddressBookScreenState();
}

class _AddressBookScreenState extends State<_AddressBookScreen> {
  List<SavedAddress>? _list;
  String _q = '';

  AddressBook get _book => AddressBook(context.read<WalletStore>().userId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await _book.load();
    if (mounted) setState(() => _list = l);
  }

  /// Add a new address, or rename [edit].
  Future<void> _editor({SavedAddress? edit}) async {
    final name = TextEditingController(text: edit?.name ?? '');
    final addr = TextEditingController(text: edit?.address ?? '');
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          final a = addr.text.trim();
          final valid = _familyOf(a) != null;
          final dup = edit == null && (_list ?? const []).any((x) => x.address.toLowerCase() == a.toLowerCase());
          final look = edit == null && valid ? AddressBook.lookalike((_list ?? const []).map((x) => x.address), a) : null;
          return Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(edit == null ? 'New address' : 'Edit name', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              TextField(
                controller: name,
                autofocus: true,
                maxLength: 40,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => set(() {}),
                decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Ali — Binance'),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: addr,
                enabled: edit == null,
                autocorrect: false,
                onChanged: (_) => set(() {}),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Address',
                  errorText: a.isEmpty ? null : (!valid ? 'Not a wallet address we know' : (dup ? 'Already saved' : null)),
                  helperText: valid ? (_familyOf(a) == 'evm' ? 'Ethereum, BNB Chain, Polygon, Arbitrum, Base, Avalanche' : _familyName(_familyOf(a)!)) : null,
                  suffixIcon: edit != null
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.content_paste_rounded),
                          onPressed: () async {
                            final d = await Clipboard.getData('text/plain');
                            final found = _addressFrom(d?.text ?? '');
                            if (found != null) set(() => addr.text = found);
                          },
                        ),
                ),
              ),
              if (look != null) ...[
                const SizedBox(height: 10),
                _Note(icon: Icons.gpp_maybe_rounded, color: _out, text: 'This looks like an address you already saved (${_short(look)}) but is different. Check it carefully.'),
              ],
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(50)),
                onPressed: name.text.trim().isEmpty || !valid || dup ? null : () => Navigator.pop(ctx, true),
                child: const Text('Save'),
              ),
            ]),
          );
        },
      ),
    );
    if (saved != true) return;
    final a = addr.text.trim();
    await _book.add(name.text, _familyOf(a) == 'evm' ? EvmCrypto.checksum(a.substring(2)) : a);
    await _load();
  }

  void _actions(SavedAddress x) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(x.name, style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: SelectableText(x.address, style: const TextStyle(fontFamily: 'monospace')),
          ),
          ListTile(
            leading: const Icon(Icons.arrow_upward_rounded),
            title: const Text('Send to this address'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
              widget.onSend(x.address);
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_rounded),
            title: const Text('Copy address'),
            onTap: () {
              Navigator.pop(ctx);
              Clipboard.setData(ClipboardData(text: x.address));
              showInfo(context, 'Address copied');
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_rounded),
            title: const Text('Rename'),
            onTap: () {
              Navigator.pop(ctx);
              _editor(edit: x);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: _out),
            title: const Text('Delete', style: TextStyle(color: _out)),
            onTap: () async {
              Navigator.pop(ctx);
              if (!await confirm(context, 'Delete ${x.name}?', 'Only the saved name and address go away.', ok: 'Delete', danger: true)) return;
              await _book.remove(x.address);
              await _load();
            },
          ),
          const SizedBox(height: 6),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = _list;
    final q = _q.toLowerCase();
    final shown = all?.where((x) => q.isEmpty || x.name.toLowerCase().contains(q) || x.address.toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Address book')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editor(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add'),
      ),
      body: all == null
          ? const Center(child: CircularProgressIndicator())
          : all.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('No saved addresses yet.\nAdd the wallets you send to often — then pick them by name, without copying long addresses.',
                        textAlign: TextAlign.center, style: TextStyle(color: Brand.muted, fontSize: 15, height: 1.4)),
                  ),
                )
              : ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                  if (all.length > 5)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: TextField(
                        onChanged: (v) => setState(() => _q = v),
                        decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Search names or addresses'),
                      ),
                    ),
                  for (final x in shown!)
                    ListTile(
                      onTap: () => _actions(x),
                      leading: CircleAvatar(
                        backgroundColor: Brand.primary.withValues(alpha: 0.13),
                        child: Text(x.name.isEmpty ? '?' : x.name.substring(0, 1).toUpperCase(), style: const TextStyle(color: Brand.primary, fontWeight: FontWeight.w800)),
                      ),
                      title: Text(x.name),
                      subtitle: Text('${_familyName(_familyOf(x.address) ?? '?')} · ${_short(x.address)}', style: const TextStyle(fontSize: 12.5)),
                      trailing: const Icon(Icons.chevron_right_rounded),
                    ),
                ]),
    );
  }
}

/// "Friends can pay me in chats": shares ONLY the public addresses with people you chat with.
class _ShareSwitch extends StatefulWidget {
  const _ShareSwitch({required this.store});
  final WalletStore store;
  @override
  State<_ShareSwitch> createState() => _ShareSwitchState();
}

class _ShareSwitchState extends State<_ShareSwitch> {
  bool? _on;
  String get _key => 'wallet_share_v1_${widget.store.userId}';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) => mounted ? setState(() => _on = p.getBool(_key) ?? false) : null);
  }

  Future<void> _set(bool v) async {
    final w = widget.store;
    try {
      await context.read<AppServices>().api.put('/me/wallet', {'share': v, 'tron': w.address, 'evm': w.evmAddress, 'sol': w.solAddress, ...w.utxoAddr});
      (await SharedPreferences.getInstance()).setBool(_key, v);
      if (mounted) setState(() => _on = v);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
        secondary: const Icon(Icons.forum_rounded),
        title: const Text('Friends can pay me in chats'),
        subtitle: const Text('Shares only your public addresses with people you chat with'),
        value: _on ?? false,
        onChanged: _on == null ? null : _set,
      );
}

/// Which kind of address this is: 'tron', 'evm', 'btc', 'ltc', 'doge' — or null.
String? _familyOf(String a) {
  final s = a.trim();
  if (TronCrypto.isValidAddress(s)) return 'tron';
  if (EvmCrypto.isValidAddress(s)) return 'evm';
  for (final c in UtxoChain.all) {
    if (UtxoCrypto.isValidAddress(s, c)) return c.id;
  }
  if (Sol.isValidAddress(s)) return 'sol';
  return null;
}

/// The address family an asset uses.
String _familyOfAsset(WalletAsset a) => a.isTron ? 'tron' : (a.isUtxo || a.isSol ? a.network : 'evm');

String _familyName(String f) => switch (f) {
      'tron' => 'TRON',
      'evm' => 'Ethereum-style (0x…)',
      'sol' => 'Solana',
      _ => UtxoChain.byId(f)?.name ?? f,
    };

/// An address inside any text (QR codes often carry "bitcoin:bc1…?amount=…" or "ethereum:0x…").
String? _addressFrom(String raw) {
  for (final w in raw.split(RegExp(r'[^A-Za-z0-9]+'))) {
    if (w.length >= 25 && _familyOf(w) != null) return w;
  }
  return null;
}

Future<WalletAsset?> _pickAsset(BuildContext context, List<WalletAsset> assets, {required String title, String? toAddress}) {
  // a scanned address decides the network family
  final list = toAddress == null
      ? assets
      : assets.where((a) => _familyOfAsset(a) == _familyOf(toAddress)).toList();
  return showModalBottomSheet<WalletAsset>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (_, scroll) => Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
        Expanded(
          child: ListView(controller: scroll, children: [
            for (final a in list) _AssetTile(asset: a, hidden: false, onTap: () => Navigator.pop(ctx, a)),
          ]),
        ),
      ]),
    ),
  );
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
  const _Section(this.text, {this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 22, trailing == null ? 20 : 8, 6),
        child: Row(children: [
          Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: -0.2))),
          if (trailing != null) trailing!,
        ]),
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

/// Coin badge; tokens get a small network dot so USDT on TRON and USDT on BNB never look the same.
class _TokenIcon extends StatelessWidget {
  const _TokenIcon({required this.color, required this.glyph, this.size = 44, this.network});
  final Color color;
  final String glyph;
  final double size;
  final Color? network;

  static _TokenIcon of(WalletAsset a, {double size = 44}) => _TokenIcon(
        color: a.color,
        glyph: a.glyph,
        size: size,
        network: a.isNative ? null : (a.isTron ? const Color(0xFFEB0029) : Color(a.evm?.color ?? 0xFF888888)),
      );

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [Color.lerp(color, Colors.white, 0.15)!, color], begin: Alignment.topLeft, end: Alignment.bottomRight),
            ),
            child: Text(glyph, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * 0.44)),
          ),
          if (network != null)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: size * 0.38,
                height: size * 0.38,
                decoration: BoxDecoration(color: network, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2)),
              ),
            ),
        ]),
      );
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({required this.asset, required this.hidden, required this.onTap});
  final WalletAsset asset;
  final bool hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = asset;
    final up = (a.change ?? 0) >= 0;
    return ListTile(
      onTap: onTap,
      leading: _TokenIcon.of(a),
      title: Row(children: [
        Flexible(child: Text(a.symbol, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
          child: Text(a.networkName, style: const TextStyle(fontSize: 10.5, color: Brand.muted, fontWeight: FontWeight.w600)),
        ),
      ]),
      subtitle: Row(children: [
        Text(a.price != null ? usd(a.price!) : '—'),
        if (a.change != null) ...[
          const SizedBox(width: 6),
          Text('${up ? '+' : ''}${a.change!.toStringAsFixed(2)}%', style: TextStyle(color: up ? _mint : _out, fontWeight: FontWeight.w600)),
        ],
      ]),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(a.balance == null ? '—' : (hidden ? '••••' : Units.format(a.balance!, decimals: a.decimals, maxFraction: 4)),
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        if (a.balance != null && a.price != null && !hidden) Text(usd(a.value), style: const TextStyle(color: Brand.muted, fontSize: 13)),
      ]),
    );
  }
}

String _explorerTx(WalletTx t, TronNet tron) {
  if (t.network == 'tron') return '${tron.explorer}${t.id}';
  final u = UtxoChain.byId(t.network);
  if (u != null) return u.txUrl(t.id);
  if (t.network == 'sol') return '${Sol.explorer}/tx/${t.id}';
  final c = EvmChain.byId(t.network);
  return c == null ? '' : '${c.explorer}/tx/${t.id}';
}

String _netName(String network) => network == 'tron' ? 'TRON' : network == 'sol' ? 'Solana' : (UtxoChain.byId(network)?.name ?? EvmChain.byId(network)?.name ?? network);

class _TxTile extends StatelessWidget {
  const _TxTile({required this.tx, required this.me, required this.hidden, required this.tronNet});
  final WalletTx tx;
  final String me;
  final bool hidden;
  final TronNet tronNet;

  @override
  Widget build(BuildContext context) {
    final incoming = tx.to.toLowerCase() == me.toLowerCase() && tx.from.toLowerCase() != me.toLowerCase();
    final other = incoming ? tx.from : tx.to;
    final color = !tx.ok ? Brand.muted : (incoming ? _mint : Theme.of(context).colorScheme.onSurface);
    return ListTile(
      onTap: () => _txSheet(context, tx, incoming, tronNet),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: (incoming ? _mint : Brand.primary).withValues(alpha: 0.12), shape: BoxShape.circle),
        child: Icon(!tx.ok ? Icons.error_outline_rounded : (incoming ? Icons.south_west_rounded : Icons.north_east_rounded), color: incoming ? _mint : Brand.primary, size: 20),
      ),
      title: Text('${!tx.ok ? 'Failed' : (incoming ? 'Received' : 'Sent')} · ${_netName(tx.network)}'),
      subtitle: Text('${incoming ? 'From' : 'To'} ${_short(other)} · ${DateFormat('d MMM, HH:mm').format(tx.time)}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(hidden ? '••••' : '${incoming ? '+' : '−'}${Units.format(tx.amount, decimals: tx.decimals, maxFraction: 4)} ${tx.token}',
          style: TextStyle(fontWeight: FontWeight.w700, color: color)),
    );
  }
}

void _txSheet(BuildContext context, WalletTx tx, bool incoming, TronNet tron) {
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
  final url = _explorerTx(tx, tron);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('${incoming ? '+' : '−'}${Units.format(tx.amount, decimals: tx.decimals)} ${tx.token}',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: incoming ? _mint : null)),
        Text('${tx.ok ? (incoming ? 'Received' : 'Sent') : 'Failed'} on ${_netName(tx.network)}', style: const TextStyle(color: Brand.muted)),
        const SizedBox(height: 8),
        row('Date', DateFormat('d MMMM y, HH:mm').format(tx.time)),
        row(incoming ? 'From' : 'To', incoming ? tx.from : tx.to, copy: true),
        row('Transaction', tx.id, copy: true),
        if (url.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
              onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('View on the explorer'),
            ),
          ),
      ]),
    ),
  );
}

// ======================================================================== receive
class _ReceiveSheet extends StatefulWidget {
  const _ReceiveSheet({required this.tron, required this.evm, this.utxo = const {}, this.sol, this.startEvm = false, this.asset});
  final String? sol;
  final String tron;
  final String evm;
  final Map<String, String> utxo;
  final bool startEvm;
  final WalletAsset? asset; // opened from one coin: say exactly what to send here
  @override
  State<_ReceiveSheet> createState() => _ReceiveSheetState();
}

class _ReceiveSheetState extends State<_ReceiveSheet> {
  late String _sel = widget.asset != null ? _familyOfAsset(widget.asset!) : (widget.startEvm ? 'evm' : 'tron');

  String get _address => switch (_sel) { 'tron' => widget.tron, 'evm' => widget.evm, 'sol' => widget.sol ?? '', _ => widget.utxo[_sel] ?? '' };

  static const _families = [('btc', 'Bitcoin'), ('evm', 'Ethereum · BNB · more'), ('tron', 'TRON'), ('sol', 'Solana'), ('ltc', 'Litecoin'), ('doge', 'Dogecoin')];

  Widget _centerIcon() {
    if (widget.asset != null) return _TokenIcon(color: widget.asset!.color, glyph: widget.asset!.glyph, size: 38);
    final u = UtxoChain.byId(_sel);
    if (u != null) return _TokenIcon(color: Color(u.color), glyph: u.glyph, size: 38);
    if (_sel == 'sol') return const _TokenIcon(color: Color(0xFF9945FF), glyph: '◎', size: 38);
    return _sel == 'evm' ? const _TokenIcon(color: Color(0xFF627EEA), glyph: 'Ξ', size: 38) : const _TokenIcon(color: _trxColor, glyph: 'T', size: 38);
  }

  String get _what => switch (_sel) {
        'tron' => 'USDT (TRC-20) and TRX',
        'evm' => 'One address for Ethereum, BNB Chain, Polygon, Arbitrum, Base and Avalanche',
        'sol' => 'Only SOL on Solana',
        _ => 'Only ${UtxoChain.byId(_sel)?.name ?? ''} (${UtxoChain.byId(_sel)?.symbol ?? ''})',
      };

  @override
  Widget build(BuildContext context) {
    final address = _address;
    final isEvm = _sel == 'evm';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.asset == null ? 'Receive' : 'Receive ${widget.asset!.symbol}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          // opened from one coin: only that coin and its network — no network switch
          if (widget.asset != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _TokenIcon.of(widget.asset!, size: 24),
                const SizedBox(width: 8),
                Text('${widget.asset!.name} · ${widget.asset!.networkName}', style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            )
          else
          Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
            for (final (id, label) in _families)
              ChoiceChip(label: Text(label), selected: _sel == id, onSelected: (_) => setState(() => _sel = id)),
          ]),
          const SizedBox(height: 8),
          Text(
            widget.asset != null
                ? 'Send only ${widget.asset!.symbol} on ${widget.asset!.networkName} to this address'
                : _what,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Brand.muted),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 18)]),
            child: Stack(alignment: Alignment.center, children: [
              QrImageView(
                data: address,
                size: 210,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Brand.primary),
                dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Brand.ink),
                errorCorrectionLevel: QrErrorCorrectLevel.H,
              ),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: _centerIcon(),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          SelectableText(address, textAlign: TextAlign.center, style: const TextStyle(fontFamily: 'monospace', fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
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
          _Note(
            icon: Icons.warning_amber_rounded,
            color: const Color(0xFFE08A1E),
            text: widget.asset != null
                ? 'Only ${widget.asset!.symbol} on ${widget.asset!.networkName} here. The same coin sent from another network is lost.'
                : isEvm
                ? 'Tell the sender which network they use (e.g. BNB Chain). The coins arrive on that same network in your wallet.'
                : _sel == 'tron'
                    ? 'Only TRON coins here (USDT TRC-20, TRX). Coins sent from another network to this address are lost.'
                    : 'Only ${_sel == 'sol' ? 'SOL' : UtxoChain.byId(_sel)?.symbol} here. Other coins sent to this address are lost.',
          ),
        ]),
      ),
    );
  }
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

// ======================================================================== add a token
class _AddTokenScreen extends StatefulWidget {
  const _AddTokenScreen();
  @override
  State<_AddTokenScreen> createState() => _AddTokenScreenState();
}

class _AddTokenScreenState extends State<_AddTokenScreen> {
  EvmChain _chain = EvmChain.bsc;
  final _addr = TextEditingController();
  EvmToken? _found;
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _addr.dispose();
    super.dispose();
  }

  Future<void> _look() async {
    final a = _addr.text.trim();
    setState(() {
      _found = null;
      _err = null;
    });
    if (!EvmCrypto.isValidAddress(a)) {
      if (a.isNotEmpty) setState(() => _err = 'A token address starts with 0x and has 42 characters');
      return;
    }
    setState(() => _busy = true);
    try {
      final t = await EvmApi(_chain).tokenInfo(a);
      if (mounted) setState(() => _found = t);
    } catch (e) {
      if (mounted) setState(() => _err = e is WalletException ? e.message : 'Not found on ${_chain.name}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = context.read<WalletStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Add a token')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 24), children: [
          const Text('Network', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in EvmChain.all)
              ChoiceChip(
                label: Text(c.name),
                selected: _chain == c,
                onSelected: (_) {
                  setState(() => _chain = c);
                  _look();
                },
              ),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _addr,
            autocorrect: false,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            onChanged: (_) => _look(),
            decoration: InputDecoration(
              labelText: 'Token contract address (0x…)',
              errorText: _err,
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste_rounded),
                onPressed: () async {
                  final d = await Clipboard.getData('text/plain');
                  final m = RegExp(r'0x[0-9a-fA-F]{40}').firstMatch(d?.text ?? '');
                  if (m != null) {
                    _addr.text = m.group(0)!;
                    _look();
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_busy) const Center(child: CircularProgressIndicator()),
          if (_found != null) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _TokenIcon(color: Color(_chain.color), glyph: _found!.symbol.substring(0, 1), network: Color(_chain.color)),
              title: Text('${_found!.name} (${_found!.symbol})'),
              subtitle: Text('${_chain.name} · ${_found!.decimals} decimals'),
            ),
            const _Note(
              icon: Icons.warning_amber_rounded,
              color: Color(0xFFE08A1E),
              text: 'Anyone can make a token with any name — even a fake “USDT”. Only add tokens whose address you got from the official project.',
            ),
            const SizedBox(height: 14),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(52)),
              onPressed: () async {
                try {
                  await w.addToken(_found!);
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  showInfo(context, '${_found!.symbol} added');
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              child: Text('Add ${_found!.symbol}'),
            ),
          ],
        ]),
      ),
    );
  }
}

// ======================================================================== send
class _SendScreen extends StatefulWidget {
  const _SendScreen({required this.asset, required this.feeAsset, this.to, this.amount, this.forChat = false, this.toName, this.locked = false, this.onSent});
  /// A bill (e.g. Hushavia Plus): the address and the amount are fixed.
  final bool locked;
  /// Called with the transaction id the moment the network accepts it (before any screen changes).
  final Future<void> Function(String tx)? onSent;
  final WalletAsset asset;
  final WalletAsset feeAsset; // the network's own coin (pays the fee)
  final String? to;
  final BigInt? amount;
  final String? toName; // the chat partner, when paying from a chat
  /// Opened from a chat: on success the screen closes and hands back the card to post.
  final bool forChat;

  @override
  State<_SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<_SendScreen> {
  late final _to = TextEditingController(text: widget.to ?? '');
  late final _amount = TextEditingController(
      text: widget.amount == null ? '' : Units.format(widget.amount!, decimals: widget.asset.decimals, maxFraction: widget.asset.decimals).replaceAll(',', ''));
  bool _busy = false;
  List<SavedAddress> _book = const [];
  List<String> _known = const []; // addresses sent to before (from this phone's history)

  /// Saved and recently used addresses of this coin's kind, for one-tap filling.
  List<String> get _recent {
    final fam = _familyOfAsset(a);
    final out = <String>[];
    for (final x in [..._book.map((b) => b.address), ..._known]) {
      if (_familyOf(x) == fam && !out.any((o) => o.toLowerCase() == x.toLowerCase())) out.add(x);
    }
    return out.take(8).toList();
  }

  WalletAsset get a => widget.asset;

  @override
  void initState() {
    super.initState();
    _to.addListener(() => setState(() {}));
    _amount.addListener(() => setState(() {}));
    final uid = context.read<WalletStore>().userId;
    AddressBook(uid).load().then((b) => mounted ? setState(() => _book = b) : null);
    SentLog(uid).load().then((l) => mounted ? setState(() => _known = l.map((t) => t.to).toSet().toList()) : null);
  }

  @override
  void dispose() {
    _to.dispose();
    _amount.dispose();
    super.dispose();
  }

  BigInt get _have => a.balance ?? BigInt.zero;

  bool _validAddress(String t) => a.isTron
      ? TronCrypto.isValidAddress(t)
      : a.isSol
      ? Sol.isValidAddress(t)
      : a.isUtxo
          ? UtxoCrypto.isValidAddress(t, a.utxo!)
          : EvmCrypto.isValidAddress(t);

  String? get _toError {
    final t = _to.text.trim();
    if (t.isEmpty) return null;
    if (!_validAddress(t)) {
      final other = _familyOf(t);
      if (other != null) return 'This is a ${_familyName(other)} address. ${a.symbol} on ${a.networkName} can’t go there — the coins would be lost';
      return a.isTron
          ? 'Not a TRON address (they start with T)'
          : a.isUtxo
              ? 'Not a ${a.networkName} address'
              : 'Not a valid address (0x… with 42 characters)';
    }
    final w = context.read<WalletStore>();
    if (t.toLowerCase() == (w.addressFor(a.network) ?? '').toLowerCase()) return 'This is your own address';
    return null;
  }

  BigInt? get _units => Units.parse(_amount.text, decimals: a.decimals);

  String? get _amountError {
    if (_amount.text.trim().isEmpty) return null;
    final u = _units;
    if (u == null || u <= BigInt.zero) return 'Enter an amount';
    if (u > _have) return 'More than you have';
    return null;
  }

  bool get _ready => _toError == null && _amountError == null && _to.text.trim().isNotEmpty && (_units ?? BigInt.zero) > BigInt.zero;

  void _max() {
    _part(100);
  }

  /// 25 / 50 / 75 / 100 % of what's there. "All of it" of a network's own coin: the real fee is
  /// worked out on Review and taken from the amount (TRX keeps a little, its fee isn't known before).
  void _part(int percent) {
    var v = _have * BigInt.from(percent) ~/ BigInt.from(100);
    if (percent == 100 && a.isTron && a.isNative) v -= BigInt.from(1100000);
    if (v < BigInt.zero) v = BigInt.zero;
    _amount.text = Units.format(v, decimals: a.decimals, maxFraction: a.decimals).replaceAll(',', '');
    _amount.selection = TextSelection.collapsed(offset: _amount.text.length);
  }

  Future<void> _review() async {
    FocusScope.of(context).unfocus();
    final w = context.read<WalletStore>();
    final to = _to.text.trim();
    final amount = _units!;
    setState(() => _busy = true);
    _Quote q;
    try {
      if (a.isTron) {
        final p = a.symbol == 'TRX' ? await w.api.prepareTrx(w.address!, to, amount) : await w.api.prepareUsdt(w.address!, to, amount);
        q = _Quote(fee: p.feeSun, feeDecimals: 6, tron: p);
      } else if (a.isSol) {
        final p = await SolApi().prepare(from: w.solAddress!, to: to, amount: amount, have: _have);
        q = _Quote(fee: BigInt.from(p.fee), feeDecimals: 9, sol: p, amount: BigInt.from(p.lamports));
      } else if (a.isUtxo) {
        final p = await UtxoApi(a.utxo!).prepare(from: w.utxoAddr[a.network]!, to: to, amount: amount, sweep: amount >= _have);
        q = _Quote(fee: p.fee, feeDecimals: 8, utxo: p, amount: p.amount);
      } else {
        final p = await EvmApi(a.evm!)
            .prepare(from: w.evmAddress!, to: EvmCrypto.checksum(to.substring(2)), amount: amount, token: a.evmToken, have: a.isNative ? _have : null);
        q = _Quote(fee: p.fee, feeDecimals: 18, evm: p, amount: p.amount);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showInfo(context, e is WalletException ? e.message : 'Can’t reach the network. Try again.');
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final feeHave = widget.feeAsset.balance ?? BigInt.zero;
    final sendAmount = q.amount ?? amount; // Bitcoin "send all": what's left after the fee
    final needNative = q.fee + (a.isNative ? sendAmount : BigInt.zero);
    final short = needNative > feeHave;
    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ConfirmSheet(
        asset: a, feeAsset: widget.feeAsset, to: to, amount: sendAmount, fee: q.fee, short: short,
        name: AddressBook.nameFor(_book, to) ?? widget.toName,
        firstTime: AddressBook.nameFor(_book, to) == null && !_known.any((k) => k.toLowerCase() == to.toLowerCase()) && widget.toName == null,
        lookalike: AddressBook.lookalike([..._book.map((b) => b.address), ..._known], to),
      ),
    );
    if (go != true || !mounted) return;
    final phrase = await w.readPhrase(context, 'Confirm sending ${Units.format(sendAmount, decimals: a.decimals)} ${a.symbol}');
    if (phrase == null || !mounted) return;
    setState(() => _busy = true);
    try {
      String id;
      if (q.tron != null) {
        final key = TronCrypto.privateKey(phrase);
        try {
          id = await w.api.broadcast(q.tron!, key);
        } finally {
          key.fillRange(0, key.length, 0); // wipe the key from memory
        }
      } else if (q.sol != null) {
        final key = Sol.privateKey(phrase);
        try {
          id = await SolApi().send(q.sol!, key);
        } finally {
          key.fillRange(0, key.length, 0);
        }
        await SentLog(w.userId).add(WalletTx(
          id: id, token: 'SOL', from: w.solAddress!, to: to, amount: sendAmount, time: DateTime.now(), ok: true, network: 'sol', decimals: Sol.decimals,
        ));
      } else if (q.utxo != null) {
        final key = UtxoCrypto.privateKey(phrase, a.utxo!);
        try {
          id = await UtxoApi(a.utxo!).send(q.utxo!, key);
        } finally {
          key.fillRange(0, key.length, 0);
        }
        await SentLog(w.userId).add(WalletTx(
          id: id, token: a.symbol, from: w.utxoAddr[a.network]!, to: to, amount: sendAmount, time: DateTime.now(), ok: true, network: a.network, decimals: a.decimals,
        ));
      } else {
        final key = EvmCrypto.privateKey(phrase);
        try {
          id = await EvmApi(a.evm!).send(q.evm!, key);
        } finally {
          key.fillRange(0, key.length, 0);
        }
        await SentLog(w.userId).add(WalletTx(
          id: id, token: a.symbol, from: w.evmAddress!, to: to, amount: sendAmount, time: DateTime.now(), ok: true, network: a.network, decimals: a.decimals,
        ));
      }
      try {
        await widget.onSent?.call(id);
      } catch (_) {}
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      final url = a.isTron ? '${w.net.explorer}$id' : a.isSol ? '${Sol.explorer}/tx/$id' : (a.isUtxo ? a.utxo!.txUrl(id) : '${a.evm!.explorer}/tx/$id');
      if (a.isTron) {
        await SentLog(w.userId).add(WalletTx(id: id, token: a.symbol, from: w.address!, to: to, amount: amount, time: DateTime.now(), ok: true, network: 'tron', decimals: a.decimals));
      }
      if (widget.forChat) {
        Navigator.pop(context, <String, dynamic>{
          'kind': 'sent', 'network': a.network, 'symbol': a.symbol, 'amount': '$sendAmount', 'decimals': a.decimals, 'to': to,
          if (a.contract != null) 'contract': a.contract, 'tx': id,
        });
        return;
      }
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => _SentScreen(
            text: '${Units.format(sendAmount, decimals: a.decimals)} ${a.symbol} to ${AddressBook.nameFor(_book, to) ?? _short(to)}',
            url: url,
            saveAddress: AddressBook.nameFor(_book, to) == null ? to : null,
            userId: w.userId,
          ),
        ),
      );
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
    final hint = a.isTron ? 'T…' : a.isSol ? 'Solana address' : (a.isUtxo ? (a.utxo!.segwit ? '${a.utxo!.hrp}1…' : 'D…') : '0x…');
    return Scaffold(
      appBar: AppBar(title: Text('Send ${a.symbol}')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 24), children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _TokenIcon.of(a, size: 40),
            title: Text('${a.name} · ${a.symbol}'),
            subtitle: Text('on ${a.networkName}'),
          ),
          const SizedBox(height: 6),
          if (widget.locked)
            _Note(icon: Icons.lock_rounded, text: widget.amount == null
                ? 'Payment to ${widget.toName ?? 'Hushavia'}. The address is set — choose the amount.'
                : 'Payment to ${widget.toName ?? 'Hushavia'}. The address and the amount are set for this order — you only confirm.'),
          if (widget.locked) const SizedBox(height: 10),
          TextField(
            controller: _to,
            readOnly: widget.locked,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            decoration: InputDecoration(
              labelText: 'To (${a.networkName} address, $hint)',
              errorText: _toError,
              errorMaxLines: 2,
              helperText: AddressBook.nameFor(_book, _to.text.trim()),
              suffixIcon: widget.locked ? null : Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Address book',
                  icon: const Icon(Icons.contacts_rounded),
                  onPressed: () async {
                    final mine = _book.where((b) => _familyOf(b.address) == _familyOfAsset(a)).toList();
                    if (mine.isEmpty) {
                      showInfo(context, 'No saved ${a.networkName} addresses yet. They’re saved after you send.');
                      return;
                    }
                    final pick = await showModalBottomSheet<String>(
                      context: context,
                      builder: (ctx) => SafeArea(
                        child: ListView(shrinkWrap: true, children: [
                          const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Address book', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                          for (final b in mine)
                            ListTile(
                              leading: CircleAvatar(child: Text(b.name.isEmpty ? '?' : b.name.substring(0, 1).toUpperCase())),
                              title: Text(b.name),
                              subtitle: Text(_short(b.address), style: const TextStyle(fontFamily: 'monospace')),
                              onTap: () => Navigator.pop(ctx, b.address),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () async {
                                  await AddressBook(context.read<WalletStore>().userId).remove(b.address);
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  final nb = await AddressBook(context.read<WalletStore>().userId).load();
                                  if (mounted) setState(() => _book = nb);
                                },
                              ),
                            ),
                        ]),
                      ),
                    );
                    if (pick != null) _to.text = pick;
                  },
                ),
                IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: () async {
                    final d = await Clipboard.getData('text/plain');
                    final addr = _addressFrom(d?.text ?? '');
                    if (addr != null) {
                      _to.text = addr;
                    } else if (mounted) {
                      showInfo(context, 'No address in the clipboard');
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Scan QR',
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  onPressed: () async {
                    final v = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const _ScanScreen()));
                    final addr = v == null ? null : _addressFrom(v);
                    if (addr != null) _to.text = addr;
                    if (v != null && addr == null && mounted) showInfo(context, 'That QR code is not an address');
                  },
                ),
              ]),
            ),
          ),
          if (!widget.locked && _to.text.trim().isEmpty && _recent.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final r in _recent)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      avatar: Icon(AddressBook.nameFor(_book, r) != null ? Icons.person_rounded : Icons.history_rounded, size: 16),
                      label: Text(AddressBook.nameFor(_book, r) ?? _short(r)),
                      onPressed: () => _to.text = r,
                    ),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: 14),
          TextField(
            controller: _amount,
            readOnly: widget.locked && widget.amount != null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
            decoration: InputDecoration(
              labelText: 'Amount',
              suffixText: a.symbol,
              errorText: _amountError,
              helperText: u != null && u > BigInt.zero && a.price != null ? '≈ ${usd(Units.toDouble(u, decimals: a.decimals) * a.price!)}' : null,
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text('Available: ${Units.format(_have, decimals: a.decimals, maxFraction: 6)} ${a.symbol}', style: const TextStyle(color: Brand.muted))),
          ]),
          const SizedBox(height: 6),
          if (!widget.locked || widget.amount == null)
          Row(children: [
            for (final pc in const [25, 50, 75, 100]) ...[
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size.fromHeight(36), visualDensity: VisualDensity.compact),
                  onPressed: _have > BigInt.zero ? () => pc == 100 ? _max() : _part(pc) : null,
                  child: Text(pc == 100 ? 'Max' : '$pc%'),
                ),
              ),
              if (pc != 100) const SizedBox(width: 8),
            ],
          ]),
          const SizedBox(height: 10),
          if (a.isNative && !a.isTron && (_units ?? BigInt.zero) >= _have && _have > BigInt.zero)
            const _Note(icon: Icons.info_rounded, text: 'Sending everything: the network fee is taken from this amount.'),
          if (!a.isNative)
            _Note(
              icon: Icons.local_gas_station_rounded,
              text: 'The network fee is paid in ${a.feeSymbol}. You have ${Units.format(widget.feeAsset.balance ?? BigInt.zero, decimals: widget.feeAsset.decimals, maxFraction: 5)} ${a.feeSymbol}. '
                  'You’ll see the exact fee before you confirm.',
            ),
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

class _Quote {
  _Quote({required this.fee, required this.feeDecimals, this.tron, this.evm, this.utxo, this.sol, this.amount});
  final SolPrepared? sol;
  final BigInt fee;
  final int feeDecimals;
  final PreparedTx? tron;
  final EvmPrepared? evm;
  final UtxoPrepared? utxo;
  final BigInt? amount; // what really gets sent, when it differs from what was typed
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({
    required this.asset, required this.feeAsset, required this.to, required this.amount, required this.fee, required this.short,
    this.name, this.firstTime = false, this.lookalike,
  });
  final String? name;
  final bool firstTime;
  final String? lookalike; // a known address this one only LOOKS like
  final WalletAsset asset;
  final WalletAsset feeAsset;
  final String to;
  final BigInt amount;
  final BigInt fee;
  final bool short;

  @override
  Widget build(BuildContext context) {
    Widget row(String k, Widget v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 96, child: Text(k, style: const TextStyle(color: Brand.muted))),
            Expanded(child: Align(alignment: Alignment.centerRight, child: v)),
          ]),
        );
    final feeText = Units.format(fee, decimals: feeAsset.decimals, maxFraction: 6);
    final feeUsd = feeAsset.price == null ? null : Units.toDouble(fee, decimals: feeAsset.decimals) * feeAsset.price!;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Confirm transfer', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          Text('${Units.format(amount, decimals: asset.decimals)} ${asset.symbol}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
          if (asset.price != null) Text('≈ ${usd(Units.toDouble(amount, decimals: asset.decimals) * asset.price!)}', style: const TextStyle(color: Brand.muted)),
          const SizedBox(height: 14),
          row('To', Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (name != null) Text(name!, style: const TextStyle(fontWeight: FontWeight.w800)),
            SelectableText(to, textAlign: TextAlign.right, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
          ])),
          row('Network', Text(asset.networkName, style: const TextStyle(fontWeight: FontWeight.w600))),
          row('Network fee', Text('≈ $feeText ${feeAsset.symbol}${feeUsd != null ? '  (${usd(feeUsd)})' : ''}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
          const SizedBox(height: 8),
          if (lookalike != null) ...[
            _Note(
              icon: Icons.gpp_maybe_rounded,
              color: _out,
              text: 'Careful: this address only LOOKS like one you used before (${_short(lookalike!)}) — the middle is different. '
                  'Scammers make look-alike addresses. Compare every character.',
            ),
            const SizedBox(height: 8),
          ] else if (firstTime) ...[
            const _Note(icon: Icons.fiber_new_rounded, color: Color(0xFFE08A1E), text: 'You haven’t sent to this address before. Check it with the person — or send a small amount first.'),
            const SizedBox(height: 8),
          ],
          if (short)
            _Note(
              icon: Icons.error_outline_rounded,
              color: _out,
              text: 'Not enough ${feeAsset.symbol} on ${asset.networkName} for this (you have ${Units.format(feeAsset.balance ?? BigInt.zero, decimals: feeAsset.decimals, maxFraction: 5)}). Add some ${feeAsset.symbol} first.',
            )
          else
            const _Note(icon: Icons.verified_user_rounded, color: _mint, text: 'Check the address and the network. Transfers can’t be undone.'),
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
                onPressed: short ? null : () => Navigator.pop(context, true),
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
  const _SentScreen({required this.text, required this.url, this.saveAddress, this.userId = 0});
  final String text;
  final String url;
  final String? saveAddress;
  final int userId;

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
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Brand.muted, fontSize: 15)),
              const SizedBox(height: 4),
              const Text('It usually arrives within a minute.', style: TextStyle(color: Brand.faint)),
              const Spacer(),
              if (saveAddress != null) ...[
                TextButton.icon(
                  onPressed: () async {
                    final name = TextEditingController();
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Save this address'),
                        content: TextField(controller: name, autofocus: true, maxLength: 40, decoration: const InputDecoration(hintText: 'Name, e.g. Ali’s wallet')),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
                        ],
                      ),
                    );
                    if (ok == true && name.text.trim().isNotEmpty) {
                      await AddressBook(userId).add(name.text, saveAddress!);
                      if (context.mounted) showInfo(context, 'Saved to your address book');
                    }
                  },
                  icon: const Icon(Icons.bookmark_add_rounded),
                  label: const Text('Save address'),
                ),
                const SizedBox(height: 6),
              ],
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('View on the explorer'),
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
  const _AssetScreen({required this.asset, required this.txs, required this.onSend});
  final WalletAsset asset;
  final List<WalletTx> txs;
  final VoidCallback onSend;

  @override
  State<_AssetScreen> createState() => _AssetScreenState();
}

class _AssetScreenState extends State<_AssetScreen> {
  int _days = 7;
  List<PricePoint>? _pts;
  String? _err;
  int? _touch;

  WalletAsset get a => widget.asset;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (a.gecko == null) {
      setState(() => _err = 'No price chart for this token');
      return;
    }
    setState(() {
      _pts = null;
      _err = null;
    });
    try {
      final p = await Prices.chart(a.gecko!, _days);
      if (mounted) setState(() => _pts = p);
    } catch (e) {
      if (mounted) setState(() => _err = 'Price chart is not available right now');
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = context.read<WalletStore>();
    final pts = _pts;
    final shown = pts != null && pts.isNotEmpty ? pts[(_touch ?? pts.length - 1).clamp(0, pts.length - 1)] : null;
    final first = pts != null && pts.isNotEmpty ? pts.first.usd : null;
    final now = shown?.usd ?? a.price;
    final ch = first != null && now != null && first > 0 ? (now - first) / first * 100 : a.change;
    final up = (ch ?? 0) >= 0;
    final myAddress = w.addressFor(a.network) ?? '';
    final explorerAddr = a.isTron
        ? '${w.net.explorer.replaceFirst('/transaction/', '/address/')}$myAddress'
        : a.isSol
        ? '${Sol.explorer}/account/$myAddress'
        : a.isUtxo
        ? a.utxo!.addressUrl(myAddress)
        : '${a.evm!.explorer}/${a.isNative ? 'address' : 'token'}/${a.isNative ? myAddress : '${a.contract}?a=$myAddress'}';
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          _TokenIcon.of(a, size: 30),
          const SizedBox(width: 10),
          Flexible(child: Text('${a.symbol} · ${a.networkName}', overflow: TextOverflow.ellipsis)),
        ]),
        actions: [
          if (a.custom)
            IconButton(
              tooltip: 'Remove token',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () async {
                if (!await confirm(context, 'Remove ${a.symbol}?', 'It only disappears from this list — nothing happens to the coins.', ok: 'Remove')) return;
                await w.removeToken(a.evmToken!);
                if (context.mounted) Navigator.pop(context);
              },
            ),
        ],
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
        if (a.gecko != null)
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
                Text(a.balance == null ? '—' : '${Units.format(a.balance!, decimals: a.decimals, maxFraction: 6)} ${a.symbol}',
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                if (a.balance != null && a.price != null) Text(usd(a.value), style: const TextStyle(color: Brand.muted)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Brand.primary, minimumSize: const Size.fromHeight(50)),
                onPressed: () {
                  Navigator.pop(context);
                  widget.onSend();
                },
                icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                label: const Text('Send'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _mint, minimumSize: const Size.fromHeight(50)),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => _ReceiveSheet(tron: w.address!, evm: w.evmAddress!, utxo: w.utxoAddr, sol: w.solAddress, startEvm: !a.isTron, asset: a),
                ),
                icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                label: const Text('Receive'),
              ),
            ),
          ]),
        ),
        _Section('History', trailing: TextButton.icon(
          onPressed: () => launchUrl(Uri.parse(explorerAddr), mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new_rounded, size: 16),
          label: const Text('All on explorer'),
        )),
        if (widget.txs.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Text(a.isTron || a.isUtxo || a.isSol ? 'No transfers yet.' : 'Transfers you send from here show up below. For everything you received, tap “All on explorer”.',
                style: const TextStyle(color: Brand.muted)),
          )
        else
          for (final t in widget.txs.take(40)) _TxTile(tx: t, me: myAddress, hidden: false, tronNet: w.net),
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

// ======================================================================== from a chat
/// Opens the wallet (creating it if needed) and loads balances. Null when there's no usable wallet.
Future<(WalletStore, List<WalletAsset>)?> _walletForChat(BuildContext context) async {
  final auth = context.read<AuthState>();
  if (!auth.feature('wallet')) {
    showInfo(context, 'The wallet is switched off for now');
    return null;
  }
  final w = WalletStore(auth.me?.id ?? 0);
  await w.load();
  if (!context.mounted) return null;
  if (!w.exists) {
    final ok = await confirm(context, 'Set up your wallet', 'To send or ask for crypto in chats, first create your own wallet. It takes a minute.', ok: 'Set up');
    if (ok && context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const WalletScreen()));
    return null;
  }
  final assets = Portfolio.build(tron: w.net, custom: w.customTokens);
  showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
  try {
    await Portfolio.load(assets, tronAddress: w.address!, evmAddress: w.evmAddress!, tron: w.net, utxoAddr: w.utxoAddr, solAddress: w.solAddress);
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
  return (w, assets);
}

/// "Send crypto" from a chat. Returns the card to post (kind: sent) or null.
/// [peerUserId]: the other person in a private chat (their shared address is filled in);
/// [request]: a payment request card being paid.
///
/// Also used to pay a bill ([locked]: the address and amount can't be changed; [onSent] gets the
/// transaction id as soon as the network accepts it).
Future<Map<String, dynamic>?> walletSendForChat(BuildContext context,
    {int? peerUserId, String? peerName, Map<String, dynamic>? request, bool locked = false, Future<void> Function(String tx)? onSent}) async {
  final got = await _walletForChat(context);
  if (got == null || !context.mounted) return null;
  final (w, assets) = got;
  if (locked && request?['network'] == 'tron' && w.net.isTest) {
    showInfo(context, 'Your wallet is on the TRON test network. Switch it off in the wallet menu first.');
    return null;
  }
  WalletAsset? asset;
  String? to;
  BigInt? amount;
  if (request != null) {
    final contract = '${request['contract'] ?? ''}'.toLowerCase();
    asset = assets.where((a) => a.network == '${request['network']}' && (contract.isEmpty ? a.isNative : (a.contract ?? '').toLowerCase() == contract)).firstOrNull;
    // TRON USDT/TRX are keyed by symbol
    asset ??= assets.where((a) => a.network == 'tron' && '${request['network']}' == 'tron' && a.symbol == '${request['symbol']}').firstOrNull;
    if (asset == null) {
      showInfo(context, 'This coin isn’t in your wallet. Add the token first.');
      return null;
    }
    to = '${request['to']}';
    amount = BigInt.tryParse('${request['amount']}');
    if (locked && asset.balance == null) {
      showInfo(context, 'Can’t reach the ${asset.networkName} network right now. Check your internet and try again.');
      return null;
    }
    if (locked && amount != null && asset.balance! < amount) {
      showInfo(context, 'Not enough ${asset.symbol} on ${asset.networkName} in your wallet. Add some (Wallet → Receive) and try again.');
      return null;
    }
  } else {
    Map<String, dynamic> shared = const {};
    if (peerUserId != null) {
      try {
        shared = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/users/$peerUserId/wallet') as Map);
      } catch (_) {}
    }
    if (!context.mounted) return null;
    var list = assets.where((a) => (a.balance ?? BigInt.zero) > BigInt.zero).toList()..sort((x, y) => y.value.compareTo(x.value));
    if (list.isEmpty) {
      showInfo(context, 'Your wallet is empty. Tap Receive in the wallet to add coins.');
      return null;
    }
    asset = await _pickAsset(context, list, title: 'Send which coin?');
    if (asset == null || !context.mounted) return null;
    to = shared[_familyOfAsset(asset)] as String?;
    if (to == null && peerName != null) {
      showInfo(context, '$peerName hasn’t shared a ${asset.networkName} address. Paste the address they gave you — or ask them to send you a request.');
    }
  }
  if (!context.mounted) return null;
  final feeAsset = assets.firstWhere((x) => x.network == asset!.network && x.isNative);
  return Navigator.push<Map<String, dynamic>>(
    context,
    MaterialPageRoute(
      builder: (_) => ChangeNotifierProvider.value(
        value: w,
        child: _SendScreen(asset: asset!, feeAsset: feeAsset, to: to, amount: amount, forChat: true, toName: peerName, locked: locked, onSent: onSent),
      ),
    ),
  );
}

/// "Ask for crypto" from a chat: pick a coin and an amount; returns the request card (kind: request) or null.
Future<Map<String, dynamic>?> walletRequestForChat(BuildContext context) async {
  final auth = context.read<AuthState>();
  if (!auth.feature('wallet')) {
    showInfo(context, 'The wallet is switched off for now');
    return null;
  }
  final w = WalletStore(auth.me?.id ?? 0);
  await w.load();
  if (!context.mounted) return null;
  if (!w.exists) {
    final ok = await confirm(context, 'Set up your wallet', 'To ask for crypto in chats, first create your own wallet. It takes a minute.', ok: 'Set up');
    if (ok && context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const WalletScreen()));
    return null;
  }
  final assets = Portfolio.build(tron: w.net, custom: w.customTokens);
  final a = await _pickAsset(context, assets, title: 'Ask for which coin?');
  if (a == null || !context.mounted) return null;
  final ctl = TextEditingController();
  final note = TextEditingController();
  final amount = await showDialog<BigInt>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final u = Units.parse(ctl.text, decimals: a.decimals);
        return AlertDialog(
          title: Text('Ask for ${a.symbol}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('on ${a.networkName}', style: const TextStyle(color: Brand.muted)),
            const SizedBox(height: 10),
            TextField(
              controller: ctl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              onChanged: (_) => set(() {}),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              decoration: InputDecoration(suffixText: a.symbol, hintText: '0'),
            ),
            const SizedBox(height: 8),
            TextField(controller: note, maxLength: 140, decoration: const InputDecoration(hintText: 'What for? (optional)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: u == null || u <= BigInt.zero ? null : () => Navigator.pop(ctx, u), child: const Text('Send request')),
          ],
        );
      },
    ),
  );
  if (amount == null) return null;
  return {
    'kind': 'request', 'network': a.network, 'symbol': a.symbol, 'amount': '$amount', 'decimals': a.decimals,
    'to': w.addressFor(a.network)!,
    if (a.contract != null) 'contract': a.contract,
    if (note.text.trim().isNotEmpty) 'note': note.text.trim(),
  };
}
