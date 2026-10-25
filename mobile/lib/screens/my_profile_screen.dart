import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../state/auth_state.dart';
import '../state/chat_store.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/premium.dart';
import 'chat_screen.dart';
import 'premium_screens.dart';
import 'qr_screens.dart';
import 'settings_screens.dart';
import 'story_screens.dart' show HighlightsRow, MyHighlightsScreen;

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
      body: ListView(padding: EdgeInsets.zero, children: [
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
          if ((me.phone ?? '').isNotEmpty) SettingsTile(icon: Icons.phone_rounded, color: Brand.green, title: me.phone!, subtitle: 'Phone'),
          if ((me.email ?? '').isNotEmpty) SettingsTile(icon: Icons.mail_rounded, color: const Color(0xFF3C83DE), title: me.email!, subtitle: 'Email'),
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
          SettingsTile(icon: Icons.auto_awesome_rounded, color: Brand.amber, title: 'Story highlights', onTap: () => go(const MyHighlightsScreen())),
          SettingsTile(
            icon: Icons.star_rounded,
            color: Brand.premium,
            title: me.isPremium ? 'Talvio Plus — active' : 'Get Talvio Plus',
            subtitle: me.isPremium ? 'Thank you for your support' : 'Animated stickers, themes, no ads and more',
            onTap: () => go(const PremiumScreen()),
          ),
          SettingsTile(icon: Icons.lock_rounded, color: Brand.green, title: 'Privacy & security', onTap: () => go(const PrivacyScreen())),
        ]),
        const SizedBox(height: 24),
      ]),
    );
  }
}
