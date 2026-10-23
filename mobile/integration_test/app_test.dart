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

    await t.tap(find.byType(FloatingActionButton).first);
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
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t, 800);
    await t.ensureVisible(find.byKey(const ValueKey('demo-button')));
    await t.tap(find.byKey(const ValueKey('demo-button')));
    await pumpUntil(t, find.text('Ayesha Khan'), seconds: 30, what: 'demo chat list');
    await settle(t, 1500);
    await snap(t, 'demo-chats');
    await t.tap(find.text('Ayesha Khan'));
    await pumpUntil(t, find.text('Naran trip ki photo 🏔️'), what: 'demo chat with photo');
    await settle(t, 2500);
    await snap(t, 'demo-chat');
    await t.enterText(find.widgetWithText(TextField, 'Message'), 'Assalam o alaikum');
    await settle(t, 400);
    await t.tap(find.byTooltip('Send (hold to schedule)'));
    await pumpUntil(t, find.text('Walaikum assalam! 😊'), seconds: 15, what: 'demo auto-reply');
    await settle(t, 800);
    await snap(t, 'demo-reply');
    await t.pageBack();
    await settle(t);
    await t.tap(find.text('Family ❤️'));
    await pumpUntil(t, find.text('Sunday ko kya banayein?'), what: 'demo group with poll');
    await settle(t, 2500);
    await snap(t, 'demo-group');
    await t.pageBack();
    await settle(t);
    await t.tap(find.text('Settings'));
    await settle(t, 1500);
    await t.scrollUntilVisible(find.text('Prayer times'), 300, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Prayer times'));
    await pumpUntil(t, find.text('Choose a city'), what: 'prayer screen');
    await t.tap(find.text('Choose a city'));
    await settle(t, 1200);
    await t.scrollUntilVisible(find.text('Kot Addu'), 200, scrollable: find.byType(Scrollable).last);
    await t.tap(find.text('Kot Addu'));
    await pumpUntil(t, find.textContaining('Next:'), what: 'prayer times');
    await settle(t, 1200);
    await snap(t, 'demo-prayer');
  });
}
