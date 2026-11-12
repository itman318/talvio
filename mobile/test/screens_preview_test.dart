// Renders real screens with pretend data to PNG files, so the look can be checked without a phone
// (CI saves them to the ci-logs branch, folder "screens").
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chatapp/core/api_client.dart';
import 'package:chatapp/core/services.dart';
import 'package:chatapp/core/socket_service.dart';
import 'package:chatapp/models/models.dart';
import 'package:chatapp/screens/coins_screen.dart';
import 'package:chatapp/screens/premium_screens.dart';
import 'package:chatapp/state/auth_state.dart';
import 'package:chatapp/state/chat_store.dart';
import 'package:chatapp/theme/brand.dart';
import 'package:chatapp/widgets/coin_cards.dart';

const _plans = [
  {'id': 1, 'name': '1 month', 'months': 1, 'price_text': r'$3.99', 'per_month_text': r'$3.99', 'price': 3.99, 'save_percent': 0, 'badge': null, 'usdt': 3.99},
  {'id': 2, 'name': '3 months', 'months': 3, 'price_text': r'$10.49', 'per_month_text': r'$3.50', 'price': 10.49, 'save_percent': 12, 'badge': 'Popular', 'usdt': 10.49},
  {'id': 3, 'name': '6 months', 'months': 6, 'price_text': r'$19.99', 'per_month_text': r'$3.33', 'price': 19.99, 'save_percent': 16, 'badge': null, 'usdt': 19.99},
  {'id': 4, 'name': '12 months', 'months': 12, 'price_text': r'$35.99', 'per_month_text': r'$3.00', 'price': 35.99, 'save_percent': 25, 'badge': 'Best value', 'usdt': 35.99},
];

final _answers = <String, Object?>{
  '/coins': {
    'balance': 2450,
    'packs': [
      {'id': 1, 'coins': 100, 'bonus': 0, 'total': 100, 'price_text': r'$0.99', 'badge': null},
      {'id': 2, 'coins': 500, 'bonus': 25, 'total': 525, 'price_text': r'$4.99', 'badge': null},
      {'id': 3, 'coins': 1000, 'bonus': 100, 'total': 1100, 'price_text': r'$9.99', 'badge': 'Popular'},
      {'id': 4, 'coins': 5000, 'bonus': 1000, 'total': 6000, 'price_text': r'$49.99', 'badge': 'Best value'},
    ],
    'crypto_networks': [{'id': 'bsc', 'name': 'BNB Smart Chain (BEP-20)', 'fee_hint': 'Lowest fee'}],
    'plus': [{'plan_id': 1, 'name': '1 month', 'months': 1, 'coins': 399}, {'plan_id': 4, 'name': '12 months', 'months': 12, 'coins': 3599}],
    'history': [
      {'id': 5, 'delta': 200, 'balance': 2450, 'kind': 'giveaway_win', 'note': 'Giveaway', 'peer': null, 'created_at': '2026-11-12T10:00:00Z'},
      {'id': 4, 'delta': -50, 'balance': 2250, 'kind': 'gift_sent', 'note': 'Cake', 'peer': {'id': 2, 'name': 'Hina Khan'}, 'created_at': '2026-11-12T09:00:00Z'},
      {'id': 3, 'delta': -100, 'balance': 2300, 'kind': 'tip_sent', 'note': 'Cricket News', 'peer': {'id': 3, 'name': 'Bilal'}, 'created_at': '2026-11-11T09:00:00Z'},
      {'id': 2, 'delta': -300, 'balance': 2400, 'kind': 'sub_paid', 'note': 'Hina Daily', 'peer': {'id': 2, 'name': 'Hina Khan'}, 'created_at': '2026-11-11T08:00:00Z'},
      {'id': 1, 'delta': 2900, 'balance': 2900, 'kind': 'purchase', 'note': null, 'peer': null, 'created_at': '2026-11-10T09:00:00Z'},
    ],
    'rules': 'Coins are for use inside Hushavia. They can’t be withdrawn or exchanged back for money.',
  },
  '/premium': {
    'is_premium': false, 'premium_until': null, 'sales_open': true, 'currency': 'USD', 'plans': _plans,
    'perks': [
      {'key': 'badge', 'title': 'Plus badge', 'text': 'A star next to your name'},
      {'key': 'uploads', 'title': 'Upload files up to 500 MB', 'text': 'Instead of 50 MB'},
      {'key': 'no_ads', 'title': 'No sponsored messages', 'text': 'No ads in channels'},
    ],
    'methods': [{'id': 'crypto', 'name': 'your wallet (USDT)'}],
    'crypto_networks': [{'id': 'bsc', 'name': 'BNB Smart Chain (BEP-20)'}],
    'coins': {'balance': 2450, 'prices': {'1': 399, '2': 1049, '3': 1999, '4': 3599}},
    'payments_note': null,
  },
  '/coins/gifts': [
    {'id': 'rose', 'name': 'Rose', 'emoji': '🌹', 'coins': 10}, {'id': 'chai', 'name': 'Cup of chai', 'emoji': '☕', 'coins': 25}, {'id': 'cake', 'name': 'Cake', 'emoji': '🎂', 'coins': 50},
    {'id': 'heart', 'name': 'Big heart', 'emoji': '💖', 'coins': 100}, {'id': 'teddy', 'name': 'Teddy bear', 'emoji': '🧸', 'coins': 200}, {'id': 'trophy', 'name': 'Trophy', 'emoji': '🏆', 'coins': 500},
    {'id': 'diamond', 'name': 'Diamond', 'emoji': '💎', 'coins': 1000}, {'id': 'crown', 'name': 'Crown', 'emoji': '👑', 'coins': 2500}, {'id': 'rocket', 'name': 'Rocket', 'emoji': '🚀', 'coins': 5000},
  ],
  '/coins/giveaways/7': {'id': 7, 'status': 'open', 'entries': 128, 'joined': false, 'ends_at': DateTime.now().add(const Duration(hours: 5, minutes: 12)).toIso8601String(), 'winner_list': []},
  '/coins/giveaways/8': {'id': 8, 'status': 'done', 'entries': 342, 'joined': true, 'ends_at': '2026-11-11T09:00:00Z', 'winner_list': [{'id': 1, 'name': 'Asad Ali', 'username': 'asad'}, {'id': 2, 'name': 'Hina Khan', 'username': null}]},
};

