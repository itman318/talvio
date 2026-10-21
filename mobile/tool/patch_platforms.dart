// Adds the permissions and SDK versions this app needs to the generated
// android/ and ios/ folders. Run once after `flutter create`:
//
//   flutter create . --org com.yourcompany --project-name chatapp --platforms=android,ios
//   dart run tool/patch_platforms.dart
//
// Safe to run more than once.
import 'dart:io';

void main() {
  _android();
  _ios();
  stdout.writeln('\nDone. Next: flutter pub get && flutter run --dart-define=API_BASE=http://<your-server>:4000');
}

void _android() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) {
    stderr.writeln('android/ not found — run `flutter create` first');
    return;
  }
  var xml = manifest.readAsStringSync();
  const perms = [
    'android.permission.INTERNET',
    'android.permission.RECORD_AUDIO',
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.ACCESS_COARSE_LOCATION',
    'android.permission.READ_CONTACTS',
    'android.permission.USE_BIOMETRIC',
  ];
  for (final p in perms) {
    if (!xml.contains(p)) {
      xml = xml.replaceFirst('<application', '<uses-permission android:name="$p"/>\n    <application');
    }
  }
  // Allows http:// during development. Remove once your server uses https://.
  if (!xml.contains('usesCleartextTraffic')) {
    xml = xml.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
  }
  manifest.writeAsStringSync(xml);
  stdout.writeln('✓ AndroidManifest.xml: permissions added');

  for (final name in ['android/app/build.gradle', 'android/app/build.gradle.kts']) {
    final f = File(name);
    if (!f.existsSync()) continue;
    var g = f.readAsStringSync();
    g = g
        .replaceAll(RegExp(r'minSdk\s*=\s*flutter\.minSdkVersion'), 'minSdk = 23')
        .replaceAll(RegExp(r'minSdkVersion\s+flutter\.minSdkVersion'), 'minSdkVersion 23');
    f.writeAsStringSync(g);
    stdout.writeln('✓ $name: minSdk 23');
  }

  // Fingerprint unlock (local_auth) needs a FlutterFragmentActivity.
  final src = Directory('android/app/src/main');
  if (src.existsSync()) {
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      final n = f.path.split(Platform.pathSeparator).last;
      if (n != 'MainActivity.kt' && n != 'MainActivity.java') continue;
      var code = f.readAsStringSync();
      if (code.contains('FlutterFragmentActivity')) continue;
      code = code
          .replaceAll('io.flutter.embedding.android.FlutterActivity', 'io.flutter.embedding.android.FlutterFragmentActivity')
          .replaceAll(RegExp(r'\bFlutterActivity\b'), 'FlutterFragmentActivity');
      f.writeAsStringSync(code);
      stdout.writeln('✓ ${f.path}: FlutterFragmentActivity (for fingerprint unlock)');
    }
  }
}

void _ios() {
  final plist = File('ios/Runner/Info.plist');
  if (!plist.existsSync()) {
    stderr.writeln('ios/ not found — skipping iOS');
    return;
  }
  var s = plist.readAsStringSync();
  const keys = {
    'NSCameraUsageDescription': 'Take photos to send in chats.',
    'NSPhotoLibraryUsageDescription': 'Choose photos and videos to send in chats.',
    'NSMicrophoneUsageDescription': 'Record voice messages.',
    'NSLocationWhenInUseUsageDescription': 'Share your location in a chat when you choose to.',
    'NSContactsUsageDescription': 'Find friends from your contacts who use the app.',
    'NSFaceIDUsageDescription': 'Unlock the app with Face ID.',
  };
  final add = StringBuffer();
  keys.forEach((k, v) {
    if (!s.contains(k)) add.write('\t<key>$k</key>\n\t<string>$v</string>\n');
  });
  if (!s.contains('NSAllowsArbitraryLoads')) {
    // Development only (http://). Remove once your server uses https://.
    add.write('\t<key>NSAppTransportSecurity</key>\n\t<dict>\n\t\t<key>NSAllowsArbitraryLoads</key>\n\t\t<true/>\n\t</dict>\n');
  }
  if (add.isNotEmpty) {
    final i = s.lastIndexOf('</dict>');
    s = s.substring(0, i) + add.toString() + s.substring(i);
    plist.writeAsStringSync(s);
  }
  stdout.writeln('✓ Info.plist: camera, photos, microphone, location, contacts, Face ID');

  final podfile = File('ios/Podfile');
  if (podfile.existsSync()) {
    var p = podfile.readAsStringSync();
    p = p.replaceFirst(RegExp(r"#?\s*platform :ios, '[0-9.]+'"), "platform :ios, '13.0'");
    podfile.writeAsStringSync(p);
    stdout.writeln('✓ Podfile: iOS 13.0');
  }
}
