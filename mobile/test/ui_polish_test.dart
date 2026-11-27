import 'package:chatapp/widgets/mascot.dart';
import 'package:chatapp/widgets/premium.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('all Hushi poses render and respect reduced motion', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: Wrap(children: [
            for (final pose in TaviPose.values) AppMascot(pose: pose, size: 64),
            const AppMascot(pose: TaviPose.search, art: 'nocontacts', size: 80),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(TaviPose.values.length + 1));
    expect(find.byKey(const ValueKey('hello-still.webp')), findsOneWidget);
    expect(find.byKey(const ValueKey('contacts-still.webp')), findsOneWidget);
    expect(find.byKey(const ValueKey('hello.gif')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an animated sticker moves the illustrated duck', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(child: AppMascot(pose: TaviPose.angry)),
    ));
    final image = find.byKey(const ValueKey('angry.png'));
    expect(image, findsOneWidget);
    final before = tester.getTopLeft(image);
    await tester.pump(const Duration(milliseconds: 175));
    expect(tester.getTopLeft(image), isNot(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile actions wrap on narrow screens', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: ProfileHero(id: 1, name: 'Example profile', actions: [
        for (final name in ['Message', 'Call', 'Video', 'Mute', 'Vault'])
          ProfileAction(icon: Icons.chat, label: name, onTap: () {}),
      ]),
    ))));
    expect(find.byType(ProfileAction), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings row handles a long trailing value on a narrow screen', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 280,
      child: SettingsGroup(title: 'Preferences', children: [
        SettingsTile(icon: Icons.settings, color: Colors.purple, title: 'Connection', trailing: 'A very long settings value that must not overflow', onTap: () {}),
      ]),
    ))));
    expect(tester.takeException(), isNull);
  });
}
