import 'dart:async';

import 'read_later_screen.dart';
import '../core/services.dart';
import '../core/socket_service.dart';
import 'coins_screen.dart' show CoinsScreen, fmtCoins;
import 'wallet_screen.dart' show WalletScreen;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/models.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/avatar.dart';
import '../widgets/premium.dart';
import '../widgets/celebration.dart';
import 'chat_screen.dart';
import 'premium_screens.dart';
import 'qr_screens.dart';
import 'settings_screens.dart';
import 'story_screens.dart' show HighlightsRow, MyHighlightsScreen;
import '../widgets/emoji_status.dart';

/// "Finish your profile": shown until photo, username, bio and birthday are set.
Widget _completeCard(BuildContext context, AppUser me, VoidCallback edit) {
  final steps = [
    (me.avatarUrl != null, 'Photo'),
    (me.username != null, 'Username'),
    (me.bio.isNotEmpty, 'Bio'),
    (me.birthday != null, 'Birthday'),
  ];
  final done = steps.where((s) => s.$1).length;
  if (done == steps.length) return const SizedBox.shrink();
  final dark = Theme.of(context).brightness == Brightness.dark;
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
    child: Material(
      color: dark ? const Color(0xFF181C30) : Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: edit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(children: [
            SizedBox(
              width: 46,
              height: 46,
              child: Stack(alignment: Alignment.center, children: [
                CircularProgressIndicator(
                  value: done / steps.length,
                  strokeWidth: 4.5,
                  backgroundColor: Brand.primary.withValues(alpha: 0.12),
                  valueColor: const AlwaysStoppedAnimation(Brand.primary),
                ),
                Text('$done/${steps.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
              ]),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Finish your profile', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 3),
                Text('Add: ${steps.where((s) => !s.$1).map((s) => s.$2).join(', ')}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Brand.muted, fontSize: 13)),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: Brand.muted),
          ]),
        ),
      ),
    ),
  );
}

/// Bottom-bar "Profile" tab: how others see me, with quick edit, share and my things.
class MyProfileScreen extends StatelessWidget {
  const MyProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthState>().me;
    if (me == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    final link = me.username == null ? null : '${AppConfig.serverUrl}/c/${me.username}';
    final top = MediaQuery.viewPaddingOf(context).top; // the tab bar may have removed padding.top
    return Scaffold(
      body: Stack(children: [
        ListView(padding: EdgeInsets.zero, children: [
        _Header(
          me: me,
          top: top,
          onEdit: () => go(const EditProfileScreen()),
          onQr: () => go(const MyQrScreen()),
          onSettings: () => go(const SettingsScreen()),
          onShare: () async {
            if (link == null) {
              showInfo(context, 'Set a username first (Edit → Username)');
              return;
            }
            await Clipboard.setData(ClipboardData(text: link));
            if (context.mounted) showInfo(context, 'Profile link copied');
          },
        ),
        HighlightsRow(key: ValueKey('hl${me.id}'), userId: me.id, mine: true, hideEmpty: true),
        _completeCard(context, me, () => go(const EditProfileScreen())),
        // contact details: one slim line each
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: _Card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if ((me.phone ?? '').isNotEmpty)
                _InfoRow(caption: 'Mobile', first: true, icon: Icons.phone_rounded, color: Brand.green, value: me.phone!, label: 'Who sees it', onTap: () => go(const PrivacyScreen())),
              if ((me.email ?? '').isNotEmpty) _InfoRow(first: (me.phone ?? '').isEmpty, caption: 'Email · only for login', icon: Icons.mail_rounded, color: const Color(0xFF3C83DE), value: me.email!, label: ''),
              _InfoRow(
                caption: 'Birthday',
                icon: Icons.cake_rounded,
                color: Brand.rose,
                value: me.birthday?.label ?? 'Add your birthday',
                label: me.birthday == null ? 'Add' : 'Edit',
                onTap: () => go(const EditProfileScreen()),
              ),
            ]),
          ),
        ),
        // my things: one plain list
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: _Card(
            child: Column(children: [
              _Line(
                first: true,
                icon: Icons.bookmark_outline_rounded,
                title: 'My Notes',
                onTap: () async {
                  try {
                    final chat = await context.read<ChatStore>().openPrivateWith(me.id);
                    if (context.mounted) go(ChatScreen(chatId: chat.id, initial: chat));
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
              _Line(icon: Icons.watch_later_outlined, title: 'Read later', onTap: () => go(const ReadLaterScreen())),
              _Line(icon: Icons.auto_awesome_outlined, title: 'Story highlights', onTap: () => go(const MyHighlightsScreen())),
            ]),
          ),
        ),
        const SizedBox(height: 24),
        ]),
        if (me.birthday?.isToday == true) const Positioned.fill(child: BirthdayCelebration()),
      ]),
    );
  }
}

