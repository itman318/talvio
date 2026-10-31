import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/battery.dart';
import '../core/notif_prefs.dart';
import '../core/keep_alive.dart';
import '../core/services.dart';
import '../theme/brand.dart';
import '../utils/format.dart';
import '../widgets/premium.dart';

/// Settings → Notifications. What gets a notification is kept on the server (it decides what to push);
/// sound and vibration are this phone's choice.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  Map<String, bool>? _s;
  bool _sound = true;
  bool _vibrate = true;
  bool _batteryRestricted = false;

  @override
  void initState() {
    super.initState();
    _load();
    BatteryGuard.restricted().then((v) {
      if (mounted) setState(() => _batteryRestricted = v);
    });
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _sound = p.getBool('notif_sound') ?? true;
    _vibrate = p.getBool('notif_vibrate') ?? true;
    if (!mounted) return;
    try {
      final r = Map<String, dynamic>.from(await context.read<AppServices>().api.get('/me/notifications') as Map);
      if (mounted) setState(() => _s = r.map((k, v) => MapEntry(k, v != false)));
    } catch (e) {
      if (mounted) {
        setState(() => _s = {'private': true, 'groups': true, 'channels': true, 'preview': true, 'reactions': true, 'pinned': true, 'contact_joined': true});
        showError(context, e);
      }
    }
  }

  Future<void> _set(String key, bool v) async {
    final before = Map<String, bool>.from(_s!);
    setState(() => _s![key] = v);
    try {
      await context.read<AppServices>().api.put('/me/notifications', {key: v});
    } catch (e) {
      if (mounted) {
        setState(() => _s = before);
        showError(context, e);
      }
    }
  }

  Future<void> _local(String key, bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(key, v);
    setState(() {
      if (key == 'notif_sound') _sound = v;
      if (key == 'notif_vibrate') _vibrate = v;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final np = context.watch<NotifPrefs>();
    bool on(String k) => s?[k] ?? true;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.only(bottom: 28), children: [
              SettingsGroup(title: 'Notify me about', children: [
                SettingsSwitchTile(
                  icon: Icons.person_rounded,
                  color: Brand.sky,
                  title: 'Private chats',
                  subtitle: 'Messages sent only to you',
                  value: s['private']!,
                  onChanged: (v) => _set('private', v),
                ),
                SettingsSwitchTile(
                  icon: Icons.groups_rounded,
                  color: Brand.green,
                  title: 'Groups',
                  subtitle: 'You still hear about @mentions and replies',
                  value: s['groups']!,
                  onChanged: (v) => _set('groups', v),
                ),
                SettingsSwitchTile(
                  icon: Icons.campaign_rounded,
                  color: Brand.amber,
                  title: 'Channels',
                  subtitle: 'New posts in channels you follow',
                  value: s['channels']!,
                  onChanged: (v) => _set('channels', v),
                ),
                SettingsSwitchTile(
                  icon: Icons.favorite_rounded,
                  color: Brand.rose,
                  title: 'Reactions',
                  subtitle: 'When someone reacts to your message',
                  value: on('reactions'),
                  onChanged: (v) => _set('reactions', v),
                ),
                SettingsSwitchTile(
                  icon: Icons.push_pin_rounded,
                  color: Brand.violet,
                  title: 'Pinned messages',
                  subtitle: 'When an admin pins something in your groups',
                  value: on('pinned'),
                  onChanged: (v) => _set('pinned', v),
                ),
                SettingsSwitchTile(
                  icon: Icons.person_add_alt_1_rounded,
                  color: Brand.green,
                  title: 'Contact joined Talvio',
                  subtitle: 'Someone from your phone book signs up',
                  value: on('contact_joined'),
                  onChanged: (v) => _set('contact_joined', v),
                ),
              ]),
              SettingsGroup(title: 'On the lock screen', children: [
                SettingsSwitchTile(
                  icon: Icons.notes_rounded,
                  color: Brand.violet,
                  title: 'Show message text',
                  subtitle: s['preview']! ? 'Name and message are shown' : 'Only “New message” and the name',
                  value: s['preview']!,
                  onChanged: (v) => _set('preview', v),
                ),
              ]),
              if (_batteryRestricted)
                SettingsGroup(children: [
                  SettingsTile(
                    icon: Icons.battery_alert_rounded,
                    color: Brand.amber,
                    title: 'Notifications may be delayed',
                    subtitle: 'Tap to let Talvio run in the background',
                    onTap: () async {
                      await BatteryGuard.ask();
                      await Future<void>.delayed(const Duration(seconds: 2));
                      final v = await BatteryGuard.restricted();
                      if (mounted) setState(() => _batteryRestricted = v);
                    },
                  ),
                ]),
              SettingsGroup(title: 'While Talvio is open', children: [
                SettingsSwitchTile(
                  icon: Icons.web_asset_rounded,
                  color: Brand.sky,
                  title: 'Pop-up banner',
                  subtitle: 'Small card on top for messages in other chats',
                  value: np.inAppBanner,
                  onChanged: (v) => np.set('inapp_banner', v),
                ),
                SettingsSwitchTile(
                  icon: Icons.music_note_rounded,
                  color: Brand.rose,
                  title: 'In-app sound',
                  value: np.inAppSound,
                  onChanged: (v) => np.set('inapp_sound', v),
                ),
                SettingsSwitchTile(
                  icon: Icons.vibration_rounded,
                  color: Brand.primary,
                  title: 'In-app vibrate',
                  value: np.inAppVibrate,
                  onChanged: (v) => np.set('inapp_vibrate', v),
                ),
              ]),
              SettingsGroup(title: 'Calls', children: [
                SettingsSwitchTile(
                  icon: Icons.ring_volume_rounded,
                  color: Brand.green,
                  title: 'Ringtone',
                  subtitle: np.callRing ? 'Your phone’s ringtone' : 'Silent — the call screen still shows',
                  value: np.callRing,
                  onChanged: (v) => np.set('call_ring', v),
                ),
                SettingsSwitchTile(
                  icon: Icons.vibration_rounded,
                  color: Brand.amber,
                  title: 'Vibrate on calls',
                  value: np.callVibrate,
                  onChanged: (v) => np.set('call_vibrate', v),
                ),
              ]),
              SettingsGroup(title: 'Unread badge', children: [
                SettingsSwitchTile(
                  icon: Icons.notifications_off_rounded,
                  color: Brand.muted,
                  title: 'Include muted chats',
                  value: np.badgeMuted,
                  onChanged: (v) => np.set('badge_muted', v),
                ),
                SettingsSwitchTile(
                  icon: Icons.forum_rounded,
                  color: Brand.violet,
                  title: 'Count chats, not messages',
                  subtitle: np.badgeChats ? '3 chats with new messages → 3' : 'Every unread message is counted',
                  value: np.badgeChats,
                  onChanged: (v) => np.set('badge_chats', v),
                ),
              ]),
              SettingsGroup(title: 'Reliability', children: [
                SettingsSwitchTile(
                  icon: Icons.bolt_rounded,
                  color: Brand.amber,
                  title: 'Keep-Alive',
                  subtitle: KeepAlive.enabled
                      ? 'On — Talvio stays connected (a small “Talvio” note stays in the status bar)'
                      : 'Turn on if messages arrive late or only when you open the app',
                  value: KeepAlive.enabled,
                  onChanged: (v) async {
                    await KeepAlive.setEnabled(v);
                    if (v && await BatteryGuard.restricted()) await BatteryGuard.ask();
                    if (mounted) setState(() {});
                  },
                ),
              ]),
              SettingsGroup(title: 'Notification sound', children: [
                SettingsSwitchTile(
                  icon: Icons.volume_up_rounded,
                  color: Brand.rose,
                  title: 'Sound',
                  value: _sound,
                  onChanged: (v) => _local('notif_sound', v),
                ),
                SettingsSwitchTile(
                  icon: Icons.vibration_rounded,
                  color: Brand.primary,
                  title: 'Vibrate',
                  value: _vibrate,
                  onChanged: (v) => _local('notif_vibrate', v),
                ),
              ]),
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 2, 22, 0),
                child: Text('To silence one chat, open it and tap Mute. Locked chats always show only “New message”.',
                    style: TextStyle(color: Brand.muted, fontSize: 12.5, height: 1.35)),
              ),
            ]),
    );
  }
}
