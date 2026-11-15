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
    final top = MediaQuery.of(context).padding.top;
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
        _StatsStrip(me: me),
        HighlightsRow(key: ValueKey('hl${me.id}'), userId: me.id, mine: true, hideEmpty: true),
        _completeCard(context, me, () => go(const EditProfileScreen())),
        // contact details: one slim line each
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: _Card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (me.username != null)
                _InfoRow(
                  first: true,
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
                _InfoRow(first: me.username == null, icon: Icons.phone_rounded, color: Brand.green, value: me.phone!, label: 'Who sees it', onTap: () => go(const PrivacyScreen())),
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
  const _InfoRow({required this.icon, required this.color, required this.value, required this.label, this.onTap, this.first = false});
  final bool first;
  final IconData icon;
  final Color color;
  final String value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (!first) Divider(height: 1, thickness: 0.7, indent: 47, color: dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFEDEFF5)),
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final line = dark ? Colors.white.withValues(alpha: 0.07) : const Color(0xFFEDEFF5);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: _Card(
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < tiles.length; i++) ...[
              if (i > 0) VerticalDivider(width: 1, thickness: 1, indent: 14, endIndent: 14, color: line),
              Expanded(child: tiles[i]),
            ],
          ]),
        ),
      ),
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
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 13, 6, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, maxLines: 1, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3, fontFeatures: [FontFeature.tabularFigures()])),
          ),
          const SizedBox(height: 3),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13.5, color: color),
            const SizedBox(width: 4),
            Text(label, maxLines: 1, style: const TextStyle(fontSize: 12.5, color: Brand.muted, fontWeight: FontWeight.w600)),
          ]),
        ]),
      ),
    );
  }
}

/// The top of my profile: a calm cover, the photo on its edge, then name, username and bio —
/// left-aligned like a business card, with the actions as slim buttons beside the photo.
class _Header extends StatelessWidget {
  const _Header({required this.me, required this.top, required this.onEdit, required this.onQr, required this.onShare, required this.onSettings});
  final AppUser me;
  final double top;
  final VoidCallback onEdit, onQr, onShare, onSettings;

  static const _avatar = 92.0;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final coverH = top + 118;
    final url = me.avatarAbsolute;

    Widget round(IconData icon, String tip, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Tooltip(
            message: tip,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              shape: CircleBorder(side: BorderSide(color: dark ? Colors.white.withValues(alpha: 0.10) : const Color(0xFFDFE3EE))),
              clipBehavior: Clip.antiAlias,
              child: InkWell(onTap: onTap, child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 19.5, color: Theme.of(context).colorScheme.onSurface))),
            ),
          ),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: coverH + _avatar / 2 + 4,
        child: Stack(clipBehavior: Clip.none, children: [
          // cover: brand ink to violet, with two soft lights (cheap to draw: no blur, no image)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: coverH,
            child: const RepaintBoundary(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1B1F3D), Color(0xFF3A2A9E), Color(0xFF6D4AFF)], stops: [0, 0.55, 1]),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(gradient: RadialGradient(center: Alignment(0.85, -0.9), radius: 1.1, colors: [Color(0x55FFFFFF), Color(0x00FFFFFF)])),
                  child: DecoratedBox(
                    decoration: BoxDecoration(gradient: RadialGradient(center: Alignment(-0.9, 1.2), radius: 0.9, colors: [Color(0x4012B89C), Color(0x0012B89C)])),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 20,
            top: top + 14,
            child: const Text('Profile', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          ),
          Positioned(
            right: 6,
            top: top + 4,
            child: IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined, color: Colors.white), onPressed: onSettings),
          ),
          // photo on the edge of the cover
          Positioned(
            left: 18,
            bottom: 0,
            child: GestureDetector(
              onTap: url == null ? onEdit : () => showPhotoViewer(context, url, tag: 'avatar-${me.id}'),
              child: Stack(clipBehavior: Clip.none, children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: me.isPremium ? null : bg,
                    gradient: me.isPremium ? Brand.plusGradient : null,
                    borderRadius: BorderRadius.circular((_avatar + 8) * 0.34),
                  ),
                  child: Hero(tag: 'avatar-${me.id}', child: Avatar(id: me.id, name: me.name, url: url, size: _avatar)),
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: GestureDetector(
                    onTap: onEdit,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(color: Brand.primary, shape: BoxShape.circle, border: Border.all(color: bg, width: 3)),
                      child: const Icon(Icons.photo_camera_rounded, size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ]),
            ),
          ),
          // actions beside the photo
          Positioned(
            right: 16,
            bottom: 2,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              FilledButton(
                onPressed: onEdit,
                style: FilledButton.styleFrom(
                  backgroundColor: Brand.primary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: const StadiumBorder(),
                  textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                child: const Text('Edit profile'),
              ),
              round(Icons.qr_code_2_rounded, 'QR code', onQr),
              round(Icons.ios_share_rounded, 'Share profile', onShare),
            ]),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(
              child: Text(me.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.15)),
            ),
            if (me.isVerified) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.verified_rounded, color: Brand.primary, size: 21)),
            if (me.isPremium) const Padding(padding: EdgeInsets.only(left: 5), child: Icon(Icons.workspace_premium_rounded, color: Brand.premium, size: 20)),
            if (me.statusEmoji != null)
              GestureDetector(onTap: () => showEmojiStatusPicker(context), child: Padding(padding: const EdgeInsets.only(left: 6), child: EmojiStatusBadge(me, size: 20, padLeft: 0))),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Flexible(
              child: GestureDetector(
                onTap: me.username == null ? onEdit : null,
                child: Text(me.username != null ? '@${me.username}' : 'Add a username',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: me.username != null ? Brand.muted : Brand.primary)),
              ),
            ),
            const SizedBox(width: 10),
            Container(width: 7, height: 7, decoration: const BoxDecoration(color: Brand.accent, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            const Text('online', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Brand.accent)),
          ]),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onEdit,
            child: Text(me.bio.isEmpty ? 'Add a short bio' : me.bio,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, height: 1.4, color: me.bio.isEmpty ? Brand.primary : null, fontWeight: me.bio.isEmpty ? FontWeight.w600 : FontWeight.w400)),
          ),
        ]),
      ),
    ]);
  }
}
