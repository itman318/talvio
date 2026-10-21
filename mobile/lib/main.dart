import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config.dart';
import 'core/prefs.dart';
import 'core/services.dart';
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
  final prefs = AppPrefs();
  await prefs.load();
  final services = AppServices();
  final chats = ChatStore(services);
  final auth = AuthState(services, chats)..prefs = prefs;
  final calls = CallManager(services);
  calls.onShowCallScreen = () {
    navigatorKey.currentState?.push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CallScreen()));
  };
  final secrets = SecretStore(services);
  auth.onSessionCleared = () {
    calls.endLocal();
    secrets.wipeAll();
  };
  auth.onAccountSwitch = () {
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
