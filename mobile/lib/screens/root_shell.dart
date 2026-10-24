import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../widgets/voice_mini_player.dart';
import 'chat_screen.dart';

import '../state/chat_store.dart';
import 'calls_screen.dart';
import 'home_screen.dart';
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

  @override
  void initState() {
    super.initState();
    // talvio://u/<id> links (profile QR codes scanned with the phone camera)
    try {
      _links = AppLinks().uriLinkStream.listen((uri) {
        final id = profileIdFromLink(uri.toString());
        if (id != null && mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfileScreen(userId: id)));
      }, onError: (_) {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unread = context.select<ChatStore, int>((s) => s.chats.where((c) => !c.isMuted && !c.isRequest && !c.isLocked).fold<int>(0, (a, c) => a + c.unreadCount));
    Widget page(int i) {
      if (!_built.contains(i)) return const SizedBox.shrink();
      return switch (i) { 0 => const HomeScreen(), 1 => const CallsScreen(), _ => const SettingsScreen() };
    }

    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = 0);
      },
      child: Scaffold(
        body: IndexedStack(index: _tab, children: [page(0), page(1), page(2)]),
        bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
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
          ],
        ),
        ),
        ]),
      ),
    );
  }
}
