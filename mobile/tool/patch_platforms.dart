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
  _pluginCompileSdk();
  _noMinify();
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
    'android.permission.CAMERA',
    'android.permission.MODIFY_AUDIO_SETTINGS',
    'android.permission.ACCESS_NETWORK_STATE',
    'android.permission.CHANGE_NETWORK_STATE',
    'android.permission.BLUETOOTH_CONNECT',
    'android.permission.WAKE_LOCK',
  ];
  for (final p in perms) {
    if (!xml.contains(p)) {
      xml = xml.replaceFirst('<application', '<uses-permission android:name="$p"/>\n    <application');
    }
  }
  // talvio:// links (the "Back to the app" button after paying)
  if (!xml.contains('android:scheme="talvio"')) {
    final i = xml.indexOf('</activity>');
    if (i > 0) {
      const filter = '''    <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="talvio"/>
            </intent-filter>
        ''';
      xml = xml.substring(0, i) + filter + xml.substring(i);
    }
  }
  // Allows http:// during development. Remove once your server uses https://.
  if (!xml.contains('usesCleartextTraffic')) {
    xml = xml.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
  }
  // Name under the icon on the home screen
  xml = xml.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="Talvio"');
  manifest.writeAsStringSync(xml);
  stdout.writeln('✓ AndroidManifest.xml: permissions added, label = Talvio');

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
  if (!s.contains('CFBundleURLSchemes')) {
    add.write('\t<key>CFBundleURLTypes</key>\n\t<array>\n\t\t<dict>\n\t\t\t<key>CFBundleURLSchemes</key>\n\t\t\t<array><string>talvio</string></array>\n\t\t</dict>\n\t</array>\n');
  }
  if (!s.contains('UIBackgroundModes')) {
    // keeps the call audio running when the screen locks / the app goes to the background
    add.write('\t<key>UIBackgroundModes</key>\n\t<array>\n\t\t<string>audio</string>\n\t\t<string>remote-notification</string>\n\t</array>\n');
  }
  if (!s.contains('NSAllowsArbitraryLoads')) {
    // Development only (http://). Remove once your server uses https://.
    add.write('\t<key>NSAppTransportSecurity</key>\n\t<dict>\n\t\t<key>NSAllowsArbitraryLoads</key>\n\t\t<true/>\n\t</dict>\n');
  }
  // Name under the icon on the home screen
  s = s.replaceFirstMapped(RegExp(r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)'), (m) => '${m[1]}Talvio${m[2]}');
  if (!s.contains('CFBundleDisplayName')) add.write('\t<key>CFBundleDisplayName</key>\n\t<string>Talvio</string>\n');
  {
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

/// Some plugins still compile against an old Android SDK, while current AndroidX
/// libraries require compileSdk 36. Raise every plugin module to 36 (minSdk/targetSdk unchanged).
void _pluginCompileSdk() {
  const marker = 'talvio-compileSdk';
  final kts = File('android/build.gradle.kts');
  final groovy = File('android/build.gradle');
  if (kts.existsSync()) {
    final s = kts.readAsStringSync();
    if (!s.contains(marker)) {
      kts.writeAsStringSync('''// $marker: plugins compiled against an old SDK break newer AndroidX
subprojects {
    afterEvaluate {
        (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)?.compileSdkVersion(36)
    }
}

$s''');
    }
  } else if (groovy.existsSync()) {
    final s = groovy.readAsStringSync();
    if (!s.contains(marker)) {
      groovy.writeAsStringSync('''// $marker: plugins compiled against an old SDK break newer AndroidX
subprojects {
    afterEvaluate { p ->
        if (p.hasProperty('android')) { p.android.compileSdkVersion 36 }
    }
}

$s''');
    }
  } else {
    return;
  }
  stdout.writeln('✓ android/build.gradle: plugins compile against SDK 36');
}

/// R8 strips plugin classes that are only reached through JNI (e.g. shared_preferences'
/// SharedPreferencesApiRegistrar), which crashes the release app on launch. Keep all code.
void _noMinify() {
  const marker = 'talvio-no-minify';
  for (final name in ['android/app/build.gradle.kts', 'android/app/build.gradle']) {
    final f = File(name);
    if (!f.existsSync()) continue;
    var s = f.readAsStringSync();
    if (s.contains(marker)) return;
    final kts = name.endsWith('.kts');
    final bt = s.indexOf('buildTypes');
    final i = bt < 0 ? -1 : s.indexOf(RegExp(r'release\s*\{'), bt);
    if (i < 0) {
      stderr.writeln('! $name: release build type not found — disable minify by hand');
      return;
    }
    final at = s.indexOf('{', i) + 1;
    final add = kts
        ? '\n            // $marker\n            isMinifyEnabled = false\n            isShrinkResources = false'
        : '\n            // $marker\n            minifyEnabled false\n            shrinkResources false';
    s = s.substring(0, at) + add + s.substring(at);
    f.writeAsStringSync(s);
    stdout.writeln('✓ $name: R8 minify/shrink off for release');
    return;
  }
}
