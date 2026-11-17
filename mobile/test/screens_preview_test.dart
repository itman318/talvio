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
import 'package:chatapp/core/accounts.dart';
import 'package:chatapp/core/proxy.dart';
import 'package:chatapp/screens/coins_screen.dart';
import 'package:chatapp/core/prefs.dart';
import 'package:chatapp/screens/home_screen.dart' show ChatTile;
import 'package:chatapp/screens/my_profile_screen.dart';
import 'package:chatapp/screens/settings_screens.dart';
import 'package:chatapp/screens/premium_screens.dart';
import 'package:chatapp/state/auth_state.dart';
import 'package:chatapp/state/chat_store.dart';
import 'package:chatapp/theme/brand.dart';
import 'package:chatapp/widgets/coin_cards.dart';
import 'package:chatapp/widgets/album_view.dart';
import 'package:chatapp/widgets/extras.dart';
import 'package:chatapp/widgets/message_bubble.dart';

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

/// Logged in as a pretend person (profile and settings pages).
class _AuthMe extends _Auth {
  final _me = AppUser.fromJson({'id': 1, 'first_name': 'Muhammad', 'last_name': 'Shareef', 'username': 'shareef', 'phone': '+92 300 1234567', 'email': 'me@example.com', 'bio': 'Building Hushavia — a private messenger. Tea first, code later.'});
  @override
  AppUser? get me => _me;
  @override
  final accounts = AccountStore();
  @override
  int get maxAccounts => 3;
  @override
  List<StoredAccount> get otherAccounts => const [];
  @override
  bool get plusAvailable => true;
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

