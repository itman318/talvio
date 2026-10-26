import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
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
        setState(() => _s = {'private': true, 'groups': true, 'channels': true, 'preview': true});
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
              SettingsGroup(title: 'This phone', children: [
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
