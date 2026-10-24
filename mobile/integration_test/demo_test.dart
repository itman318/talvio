// Offline demo account (run separately from app_test.dart so each emulator run stays short).
// End-to-end run of the real app against a live backend (see .github/workflows/app-e2e.yml):
// login with the dev-mode OTP → profile → chats → open a chat → send a message → other tabs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chatapp/main.dart' as app;

const email = 'muhammad@talvio.test';

bool _converted = false;

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

  var shot = 16;
  Future<void> snap(WidgetTester t, String name) async {
    await settle(t, 800);
    shot++;
    final n = '${shot.toString().padLeft(2, '0')}-$name';
    if (!_converted) {
      _converted = true;
      await binding.convertFlutterSurfaceToImage();
    }
    await t.pump();
    await binding.takeScreenshot(n);
    debugPrint('SCREENSHOT $n');
  }

  testWidgets('demo account: chats, reply, emoji, themes, media, group, prayer times', (t) async {
    app.main();
    await pumpUntil(t, find.byKey(const ValueKey('demo-button')), seconds: 60, what: 'login screen');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t, 800);
    await t.ensureVisible(find.byKey(const ValueKey('demo-button')));
    await t.tap(find.byKey(const ValueKey('demo-button')));
    await pumpUntil(t, find.text('Omar Hassan'), seconds: 30, what: 'demo chat list');
    await settle(t, 1500);
    await snap(t, 'demo-chats');
    for (var i = 0; i < 4 && find.text('Sarah Miller').hitTestable().evaluate().isEmpty; i++) {
      await t.dragFrom(const Offset(160, 420), const Offset(0, -250));
      await settle(t, 600);
    }
    await t.tap(find.text('Sarah Miller'));
    await pumpUntil(t, find.text('From our mountain trip 🏔️'), what: 'demo chat with photo');
    await settle(t, 2500);
    await snap(t, 'demo-chat');
    await t.enterText(find.widgetWithText(TextField, 'Message'), 'Hello there');
    await settle(t, 400);
    await t.tap(find.byTooltip('Send (hold to schedule)'));
    await pumpUntil(t, find.text('Hey! 👋 How are you?'), seconds: 15, what: 'demo auto-reply');
    await settle(t, 800);
    await snap(t, 'demo-reply');
    // emoji panel (Tali emoji + full emoji keyboard)
    await t.tap(find.byTooltip('Emoji, stickers & GIFs'));
    await settle(t, 1500);
    await snap(t, 'demo-emoji');
    await t.tap(find.byTooltip('Keyboard'));
    await settle(t, 600);
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t, 600);
    // theme & wallpaper
    await t.tap(find.byType(PopupMenuButton<String>).last);
    await settle(t, 800);
    await t.tap(find.text('Theme & wallpaper'));
    await pumpUntil(t, find.text('Ocean'), what: 'theme screen');
    await t.tap(find.text('Ocean'));
    await settle(t, 1200);
    await snap(t, 'demo-theme');
    await t.pageBack();
    await settle(t, 1500);
    await snap(t, 'demo-chat-ocean');
    // shared media
    await t.tap(find.byType(PopupMenuButton<String>).last);
    await settle(t, 800);
    await t.tap(find.text('Shared media'));
    await settle(t, 2500);
    await snap(t, 'demo-media');
    await t.pageBack();
    await settle(t);
    await t.pageBack();
    await settle(t);
    await t.dragFrom(const Offset(160, 250), const Offset(0, 500));
    await settle(t, 800);
    await t.tap(find.text('Family ❤️'));
    await pumpUntil(t, find.text('What should we cook on Sunday?'), what: 'demo group with poll');
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
    await t.scrollUntilVisible(find.text('Dubai'), 200, scrollable: find.byType(Scrollable).last);
    await t.tap(find.text('Dubai'));
    await pumpUntil(t, find.textContaining('Next:'), what: 'prayer times');
    await settle(t, 1200);
    await snap(t, 'demo-prayer');
  });
}
