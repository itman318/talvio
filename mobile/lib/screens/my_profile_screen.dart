import 'read_later_screen.dart';
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
import 'notifications_screen.dart';
import 'story_screens.dart' show HighlightsRow, MyHighlightsScreen;

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
              if (me.isPremium) const Icon(Icons.star_rounded, color: Brand.premium, size: 22),
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
        HighlightsRow(key: ValueKey('hl${me.id}'), userId: me.id, mine: true),
        _completeCard(context, me, () => go(const EditProfileScreen())),
        SettingsGroup(title: 'About me', children: [
          SettingsTile(
            icon: Icons.notes_rounded,
            color: Brand.sky,
            title: me.bio.isEmpty ? 'Add a bio' : me.bio,
            subtitle: me.bio.isEmpty ? 'A few words about you' : 'Bio',
            maxSubtitleLines: 1,
            onTap: () => go(const EditProfileScreen()),
          ),
          if (me.username != null)
            SettingsTile(
              icon: Icons.alternate_email_rounded,
              color: Brand.primary,
              title: '@${me.username}',
              subtitle: 'Username · tap to copy link',
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: link!));
                if (context.mounted) showInfo(context, 'Profile link copied');
              },
            ),
          if ((me.phone ?? '').isNotEmpty)
            SettingsTile(
              icon: Icons.phone_rounded,
              color: Brand.green,
              title: me.phone!,
              subtitle: 'Phone · only people you allow see it',
              onTap: () => go(const PrivacyScreen()),
            ),
          if ((me.email ?? '').isNotEmpty) SettingsTile(icon: Icons.mail_rounded, color: const Color(0xFF3C83DE), title: me.email!, subtitle: 'Email · for login, never shown'),
          SettingsTile(
            icon: Icons.cake_rounded,
            color: Brand.rose,
            title: me.birthday?.label ?? 'Add your birthday',
            subtitle: 'Birthday',
            onTap: () => go(const EditProfileScreen()),
          ),
        ]),
        SettingsGroup(title: 'My things', children: [
          SettingsTile(
            icon: Icons.bookmark_rounded,
            color: Brand.violet,
            title: 'My Notes',
            subtitle: 'Saved messages, links and files',
            onTap: () async {
              try {
                final chat = await context.read<ChatStore>().openPrivateWith(me.id);
                if (context.mounted) go(ChatScreen(chatId: chat.id, initial: chat));
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
          SettingsTile(icon: Icons.bookmarks_rounded, color: const Color(0xFF3C83DE), title: 'Read later', subtitle: 'Saved messages to come back to', onTap: () => go(const ReadLaterScreen())),
          SettingsTile(icon: Icons.auto_awesome_rounded, color: Brand.amber, title: 'Story highlights', onTap: () => go(const MyHighlightsScreen())),
          SettingsTile(
            icon: Icons.star_rounded,
            color: Brand.premium,
            title: me.isPremium ? 'Talvio Plus — active' : 'Talvio Plus',
            subtitle: me.isPremium
                ? 'Thank you for your support'
                : (context.read<AuthState>().plusAvailable ? 'Animated stickers, themes, no ads and more' : 'Coming soon · stickers, themes, no ads'),
            onTap: () => go(const PremiumScreen()),
          ),
        ]),
        SettingsGroup(title: 'Account', children: [
          SettingsTile(icon: Icons.lock_rounded, color: Brand.green, title: 'Privacy', subtitle: 'Who sees your phone, photo and last seen', onTap: () => go(const PrivacyScreen())),
          SettingsTile(icon: Icons.notifications_rounded, color: const Color(0xFFE5484D), title: 'Notifications', onTap: () => go(const NotificationsScreen())),
          SettingsTile(icon: Icons.devices_rounded, color: Brand.sky, title: 'Devices', subtitle: 'Where you are logged in', onTap: () => go(const SessionsScreen())),
          SettingsTile(icon: Icons.settings_rounded, color: const Color(0xFF5E6B8C), title: 'All settings', onTap: () => go(const SettingsScreen())),
        ]),
        const SizedBox(height: 24),
        ]),
        if (me.birthday?.isToday == true) const Positioned.fill(child: BirthdayCelebration()),
      ]),
    );
  }
}
