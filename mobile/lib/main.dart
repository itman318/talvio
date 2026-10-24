import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config.dart';
import 'core/chat_lock.dart';
import 'core/crash_reporter.dart';
import 'core/prefs.dart';
import 'core/prayer_reminders.dart';
import 'core/message_notifications.dart';
import 'core/services.dart';
import 'core/voice_playback.dart';
import 'screens/more_screens.dart';
import 'screens/auth_screens.dart';
import 'screens/call_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/folder_support_screens.dart';
import 'screens/root_shell.dart';
import 'state/auth_state.dart';
import 'state/call_manager.dart';
import 'state/chat_store.dart';
import 'state/secret_store.dart';
import 'theme/brand.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  CrashReporter.install();
  try {
    await _start();
  } catch (e, st) {
    CrashReporter.report(e, st, context: 'startup');
    // Never leave the user on the launch screen: show what went wrong instead.
    debugPrint('Startup failed: $e\n$st');
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(24), children: [
            const Text('Talvio could not start', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            SelectableText('$e\n\n$st', style: const TextStyle(fontSize: 12)),
          ]),
        ),
      ),
    ));
  }
}

Future<void> _start() async {
  final prefs = AppPrefs();
  try {
    await prefs.load().timeout(const Duration(seconds: 5));
  } catch (e) {
    debugPrint('Prefs not loaded: $e');
  }
  final services = AppServices();
  CrashReporter.tokenProvider = () => services.api.accessToken;
  final chats = ChatStore(services);
  final auth = AuthState(services, chats)..prefs = prefs;
  final calls = CallManager(services);
  calls.lowData = prefs.dataSaver;
  // keeps the 7-day window of prayer reminders topped up
  if (prefs.prayerReminders || prefs.ramadanReminders) unawaited(PrayerReminders.reschedule(prefs));
  prefs.addListener(() => calls.lowData = prefs.dataSaver);
  calls.onShowCallScreen = () {
    navigatorKey.currentState?.push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CallScreen()));
  };
  final secrets = SecretStore(services);
  // drafts follow me to my other devices
  chats.onDraftSynced = (chatId, text, live) {
    final local = prefs.draft(chatId) ?? '';
    if (live || local.trim().isEmpty) prefs.setDraft(chatId, text);
  };
  final voice = VoicePlayback(services)
    ..messagesOf = chats.messagesOf
    ..myId = (() => chats.myId);
  auth.onSessionCleared = () {
    voice.stop();
    calls.endLocal();
    secrets.wipeAll();
  };
  auth.onAccountSwitch = () {
    voice.stop();
    calls.endLocal();
    secrets.suspend();
  };
  services.push.onOpenCall = () {
    if (auth.status == AuthStatus.loggedIn) calls.checkActive();
  };
  services.push.onOpenChat = (chatId) {
    if (auth.status != AuthStatus.loggedIn) return;
    navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));
  };
  // our own message notifications (Reply / Mark as read): tapping one opens the chat
  MessageNotifications.onOpenChat = (chatId) {
    if (auth.status == AuthStatus.loggedIn) {
      navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));
    } else {
      // still starting up: wait for the session
      void wait() {
        if (auth.status == AuthStatus.loggedIn) {
          auth.removeListener(wait);
          navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));
        }
      }
      auth.addListener(wait);
    }
  };
  unawaited(MessageNotifications.handleLaunch());
  services.push.onOpenSupport = () {
    if (auth.status != AuthStatus.loggedIn) return;
    navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => const SupportListScreen()));
  };
  auth.init();

  runApp(
    MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider<AppPrefs>.value(value: prefs),
        ChangeNotifierProvider<ChatStore>.value(value: chats),
        ChangeNotifierProvider<AuthState>.value(value: auth),
        ChangeNotifierProvider<CallManager>.value(value: calls),
        ChangeNotifierProvider<SecretStore>.value(value: secrets),
        ChangeNotifierProvider<VoicePlayback>.value(value: voice),
      ],
      child: const ChatApp(),
    ),
  );
}