    Future<void> show(Widget screen, String name, {bool dark = false, bool me = false, Future<void> Function()? then}) async {
      final base = dark ? Brand.dark() : Brand.light();
      await tester.pumpWidget(RepaintBoundary(
        key: shot,
        child: MultiProvider(
          providers: [
            Provider<AppServices>.value(value: _Services()),
            ChangeNotifierProvider<AuthState>.value(value: me ? _AuthMe() : _Auth()),
            ChangeNotifierProvider<ProxyManager>.value(value: ProxyManager.instance),
            ChangeNotifierProvider<AppPrefs>.value(value: AppPrefs()),
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

    await show(const MyProfileScreen(), 'profile', me: true);
    await show(const MyProfileScreen(), 'profile-dark', me: true, dark: true);
    await show(const EditProfileScreen(), 'edit-profile', me: true);
    await show(const EditProfileScreen(), 'edit-profile-dark', me: true, dark: true);
    await show(const SettingsScreen(), 'settings', me: true);
    await show(const SettingsScreen(), 'settings-dark', me: true, dark: true);
    await show(const SettingsScreen(), 'settings-2', me: true, then: () async {
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 400));
    });
    // ---- chat list rows
    final now = DateTime.now();
    Map<String, dynamic> lm(int id, int from, String text, {String type = 'text', int ago = 5, Map<String, dynamic>? sender}) => {
          'id': id, 'chat_id': id, 'sender_id': from, 'type': type, 'text': text,
          'created_at': now.subtract(Duration(minutes: ago)).toIso8601String(), if (sender != null) 'sender': sender,
        };
    final listChats = [
      Chat.fromJson({'id': 11, 'type': 'private', 'title': 'Hina Khan', 'is_pinned': true, 'unread_count': 2, 'read_up_to': 0, 'peer': {'id': 2, 'first_name': 'Hina', 'last_name': 'Khan', 'online': true}, 'last_message': lm(101, 2, 'Kal meeting 11 baje confirm hai?', ago: 3)}),
      Chat.fromJson({'id': 12, 'type': 'group', 'title': 'Family', 'member_count': 6, 'unread_count': 14, 'unread_mentions': 1, 'last_message': lm(102, 3, 'Khana 8 baje ready hoga', ago: 12, sender: {'id': 3, 'first_name': 'Ali', 'last_name': 'Raza'})}),
      Chat.fromJson({'id': 13, 'type': 'private', 'title': 'Asad Ali', 'read_up_to': 103, 'delivered_up_to': 103, 'peer': {'id': 5, 'first_name': 'Asad', 'last_name': 'Ali'}, 'last_message': lm(103, 1, 'Theek hai, kal baat karte hain', ago: 40)}),
      Chat.fromJson({'id': 14, 'type': 'channel', 'title': 'Cricket News', 'is_verified': true, 'is_muted': true, 'muted_until': '2099-01-01T00:00:00Z', 'unread_count': 37, 'last_message': lm(104, 9, 'Pakistan won by 6 wickets 🏏', type: 'image', ago: 90)}),
      Chat.fromJson({'id': 15, 'type': 'private', 'title': 'Sara', 'peer': {'id': 4, 'first_name': 'Sara'}, 'last_message': lm(105, 4, '', type: 'voice', ago: 300)}),
      Chat.fromJson({'id': 16, 'type': 'private', 'title': 'Bilal Ahmed', 'peer': {'id': 6, 'first_name': 'Bilal', 'last_name': 'Ahmed'}, 'last_message': lm(106, 6, 'Missed call', type: 'call', ago: 1500)}),
      Chat.fromJson({'id': 17, 'type': 'group', 'title': 'Office Team', 'member_count': 24, 'last_message': lm(107, 7, 'Report bhej di hai, check kar lein', ago: 3000, sender: {'id': 7, 'first_name': 'Usman', 'last_name': ''})}),
      Chat.fromJson({'id': 18, 'type': 'private', 'title': 'Saved Messages', 'is_saved_messages': true, 'peer': {'id': 1, 'first_name': 'Me'}, 'last_message': lm(108, 1, 'Passport scan', type: 'file', ago: 6000)}),
    ];
    Widget chatList() => Scaffold(
          appBar: AppBar(title: const Text('Hushavia')),
          body: ListView(children: [for (final c in listChats) ChatTile(chat: c)]),
        );
    await show(chatList(), 'chat-list', me: true);
    await show(chatList(), 'chat-list-dark', me: true, dark: true);
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

    // ---- chat bubbles: a private chat and a group, with pretend messages
    final day = DateTime(2026, 11, 12, 10);
    Message t(int id, int from, String text, {int min = 0, Map<String, dynamic>? reply, String? fwd, bool edited = false, List<Map<String, dynamic>>? reactions, String? album, String type = 'text', AppUser? sender}) => Message.fromJson({
          'id': id, 'chat_id': 5, 'sender_id': from, 'type': type, 'text': text, 'album_id': album,
          'created_at': day.add(Duration(minutes: min)).toIso8601String(),
          if (edited) 'edited_at': day.add(Duration(minutes: min + 1)).toIso8601String(),
          if (fwd != null) 'forwarded_from': {'name': fwd},
          if (reactions != null) 'reactions': reactions,
          if (sender != null) 'sender': {'id': sender.id, 'first_name': sender.firstName, 'last_name': sender.lastName},
          if (reply != null) 'reply_to': reply,
        });
    Widget bubbles(Chat chat, List<Widget> rows) => Scaffold(
          appBar: AppBar(title: Text(chat.title)),
          body: Builder(builder: (c) => ColoredBox(color: ChatColors.of(c).background, child: ListView(padding: const EdgeInsets.symmetric(vertical: 10), children: rows))),
        );
    final priv = Chat.fromJson({'id': 5, 'type': 'private', 'title': 'Hina Khan', 'read_up_to': 6, 'delivered_up_to': 8, 'peer': {'id': 2, 'first_name': 'Hina', 'last_name': 'Khan'}});
    MessageBubble b(Chat chat, Message m, {bool first = true, bool last = true, bool sender = false}) =>
        MessageBubble(message: m, chat: chat, isMine: m.senderId == 1, showSender: sender, firstInGroup: first, lastInGroup: last, showAvatar: last && chat.isGroup && m.senderId != 1);
    List<Widget> privRows() => [
          DateChip(date: day),
          b(priv, t(1, 2, 'Assalam o alaikum! Kya haal hai?')),
          b(priv, t(2, 1, 'Walaikum salam 🙂', min: 1), last: false),
          b(priv, t(3, 1, 'Sab theek. Kal ki meeting ka time confirm ho gaya hai, 11 baje office me milte hain — file bhi sath le aana.', min: 1, edited: true), first: false),
          b(priv, t(4, 2, 'ok', min: 2), last: false),
          b(priv, t(5, 2, 'Check this: https://hushavia.com/plan and **bold**, _italic_, `code`', min: 2), first: false),
          b(priv, t(6, 1, 'Done ✅', min: 3, reply: {'id': 5, 'sender_id': 2, 'sender_name': 'Hina Khan', 'type': 'text', 'text': 'Check this: https://hushavia.com/plan'})),
          b(priv, t(7, 2, 'یہ پیغام اردو میں ہے، وقت الگ سطر پر رہے گا', min: 4)),
          b(priv, t(8, 1, 'Great news!', min: 5, reactions: [{'emoji': '❤️', 'count': 1}, {'emoji': '👍', 'count': 1}])),
          b(priv, t(9, 2, 'Forwarded text with a longer line to see wrapping in the bubble', min: 6, fwd: 'Cricket News')),
          b(priv, t(10, 1, '🎉', min: 7)),
          const SystemBubble(text: 'Hina Khan pinned a message'),
          AlbumBubble(chat: priv, isMine: true, items: [for (var i = 0; i < 3; i++) t(20 + i, 1, '', min: 8, album: 'a1', type: 'image')]),
          AlbumBubble(chat: priv, isMine: false, items: [for (var i = 0; i < 5; i++) t(30 + i, 2, i == 0 ? 'Trip photos 🌄' : '', min: 9, album: 'a2', type: 'image')]),
        ];
    await show(Builder(builder: (c) => bubbles(priv, privRows())), 'chat-private');
    await show(Builder(builder: (c) => bubbles(priv, privRows())), 'chat-private-dark', dark: true);
    await show(Builder(builder: (c) => bubbles(priv, privRows())), 'chat-private-2', then: () async {
      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pump(const Duration(milliseconds: 400));
    });
    final group = Chat.fromJson({'id': 5, 'type': 'group', 'title': 'Family', 'member_count': 6, 'read_up_to': 3});
    final ali = AppUser.fromJson({'id': 3, 'first_name': 'Ali', 'last_name': 'Raza'});
    final sara = AppUser.fromJson({'id': 4, 'first_name': 'Sara', 'last_name': ''});
    List<Widget> groupRows() => [
          DateChip(date: day),
          b(group, t(1, 3, 'Aaj shaam ko sab aa rahe hain?', sender: ali), sender: true, last: false),
          b(group, t(2, 3, 'Khana 8 baje', min: 1, sender: ali), first: false),
          b(group, t(3, 1, 'Haan, main 7:30 tak pohanch jaunga', min: 2)),
          b(group, t(4, 4, '👍', min: 3, sender: sara), sender: true),
          b(group, t(5, 4, 'Main dessert le aaungi', min: 3, sender: sara, reply: {'id': 2, 'sender_id': 3, 'sender_name': 'Ali Raza', 'type': 'text', 'text': 'Khana 8 baje'})),
          AlbumBubble(chat: group, isMine: false, senderName: 'Ali Raza', sender: ali, showAvatar: true, items: [for (var i = 0; i < 4; i++) t(40 + i, 3, '', min: 5, album: 'a3', type: 'image', sender: ali)]),
          b(group, Message.fromJson({'id': 60, 'chat_id': 5, 'sender_id': 1, 'type': 'poll', 'created_at': day.add(const Duration(minutes: 4)).toIso8601String(),
            'poll': {'id': 1, 'question': 'Kis din milna hai?', 'total_voters': 5, 'anonymous': false, 'my_votes': [0], 'options': [{'text': 'Saturday', 'votes': 3}, {'text': 'Sunday', 'votes': 2}]}})),
          AlbumBubble(chat: group, isMine: true, items: [for (var i = 0; i < 2; i++) t(50 + i, 1, i == 0 ? 'Yeh dekho' : '', min: 6, album: 'a4', type: 'image')]),
        ];
    await show(Builder(builder: (c) => bubbles(group, groupRows())), 'chat-group');
    await show(Builder(builder: (c) => bubbles(group, groupRows())), 'chat-group-dark', dark: true);

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