/// A soft rounded card (the same look as the settings groups).
class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: dark ? BorderSide(color: Colors.white.withValues(alpha: 0.05)) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// One slim detail line: small coloured icon, the value, and what a tap does on the right.
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.caption, required this.icon, required this.color, required this.value, required this.label, this.onTap, this.first = false});
  final bool first;
  final String caption;
  final IconData icon;
  final Color color;
  final String value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (!first) Divider(height: 1, thickness: 0.7, indent: 16, color: dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFEDEFF5)),
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 1),
                Text(caption, style: const TextStyle(fontSize: 12.5, color: Brand.muted)),
              ]),
            ),
            const SizedBox(width: 8),
            if (onTap != null) Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Brand.primary)),
          ]),
        ),
      ),
    ]);
  }
}

/// Coins · Plus · Wallet at a glance, right under the name.
class _StatsStrip extends StatefulWidget {
  const _StatsStrip({required this.me, this.onCard = false, this.bare = false});
  final AppUser me;
  final bool bare; // inside a box that already has a fixed height
  final bool onCard; // drawn on the dark ID card (white text, no card of its own)

  @override
  State<_StatsStrip> createState() => _StatsStripState();
}

class _StatsStripState extends State<_StatsStrip> {
  static final Map<int, int> _lastCoins = {}; // shown at once on the next visit
  late int? _coins = _lastCoins[widget.me.id];
  StreamSubscription<SocketEvent>? _sub;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthState>();
    if (!auth.feature('coins')) return;
    final services = context.read<AppServices>();
    services.api.get('/coins').then((r) {
      final b = ((r as Map)['balance'] as num?)?.toInt();
      if (b != null) _set(b);
    }).catchError((_) {});
    _sub = services.socket.events.where((e) => e.name == 'coins:updated').listen((e) {
      final b = (e.data['balance'] as num?)?.toInt();
      if (b != null) _set(b);
    });
  }

  void _set(int b) {
    _lastCoins[widget.me.id] = b;
    if (mounted) setState(() => _coins = b);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    final tiles = <Widget>[
      if (auth.feature('coins'))
        _Stat(light: widget.onCard, icon: Icons.monetization_on_rounded, color: const Color(0xFFF5A623), value: _coins == null ? '—' : fmtCoins(_coins!), label: 'Coins', onTap: () => go(const CoinsScreen())),
      if (auth.feature('premium'))
        _Stat(
          light: widget.onCard,
          icon: Icons.workspace_premium_rounded,
          color: Brand.premium,
          value: widget.me.isPremium ? 'Active' : (auth.plusAvailable ? 'Get it' : 'Soon'),
          label: 'Plus',
          onTap: () => go(const PremiumScreen()),
        ),
      if (auth.feature('wallet'))
        _Stat(light: widget.onCard, icon: Icons.account_balance_wallet_rounded, color: const Color(0xFF12B89C), value: 'Open', label: 'Wallet', onTap: () => go(const WalletScreen())),
    ];
    if (tiles.isEmpty) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final line = widget.onCard ? Colors.white.withValues(alpha: 0.09) : (dark ? Colors.white.withValues(alpha: 0.07) : const Color(0xFFEDEFF5));
    final row = IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) VerticalDivider(width: 1, thickness: 1, indent: 12, endIndent: 12, color: line),
          Expanded(child: tiles[i]),
        ],
      ]),
    );
    if (widget.bare) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) VerticalDivider(width: 1, thickness: 1, indent: 16, endIndent: 16, color: line),
          Expanded(child: Center(child: tiles[i])),
        ],
      ]);
    }
    if (widget.onCard) return Material(color: Colors.transparent, child: row);
    return Padding(padding: const EdgeInsets.fromLTRB(16, 2, 16, 4), child: _Card(child: row));
  }
}

class _Stat extends StatelessWidget {
  const _Stat({this.light = false, required this.icon, required this.color, required this.value, required this.label, required this.onTap});
  final IconData icon;
  final Color color;
  final String value;
  final String label;
  final VoidCallback onTap;
  final bool light;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 12, 6, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, maxLines: 1, style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, letterSpacing: -0.3, color: light ? Colors.white : null, fontFeatures: const [FontFeature.tabularFigures()])),
          ),
          const SizedBox(height: 3),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13.5, color: color),
            const SizedBox(width: 4),
            Text(label, maxLines: 1, style: TextStyle(fontSize: 12.5, color: light ? Colors.white.withValues(alpha: 0.65) : Brand.muted, fontWeight: FontWeight.w600)),
          ]),
        ]),
      ),
    );
  }
}

/// The top of my profile: no cover and no effects — title, photo beside the name, bio, two calm buttons.
class _Header extends StatelessWidget {
  const _Header({required this.me, required this.top, required this.onEdit, required this.onQr, required this.onShare, required this.onSettings});
  final AppUser me;
  final double top;
  final VoidCallback onEdit, onQr, onShare, onSettings;