class ChatApp extends StatefulWidget {
  const ChatApp({super.key});

  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> with WidgetsBindingObserver {
  late bool _locked;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _locked = context.read<AppPrefs>().lockEnabled; // lock on cold start
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final store = context.read<ChatStore>();
    final services = context.read<AppServices>();
    final auth = context.read<AuthState>();
    final prefs = context.read<AppPrefs>();
    if (state == AppLifecycleState.resumed) {
      final pausedAt = _pausedAt;
      _pausedAt = null;
      // locked chats lock again after the app was in the background for a while
      if (pausedAt != null && DateTime.now().difference(pausedAt) > const Duration(seconds: 30)) ChatLock.close();
      if (pausedAt != null && prefs.lockEnabled && !_locked && DateTime.now().difference(pausedAt) >= Duration(minutes: prefs.lockAfterMinutes)) {
        setState(() => _locked = true);
      }
      store.setForeground(true);
      if (auth.status == AuthStatus.loggedIn && !services.socket.isConnected) {
        services.api.refreshTokens().then((_) => services.socket.connect()).catchError((_) {});
      }
      if (auth.status == AuthStatus.loggedIn) {
        context.read<CallManager>().checkActive();
        store.loadStories().catchError((_) {});
        store.loadAnnouncements().catchError((_) {});
      }
    } else if (state == AppLifecycleState.paused) {
      store.setForeground(false);
      // Not while the lock screen is up: the fingerprint prompt itself pauses the app on some phones.
      if (!_locked) _pausedAt = DateTime.now();
    }
  }

  AuthStatus? _lastStatus;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final prefs = context.watch<AppPrefs>();
    if (_lastStatus != auth.status && auth.status == AuthStatus.loggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.read<CallManager>().checkActive();
        final meId = context.read<AuthState>().me?.id;
        if (meId != null) context.read<SecretStore>().start(meId);
      });
    }
    if (_lastStatus != null && _lastStatus != auth.status) {
      // Login state changed (e.g. logged out from another device): drop any pushed screens.
      WidgetsBinding.instance.addPostFrameCallback((_) => navigatorKey.currentState?.popUntil((r) => r.isFirst));
    }
    _lastStatus = auth.status;
    final Widget home = switch (auth.status) {
      AuthStatus.loading => const SplashScreen(),
      AuthStatus.loggedOut => const PhoneScreen(),
      AuthStatus.needsProfile => const ProfileSetupScreen(),
      AuthStatus.loggedIn => const RootShell(),
      AuthStatus.maintenance => MessageScreen(
          icon: Icons.build_circle_outlined,
          title: 'Under maintenance',
          body: '${auth.appConfig['maintenance_message'] ?? 'Please try again soon.'}',
          action: FilledButton(onPressed: auth.init, child: const Text('Try again')),
        ),
      AuthStatus.updateRequired => const MessageScreen(
          icon: Icons.system_update,
          title: 'Update required',
          body: 'This version of the app is no longer supported. Please update it from the Play Store / App Store.',
        ),
    };

    return MaterialApp(
      title: AppConfig.appName,
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: Brand.light(),
      darkTheme: Brand.dark(),
      themeMode: prefs.themeMode,
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final scaled = MediaQuery(data: mq.copyWith(textScaler: TextScaler.linear(prefs.textScale)), child: child ?? const SizedBox());
        final showLock = _locked && prefs.lockEnabled && auth.status == AuthStatus.loggedIn;
        return Stack(textDirection: TextDirection.ltr, children: [
          scaled,
          if (showLock) Positioned.fill(child: LockScreen(onUnlocked: () => setState(() => _locked = false))),
        ]);
      },
      // Rebuilding the key resets navigation when the login state changes.
      home: KeyedSubtree(key: ValueKey(auth.status), child: home),
    );
  }
}
