import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config.dart';
import 'core/services.dart';
import 'screens/auth_screens.dart';
import 'screens/chat_screen.dart';
import 'screens/folder_support_screens.dart';
import 'screens/home_screen.dart';
import 'state/auth_state.dart';
import 'state/chat_store.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final services = AppServices();
  final chats = ChatStore(services);
  final auth = AuthState(services, chats);
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
        ChangeNotifierProvider<ChatStore>.value(value: chats),
        ChangeNotifierProvider<AuthState>.value(value: auth),
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    if (state == AppLifecycleState.resumed) {
      store.setForeground(true);
      if (auth.status == AuthStatus.loggedIn && !services.socket.isConnected) {
        services.api.refreshTokens().then((_) => services.socket.connect()).catchError((_) {});
      }
      if (auth.status == AuthStatus.loggedIn) {
        store.loadStories().catchError((_) {});
        store.loadAnnouncements().catchError((_) {});
      }
    } else if (state == AppLifecycleState.paused) {
      store.setForeground(false);
    }
  }

  AuthStatus? _lastStatus;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    if (_lastStatus != null && _lastStatus != auth.status) {
      // Login state changed (e.g. logged out from another device): drop any pushed screens.
      WidgetsBinding.instance.addPostFrameCallback((_) => navigatorKey.currentState?.popUntil((r) => r.isFirst));
    }
    _lastStatus = auth.status;
    final Widget home = switch (auth.status) {
      AuthStatus.loading => const SplashScreen(),
      AuthStatus.loggedOut => const PhoneScreen(),
      AuthStatus.needsProfile => const ProfileSetupScreen(),
      AuthStatus.loggedIn => const HomeScreen(),
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
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2AABEE),
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      // Rebuilding the key resets navigation when the login state changes.
      home: KeyedSubtree(key: ValueKey(auth.status), child: home),
    );
  }
}