  /// A round action under the name: icon in a soft glass circle, label below.
  Widget _action(IconData icon, String label, VoidCallback onTap, {bool main = false}) => Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: main ? Colors.white : Colors.white.withValues(alpha: 0.12),
                  border: main ? null : Border.all(color: Colors.white.withValues(alpha: 0.16)),
                ),
                child: Icon(icon, size: 22, color: main ? const Color(0xFF151A2E) : Colors.white),
              ),
              const SizedBox(height: 7),
              Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.85))),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final url = me.avatarAbsolute;
    final plus = me.isPremium;
    // The whole top of the page is the "ID" area: deep ink, a soft glow, and the brand line at the bottom.
    // The stats card floats half over its lower edge.
    return Stack(clipBehavior: Clip.none, children: [
      Column(children: [
        Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF12152A), Color(0xFF1E1A48)]),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.35),
                    radius: 0.85,
                    colors: plus ? const [Color(0x55C9A45C), Color(0x00C9A45C)] : const [Color(0x667C5CFF), Color(0x007C5CFF)],
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(8, top + 2, 8, 50),
              child: Column(children: [
                Row(children: [
                  IconButton(tooltip: 'QR code', icon: const Icon(Icons.qr_code_2_rounded, color: Colors.white), onPressed: onQr),
                  const Expanded(child: Text('Profile', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700))),
                  IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined, color: Colors.white), onPressed: onSettings),
                ]),
                const SizedBox(height: 8),
                // photo with a thin ring (gold for Plus)
                GestureDetector(
                  onTap: url == null ? onEdit : () => showPhotoViewer(context, url, tag: 'avatar-${me.id}'),
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: plus ? Brand.plusGradient : const LinearGradient(colors: [Color(0xFF7C5CFF), Color(0xFF12B89C)]),
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF16193A)),
                      child: Hero(tag: 'avatar-${me.id}', child: ClipOval(child: Avatar(id: me.id, name: me.name, url: url, size: 96))),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Flexible(
                      child: Text(me.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                    ),
                    if (me.isVerified) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.verified_rounded, color: Color(0xFF9A82FF), size: 21)),
                    if (me.statusEmoji != null)
                      GestureDetector(onTap: () => showEmojiStatusPicker(context), child: Padding(padding: const EdgeInsets.only(left: 6), child: EmojiStatusBadge(me, size: 20, padLeft: 0)))
                    else if (plus)
                      const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.workspace_premium_rounded, color: Color(0xFFE6C987), size: 20)),
                  ]),
                ),
                const SizedBox(height: 5),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  GestureDetector(
                    onTap: me.username == null ? onEdit : null,
                    child: Text(me.username != null ? '@${me.username}' : 'Add a username',
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.7))),
                  ),
                  const SizedBox(width: 10),
                  const DecoratedBox(decoration: BoxDecoration(color: Color(0xFF3FE0C0), shape: BoxShape.circle), child: SizedBox(width: 7, height: 7)),
                  const SizedBox(width: 5),
                  const Text('online', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF3FE0C0))),
                ]),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
                  child: GestureDetector(
                    onTap: onEdit,
                    child: Text(me.bio.isEmpty ? '+ Add a short bio' : me.bio,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14.5, height: 1.4, color: Colors.white.withValues(alpha: me.bio.isEmpty ? 0.6 : 0.85), fontWeight: me.bio.isEmpty ? FontWeight.w600 : FontWeight.w400)),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(children: [
                    _action(Icons.edit_rounded, 'Edit', onEdit, main: true),
                    _action(Icons.ios_share_rounded, 'Share', onShare),
                    _action(Icons.qr_code_2_rounded, 'QR code', onQr),
                    _action(Icons.add_reaction_outlined, 'Status', () => showEmojiStatusPicker(context)),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 46),
      ]),
      // the stats float half over the bottom edge
      Positioned(
        left: 16,
        right: 16,
        bottom: 0,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          elevation: 3,
          shadowColor: Colors.black.withValues(alpha: 0.18),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Theme.of(context).brightness == Brightness.dark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.05)),
            ),
            height: 74,
            child: _StatsStrip(me: me, onCard: false, bare: true),
          ),
        ),
      ),
    ]);
  }
}

/// A plain line of the "my things" list: thin icon, title, arrow.
class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.title, required this.onTap, this.trailing, this.first = false});
  final IconData icon;
  final String title;
  final String? trailing;
  final VoidCallback onTap;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (!first) Divider(height: 1, thickness: 0.7, indent: 52, color: dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFEDEFF5)),
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(children: [
            Icon(icon, size: 22, color: Brand.primary),
            const SizedBox(width: 14),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600))),
            if (trailing != null) Text(trailing!, style: const TextStyle(fontSize: 15)),
            Icon(Icons.chevron_right_rounded, size: 21, color: scheme.onSurfaceVariant.withValues(alpha: 0.45)),
          ]),
        ),
      ),
    ]);
  }
}