class _Api implements ApiClient {
  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async => _answers[path] ?? (throw ApiException(404, 'not_found', 'Not found'));
  @override
  Future<dynamic> post(String path, [Object? body]) async => <String, dynamic>{};
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Socket implements SocketService {
  @override
  Stream<SocketEvent> get events => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Services implements AppServices {
  @override
  final ApiClient api = _Api();
  @override
  SocketService get socket => _Socket();
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Auth extends ChangeNotifier implements AuthState {
  @override
  Map<String, dynamic> get appConfig => {'plus_available': true};
  @override
  AppUser? get me => null;
  @override
  bool feature(String key) => true;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Chats extends ChangeNotifier implements ChatStore {
  @override
  int? get myId => 1;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  var any = false;
  for (final f in files) {
    final file = File(f);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    any = true;
  }
  if (any) await loader.load();
}

Message _msg(int id, String type, Map<String, dynamic> meta, {int? sender}) =>
    Message(id: id, chatId: 5, senderId: sender, type: type, meta: meta, createdAt: DateTime(2026, 11, 12, 10));

void main() {
  testWidgets('render screens', (tester) async {
    final out = Directory(Platform.environment['SCREENS_OUT'] ?? 'build/screens')..createSync(recursive: true);
    SharedPreferences.setMockInitialValues({});
    final flutter = Platform.environment['FLUTTER_ROOT'] ?? '';
    await _font('Jakarta', [for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) 'assets/fonts/PlusJakartaSans-$w.ttf']);
    await _font('MaterialIcons', ['$flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
    await _font('Emoji', ['/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf']);
    tester.view.physicalSize = const Size(780, 1688); // a 390 × 844 phone at 2×
    tester.view.devicePixelRatio = 2;
    final shot = GlobalKey();

    Future<void> save(String name) async {
      await tester.runAsync(() async {
        final boundary = shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${out.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    Future<void> show(Widget screen, String name, {bool dark = false, Future<void> Function()? then}) async {
      final base = dark ? Brand.dark() : Brand.light();
      await tester.pumpWidget(RepaintBoundary(
        key: shot,
        child: MultiProvider(
          providers: [
            Provider<AppServices>.value(value: _Services()),
            ChangeNotifierProvider<AuthState>.value(value: _Auth()),
            ChangeNotifierProvider<ChatStore>.value(value: _Chats()),
          ],
          child: MaterialApp(
            key: ValueKey(name),
            debugShowCheckedModeBanner: false,
            theme: base.copyWith(textTheme: base.textTheme.apply(fontFamilyFallback: const ['Emoji'])),
            home: screen,
          ),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      if (then != null) await then();
      await save(name);
    }

    await show(const CoinsScreen(), 'coins');
    await show(const CoinsScreen(), 'coins-dark', dark: true);
    await show(const PremiumScreen(), 'plus');
    await show(const PremiumScreen(), 'plus-2', then: () async {
      await tester.drag(find.byType(ListView).first, const Offset(0, -520));
      await tester.pump(const Duration(milliseconds: 400));
    });

    Widget cards() => Scaffold(
          appBar: AppBar(title: const Text('Cards in a chat')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Align(alignment: Alignment.centerRight, child: GiftCard(isMine: true, message: _msg(1, 'gift', {'gift': {'name': 'Cake', 'emoji': '🎂', 'coins': 50, 'note': 'Happy birthday!'}}, sender: 1))),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerLeft, child: GiftCard(isMine: false, message: _msg(2, 'gift', {'gift': {'name': 'Diamond', 'emoji': '💎', 'coins': 1000}}, sender: 2))),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerLeft, child: GiveawayCard(message: _msg(3, 'giveaway', {'giveaway': {'id': 7, 'coins_each': 200, 'winners': 5, 'ends_at': DateTime.now().add(const Duration(hours: 5)).toIso8601String()}}))),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerLeft, child: GiveawayCard(message: _msg(4, 'giveaway', {'giveaway': {'id': 8, 'coins_each': 500, 'winners': 2, 'ends_at': '2026-11-11T09:00:00Z'}}))),
          ]),
        );
    await show(cards(), 'chat-cards');
    await show(cards(), 'chat-cards-dark', dark: true);

    Widget launcher(Future<void> Function(BuildContext) run) => Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => run(c), child: const Text('open')))));
    Future<void> open() async {
      await tester.tap(find.text('open'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    await show(launcher((c) => sendGiftFlow(c, 5, 'Hina')), 'gift-picker', then: open);
    await show(launcher((c) => giveawayFlow(c, 5)), 'giveaway-form', then: open);
    await show(launcher((c) => tipFlow(c, _msg(9, 'text', const {}))), 'tip-sheet', then: open);
  });
}
