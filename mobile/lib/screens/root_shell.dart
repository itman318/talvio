import 'voice_chat_screen.dart';
import '../core/battery.dart';
import '../core/notif_prefs.dart';
import '../core/keep_alive.dart';
import '../theme/brand.dart';
import '../widgets/avatar.dart';
import '../state/auth_state.dart';
import 'my_profile_screen.dart';
import '../core/proxy.dart';
import 'proxy_screen.dart';
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import '../core/chat_links.dart';
import 'package:provider/provider.dart';

import '../widgets/voice_mini_player.dart';
import 'chat_screen.dart';

import '../state/chat_store.dart';
import 'calls_screen.dart';
import 'home_screen.dart';
import 'notices_screen.dart';
import 'settings_screens.dart';
import 'qr_screens.dart';
import 'user_profile_screen.dart';

/// Main shell after login: Chats · Calls · Settings in a bottom bar (keeps each tab alive).
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _tab = 0;
  final _built = <int>{0};
  StreamSubscription<Uri>? _links;
  late final ChatStore _store = context.read<ChatStore>();

  /// A new Talvio notification while the app is open: a small banner with a "View" button.
  void _onNotice() {
    final n = _store.lastNotice.value;
    if (n == null || !mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 5),
      content: Row(children: [
        const Icon(Icons.notifications_active_rounded, color: Colors.white, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text('${n['title']}', maxLines: 2, overflow: TextOverflow.ellipsis)),
      ]),
      action: SnackBarAction(label: 'View', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NoticesScreen()))),
    ));
  }

  @override
  void initState() {
    super.initState();
    _store.lastNotice.addListener(_onNotice);
    // battery optimisation can delay notifications: explain once and offer to allow background running
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) BatteryGuard.maybePrompt(context);
    });
    if (KeepAlive.enabled) KeepAlive.apply();
    // talvio://u/<id> links (profile QR codes scanned with the phone camera)
    try {
      _links = AppLinks().uriLinkStream.listen((uri) {
        if (!mounted) return;
        final id = profileIdFromLink(uri.toString());
        if (id != null) Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfileScreen(userId: id)));
        final code = callCodeFromLink(uri.toString());
        if (code != null) openCallLink(context, code);
        if (parseChatLink(uri.toString()) != null) openChatLink(context, uri.toString());
        final proxy = ProxyServer.fromLink(uri.toString());
        if (proxy != null) confirmAddProxy(context, proxy);
      }, onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _store.lastNotice.removeListener(_onNotice);
    _links?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final np = context.watch<NotifPrefs>();
    final unread = context.select<ChatStore, int>((s) {
      final list = s.chats.where((c) => (np.badgeMuted || !c.isMuted) && !c.isRequest && !c.isLocked && c.unreadCount > 0);
      return np.badgeChats ? list.length : list.fold<int>(0, (a, c) => a + c.unreadCount);
    });
    Widget page(int i) {
      if (!_built.contains(i)) return const SizedBox.shrink();
      return switch (i) { 0 => const HomeScreen(), 1 => const CallsScreen(), 2 => const SettingsScreen(), _ => const MyProfileScreen() };
    }

    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = 0);
      },
      child: Scaffold(
        body: IndexedStack(index: _tab, children: [page(0), page(1), page(2), page(3)]),
        bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
          const VoiceChatMiniBar(),
          VoiceMiniPlayer(onOpen: (id) => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: id)))),
          DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6), width: 0.6)),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 16, offset: const Offset(0, -4))],
          ),
          child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() {
            _tab = i;
            _built.add(i);
          }),
          destinations: [
            NavigationDestination(
              icon: Badge(isLabelVisible: unread > 0, label: Text(unread > 99 ? '99+' : '$unread'), child: const Icon(Icons.chat_bubble_outline_rounded)),
              selectedIcon: Badge(isLabelVisible: unread > 0, label: Text(unread > 99 ? '99+' : '$unread'), child: const Icon(Icons.chat_bubble_rounded)),
              label: 'Chats',
            ),
            const NavigationDestination(icon: Icon(Icons.call_outlined), selectedIcon: Icon(Icons.call_rounded), label: 'Calls'),
            const NavigationDestination(icon: Icon(Icons.tune_rounded), selectedIcon: Icon(Icons.tune_rounded), label: 'Settings'),
            NavigationDestination(icon: _MeIcon(selected: false), selectedIcon: _MeIcon(selected: true), label: 'Profile'),
          ],
        ),
        ),
        ]),
      ),
    );
  }
}


/// My photo as the Profile tab icon.
class _MeIcon extends StatelessWidget {
  const _MeIcon({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthState>().me;
    if (me == null) return Icon(selected ? Icons.person_rounded : Icons.person_outline_rounded);
    return Container(
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(shape: BoxShape.circle, gradient: selected ? Brand.aurora : null),
      child: ClipOval(child: Avatar(id: me.id, name: me.name, url: me.avatarAbsolute, size: 24)),
    );
  }
}
