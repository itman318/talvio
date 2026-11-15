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
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      body: Stack(children: [
        ListView(padding: EdgeInsets.zero, children: [
        Stack(children: [
          ProfileHero(
            id: me.id,
            name: me.name,
            avatarUrl: me.avatarAbsolute,
            online: true,
            glow: me.isPremium,
            topPadding: top + 10,
            status: me.username != null ? '@${me.username}' : 'Add a username so people can find you',
            badges: [
              if (me.isVerified) const Icon(Icons.verified_rounded, color: Brand.primary, size: 22),
              GestureDetector(
                onTap: () => showEmojiStatusPicker(context),
                child: me.statusEmoji != null
                    ? EmojiStatusBadge(me, size: 21, padLeft: 0)
                    : Icon(me.isPremium ? Icons.star_rounded : Icons.add_reaction_outlined, color: me.isPremium ? Brand.premium : Colors.white70, size: 22),
              ),
            ],
            onAvatarTap: () => go(const EditProfileScreen()),
            actions: [
              ProfileAction(icon: Icons.edit_rounded, label: 'Edit', highlight: true, onTap: () => go(const EditProfileScreen())),
              ProfileAction(icon: Icons.qr_code_2_rounded, label: 'QR code', onTap: () => go(const MyQrScreen())),
              ProfileAction(
                icon: Icons.ios_share_rounded,
                label: 'Share',
                onTap: () async {
                  if (link == null) {
                    showInfo(context, 'Set a username first (Edit → Username)');
                    return;
                  }
                  await Clipboard.setData(ClipboardData(text: link));
                  if (context.mounted) showInfo(context, 'Profile link copied');
                },
              ),
            ],
          ),
          Positioned(
            right: 8,
            top: top + 4,
            child: IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_rounded, color: Colors.white),
              onPressed: () => go(const SettingsScreen()),
            ),
          ),
        ]),
        _StatsStrip(me: me),
        HighlightsRow(key: ValueKey('hl${me.id}'), userId: me.id, mine: true),
        _completeCard(context, me, () => go(const EditProfileScreen())),
        // about me: the bio as text, then one slim line per detail
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: _Card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              InkWell(
                onTap: () => go(const EditProfileScreen()),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('BIO', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.9, color: Brand.muted)),
                    const SizedBox(height: 4),
                    Text(me.bio.isEmpty ? 'Add a few words about you' : me.bio,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, height: 1.35, color: me.bio.isEmpty ? Brand.primary : null, fontWeight: me.bio.isEmpty ? FontWeight.w600 : FontWeight.w400)),
                  ]),
                ),
              ),
              if (me.username != null)
                _InfoRow(
                  icon: Icons.alternate_email_rounded,
                  color: Brand.primary,
                  value: me.username!,
                  label: 'Copy link',
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: link!));
                    if (context.mounted) showInfo(context, 'Profile link copied');
                  },
                ),
              if ((me.phone ?? '').isNotEmpty)
                _InfoRow(icon: Icons.phone_rounded, color: Brand.green, value: me.phone!, label: 'Who sees it', onTap: () => go(const PrivacyScreen())),
              if ((me.email ?? '').isNotEmpty) _InfoRow(icon: Icons.mail_rounded, color: const Color(0xFF3C83DE), value: me.email!, label: 'Login only'),
              _InfoRow(
                icon: Icons.cake_rounded,
                color: Brand.rose,
                value: me.birthday?.label ?? 'Add your birthday',
                label: me.birthday == null ? 'Add' : 'Birthday',
                onTap: () => go(const EditProfileScreen()),
              ),
            ]),
          ),
        ),
        // my things: four shortcuts instead of a long list
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Row(children: [
            Expanded(
              child: QuickTile(
                icon: Icons.bookmark_rounded,
                label: 'My Notes',
                color: Brand.violet,
                onTap: () async {
                  try {
                    final chat = await context.read<ChatStore>().openPrivateWith(me.id);
                    if (context.mounted) go(ChatScreen(chatId: chat.id, initial: chat));
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: QuickTile(icon: Icons.bookmarks_rounded, label: 'Read later', color: const Color(0xFF3C83DE), onTap: () => go(const ReadLaterScreen()))),
            const SizedBox(width: 8),
            Expanded(child: QuickTile(icon: Icons.auto_awesome_rounded, label: 'Highlights', color: Brand.amber, onTap: () => go(const MyHighlightsScreen()))),
            const SizedBox(width: 8),
            Expanded(child: QuickTile(icon: Icons.emoji_emotions_rounded, label: me.statusEmoji != null ? 'Status ${me.statusEmoji}' : 'Status', color: Brand.rose, onTap: () => showEmojiStatusPicker(context))),
          ]),
        ),
        SettingsGroup(children: [
          SettingsTile(icon: Icons.settings_rounded, color: const Color(0xFF5E6B8C), title: 'Settings', subtitle: 'Privacy, notifications, devices, theme and more', maxSubtitleLines: 1, onTap: () => go(const SettingsScreen())),
        ]),
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
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: dark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFE9ECF3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// One slim detail line: small coloured icon, the value, and what a tap does on the right.
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.color, required this.value, required this.label, this.onTap});
  final IconData icon;
  final Color color;
  final String value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Divider(height: 1, indent: 16, endIndent: 16, color: dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFEDEFF5)),
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
          child: Row(children: [
            Icon(icon, size: 19, color: color),
            const SizedBox(width: 12),
            Expanded(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: onTap == null ? Brand.muted : Brand.primary)),
          ]),
        ),
      ),
    ]);
  }
}

/// Coins · Plus · Wallet at a glance, right under the name.
class _StatsStrip extends StatefulWidget {
  const _StatsStrip({required this.me});
  final AppUser me;

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
        _Stat(icon: Icons.monetization_on_rounded, color: const Color(0xFFF5A623), value: _coins == null ? '—' : fmtCoins(_coins!), label: 'Coins', onTap: () => go(const CoinsScreen())),
      if (auth.feature('premium'))
        _Stat(
          icon: Icons.workspace_premium_rounded,
          color: Brand.premium,
          value: widget.me.isPremium ? 'Active' : (auth.plusAvailable ? 'Get it' : 'Soon'),
          label: 'Plus',
          onTap: () => go(const PremiumScreen()),
        ),
      if (auth.feature('wallet'))
        _Stat(icon: Icons.account_balance_wallet_rounded, color: const Color(0xFF12B89C), value: 'Open', label: 'Wallet', onTap: () => go(const WalletScreen())),
    ];
    if (tiles.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: tiles[i]),
        ],
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.color, required this.value, required this.label, required this.onTap});
  final IconData icon;
  final Color color;
  final String value;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: dark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFE9ECF3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 11, 8, 11),
          child: Row(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: color.withValues(alpha: dark ? 0.2 : 0.13), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 19),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value, maxLines: 1, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, letterSpacing: -0.2, fontFeatures: [FontFeature.tabularFigures()])),
                ),
                Text(label, maxLines: 1, style: const TextStyle(fontSize: 12, color: Brand.muted, fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
