// End-to-end run of the real app against a live backend (see .github/workflows/app-e2e.yml):
// login with the dev-mode OTP → profile → chats → open a chat → send a message → other tabs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chatapp/main.dart' as app;

const email = 'muhammad@talvio.test';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntil(WidgetTester t, Finder f, {int seconds = 30, String? what}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end)) {
      await t.pump(const Duration(milliseconds: 250));
      if (f.evaluate().isNotEmpty) return;
    }
    // show what is on screen instead
    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '').where((x) => x.isNotEmpty).take(40).join(' | ');
    debugPrint('ON SCREEN: $texts');
    try {
      await binding.takeScreenshot('zz-fail');
    } catch (_) {}
    throw TestFailure('Timed out waiting for ${what ?? f.toString()}');
  }

  Future<void> settle(WidgetTester t, [int ms = 1200]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  var shot = 0;
  Future<void> snap(WidgetTester t, String name) async {
    await settle(t, 800);
    shot++;
    final n = '${shot.toString().padLeft(2, '0')}-$name';
    if (shot == 1) await binding.convertFlutterSurfaceToImage();
    await t.pump();
    await binding.takeScreenshot(n);
    debugPrint('SCREENSHOT $n');
  }

  testWidgets('login → chats → send message → tabs', (t) async {
    app.main();
    await pumpUntil(t, find.text('Email address'), seconds: 60, what: 'login screen (email)');
    await snap(t, 'login');
    await t.tap(find.text('Phone'));
    await settle(t, 600);
    await snap(t, 'login-phone');
    await t.tap(find.text('Email'));
    await settle(t, 600);

    await t.enterText(find.widgetWithText(TextField, 'Email address'), email);
    await t.testTextInput.receiveAction(TextInputAction.go); // keyboard "Go" (the button can be under the keyboard)
    await pumpUntil(t, find.textContaining('Dev mode code:'), what: 'OTP screen with dev code');
    await snap(t, 'otp');
    final codeText = (find.textContaining('Dev mode code:').evaluate().first.widget as Text).data!;
    final code = codeText.split(':').last.trim();
    await t.enterText(find.byType(TextField).first, code);
    await settle(t);

    // New account → profile screen
    await pumpUntil(t, find.text('Your profile'), what: 'profile screen');
    await snap(t, 'profile');
    await t.enterText(find.widgetWithText(TextField, 'First name (required)'), 'Muhammad');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t, 800);
    await t.ensureVisible(find.text('Continue'));
    await t.tap(find.text('Continue'));

    await pumpUntil(t, find.text('Sana Ahmed'), seconds: 40, what: 'chat list with seeded chat');
    await snap(t, 'chats');

    await t.tap(find.text('Sana Ahmed'));
    await pumpUntil(t, find.text('Assalam o alaikum! App kaisi chal rahi hai?'), what: 'messages in chat');
    await snap(t, 'chat');

    await t.enterText(find.widgetWithText(TextField, 'Message'), 'Hello from the app ✅');
    await settle(t, 400);
    await t.tap(find.byTooltip('Send (hold to schedule)'));
    await pumpUntil(t, find.text('Hello from the app ✅'), what: 'sent message');
    await settle(t, 2500);
    await snap(t, 'chat-sent');

    await t.pageBack();
    await settle(t);
    await t.tap(find.text('Dev Team'));
    await pumpUntil(t, find.text('Launch kab karein?'), what: 'poll in group');
    await snap(t, 'group-poll');
    await t.pageBack();
    await settle(t);

    await t.tap(find.text('Calls'));
    await settle(t, 2500);
    await snap(t, 'calls');
    await t.tap(find.text('Settings'));
    await settle(t, 2500);
    await snap(t, 'settings');
    await t.tap(find.text('Chats'));
    await settle(t);

    await t.tap(find.byTooltip('New message'));
    await pumpUntil(t, find.text('New message'), what: 'new message screen');
    await snap(t, 'new-message');
    await t.tapAt(const Offset(20, 120)); // close the sheet
    await settle(t);

    // Same screens in dark mode (theme follows the system by default)
    t.binding.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await settle(t, 1500);
    await snap(t, 'chats-dark');
    await t.tap(find.text('Sana Ahmed'));
    await pumpUntil(t, find.text('Hello from the app ✅'), what: 'chat in dark mode');
    await snap(t, 'chat-dark');
    await t.pageBack();
    await settle(t);
    await t.tap(find.text('Dev Team'));
    await pumpUntil(t, find.text('Launch kab karein?'), what: 'group in dark mode');
    await snap(t, 'group-dark');
    await t.pageBack();
    await settle(t);
    await t.tap(find.text('Settings'));
    await settle(t, 2000);
    await snap(t, 'settings-dark');
    t.binding.platformDispatcher.clearPlatformBrightnessTestValue();
    await settle(t, 800);

    // ---- log out, then the offline demo account (no server involved)
    await t.scrollUntilVisible(find.text('Log out'), 300, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Log out'));
    await settle(t, 800);
    await t.tap(find.text('Log out').last);
    await pumpUntil(t, find.byKey(const ValueKey('demo-button')), what: 'login screen after logout');
    await snap(t, 'logged-out');
  });
}
