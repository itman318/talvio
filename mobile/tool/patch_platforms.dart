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
  _desugaring();
  _androidBranding();
  _iosBranding();
  _releaseSigning();
  _googleServices();
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
    'android.permission.RECEIVE_BOOT_COMPLETED',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION',
    'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
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
  // Prayer reminders (flutter_local_notifications) and the screen-share service (flutter_foreground_task)
  if (!xml.contains('ScheduledNotificationReceiver')) {
    const comps = '''
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver" />
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
        <service android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
            android:foregroundServiceType="mediaProjection" android:exported="false" />
    ''';
    xml = xml.replaceFirst('</application>', '$comps</application>');
  }
  // Allows http:// during development. Remove once your server uses https://.
  if (!xml.contains('usesCleartextTraffic')) {
    xml = xml.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
  }
  // sticker maker: download the on-device background-removal model with the app
  if (!xml.contains('com.google.mlkit.vision.DEPENDENCIES')) {
    xml = xml.replaceFirst('</application>',
        '    <meta-data android:name="com.google.mlkit.vision.DEPENDENCIES" android:value="subject_segment" />\n    </application>');
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
        .replaceAll(RegExp(r'minSdk\s*=\s*flutter\.minSdkVersion'), 'minSdk = 24')
        .replaceAll(RegExp(r'minSdkVersion\s+flutter\.minSdkVersion'), 'minSdkVersion 24');
    f.writeAsStringSync(g);
    stdout.writeln('✓ $name: minSdk 24'); // ML Kit subject segmentation needs 24
  }

  // Fingerprint unlock (local_auth) needs a FlutterFragmentActivity.
  final src = Directory('android/app/src/main');
  if (src.existsSync()) {
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      final n = f.path.split(Platform.pathSeparator).last;
      if (n != 'MainActivity.kt' && n != 'MainActivity.java') continue;
      var code = f.readAsStringSync();
      if (n == 'MainActivity.kt' && !code.contains('talvio/system')) {
        // FlutterFragmentActivity + a small channel for "don't let the phone put Talvio to sleep" (battery optimisation)
        final pkg = RegExp(r'^package\s+[\w.]+', multiLine: true).firstMatch(code)?.group(0) ?? 'package com.talvio.chatapp';
        f.writeAsStringSync('''$pkg

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "talvio/system").setMethodCallHandler { call, result ->
            when (call.method) {
                "batteryRestricted" -> {
                    if (Build.VERSION.SDK_INT < 23) {
                        result.success(false)
                    } else {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(!pm.isIgnoringBatteryOptimizations(packageName))
                    }
                }
                "askBattery" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + packageName)))
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                            result.success(true)
                        } catch (e2: Exception) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
''');
        stdout.writeln('✓ ${f.path}: FlutterFragmentActivity + battery channel');
        continue;
      }
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
/// flutter_local_notifications needs Java 8+ APIs on older Androids (core library desugaring).
void _desugaring() {
  for (final name in ['android/app/build.gradle.kts', 'android/app/build.gradle']) {
    final f = File(name);
    if (!f.existsSync()) continue;
    var s = f.readAsStringSync();
    if (s.contains('desugar_jdk_libs')) return;
    final kts = name.endsWith('.kts');
    final co = s.indexOf(RegExp(r'compileOptions\s*\{'));
    if (co < 0) {
      stderr.writeln('! $name: compileOptions not found — enable desugaring by hand');
      return;
    }
    final brace = s.indexOf('{', co) + 1;
    s = s.substring(0, brace) + (kts ? '\n        isCoreLibraryDesugaringEnabled = true' : '\n        coreLibraryDesugaringEnabled true') + s.substring(brace);
    final dep = kts ? 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")' : "coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'";
    final d = s.indexOf(RegExp(r'^dependencies\s*\{', multiLine: true));
    if (d >= 0) {
      final b = s.indexOf('{', d) + 1;
      s = s.substring(0, b) + '\n    $dep' + s.substring(b);
    } else {
      s += '\ndependencies {\n    $dep\n}\n';
    }
    f.writeAsStringSync(s);
    stdout.writeln('✓ $name: core library desugaring');
    return;
  }
}

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

/// Talvio launcher icons (legacy + adaptive + themed), and the launch/splash screen in brand ink.
/// The PNGs come from branding/ (regenerate with: node tool/branding/render.js branding).
void _androidBranding() {
  final res = Directory('android/app/src/main/res');
  final src = Directory('branding/android');
  if (!res.existsSync() || !src.existsSync()) return;
  for (final f in src.listSync(recursive: true).whereType<File>()) {
    final rel = f.path.substring(src.path.length + 1);
    final dst = File('${res.path}/$rel');
    dst.parent.createSync(recursive: true);
    f.copySync(dst.path);
  }
  void write(String rel, String body) {
    final f = File('${res.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body);
  }

  const adaptive = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>
</adaptive-icon>
''';
  write('drawable/ic_launcher_background.xml', '''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android">
    <gradient android:angle="315" android:startColor="#FF9A62" android:centerColor="#F2557E" android:endColor="#6C4BE0"/>
</shape>
''');
  write('mipmap-anydpi-v26/ic_launcher.xml', adaptive);
  write('mipmap-anydpi-v26/ic_launcher_round.xml', adaptive);
  write('values/talvio_colors.xml', '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="talvio_ink">#F2557E</color>
    <color name="talvio_window">#F3F4F9</color>
</resources>
''');
  const launch = '''<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@color/talvio_ink"/>
    <item><bitmap android:gravity="center" android:src="@drawable/splash_logo"/></item>
</layer-list>
''';
  write('drawable/launch_background.xml', launch);
  write('drawable-v21/launch_background.xml', launch);
  const v31 = '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="LaunchTheme" parent="@android:style/Theme.Black.NoTitleBar">
        <item name="android:forceDarkAllowed">false</item>
        <item name="android:windowSplashScreenBackground">@color/talvio_ink</item>
        <item name="android:windowSplashScreenAnimatedIcon">@drawable/splash_icon</item>
        <item name="android:windowBackground">@drawable/launch_background</item>
    </style>
    <style name="NormalTheme" parent="@android:style/Theme.Black.NoTitleBar">
        <item name="android:windowBackground">@color/talvio_window</item>
    </style>
</resources>
''';
  write('values-v31/styles.xml', v31);
  // after the splash, the window behind the app (and the system navigation bar) is calm, not brand pink
  write('values-night-v31/styles.xml', v31.replaceAll('@color/talvio_window', '#0D1122'));
  write('values-night/talvio_window.xml', '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="talvio_window">#0D1122</color>\n</resources>\n');
  stdout.writeln('✓ Android: Talvio launcher icons + splash screen');
}

void _iosBranding() {
  final set = Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset');
  final src = Directory('branding/ios');
  if (!set.existsSync() || !src.existsSync()) return;
  for (final f in set.listSync().whereType<File>()) {
    if (f.path.endsWith('.png')) f.deleteSync();
  }
  final images = <String>[];
  void add(String idiom, double size, int scale) {
    final px = (size * scale).round();
    final name = 'Icon-$px.png';
    final file = File('${src.path}/$name');
    if (!file.existsSync()) return;
    file.copySync('${set.path}/$name');
    final sz = size == size.roundToDouble() ? size.toInt().toString() : size.toString();
    images.add('{"idiom":"$idiom","size":"${sz}x$sz","scale":"${scale}x","filename":"$name"}');
  }

  for (final s in [20.0, 29.0, 40.0, 60.0]) {
    add('iphone', s, 2);
    add('iphone', s, 3);
  }
  for (final s in [20.0, 29.0, 40.0, 76.0]) {
    add('ipad', s, 1);
    add('ipad', s, 2);
  }
  add('ipad', 83.5, 2);
  add('ios-marketing', 1024, 1);
  File('${set.path}/Contents.json').writeAsStringSync('{"images":[${images.join(',')}],"info":{"version":1,"author":"talvio"}}');
  stdout.writeln('✓ iOS: Talvio app icon');
}

/// Release signing: when android/key.properties exists (written by CI from the encrypted upload key),
/// sign release builds with it instead of the debug key. Also sets the Play Store application id.
void _releaseSigning() {
  const appId = 'com.talvio.app';
  for (final name in ['android/app/build.gradle.kts', 'android/app/build.gradle']) {
    final f = File(name);
    if (!f.existsSync()) continue;
    var s = f.readAsStringSync();
    final kts = name.endsWith('.kts');
    s = s.replaceFirst(RegExp(r'applicationId\s*=?\s*"[^"]*"'), kts ? 'applicationId = "$appId"' : 'applicationId "$appId"');
    if (File('android/key.properties').existsSync() && !s.contains('talvio-release-signing')) {
      final block = kts
          ? '''
    // talvio-release-signing
    signingConfigs {
        create("release") {
            val props = Properties()
            rootProject.file("key.properties").inputStream().use { props.load(it) }
            keyAlias = props.getProperty("keyAlias")
            keyPassword = props.getProperty("keyPassword")
            storeFile = rootProject.file(props.getProperty("storeFile"))
            storePassword = props.getProperty("storePassword")
        }
    }
'''
          : '''
    // talvio-release-signing
    signingConfigs {
        release {
            def props = new Properties()
            props.load(rootProject.file("key.properties").newInputStream())
            keyAlias props["keyAlias"]
            keyPassword props["keyPassword"]
            storeFile rootProject.file(props["storeFile"])
            storePassword props["storePassword"]
        }
    }
''';
      final i = s.indexOf('buildTypes');
      if (i > 0) s = s.substring(0, i) + block.trimLeft() + '\n    ' + s.substring(i);
      // Kotlin DSL: inside android { } the name "java" means the java extension, so import Properties
      if (kts && !s.contains('import java.util.Properties')) s = 'import java.util.Properties\n' + s;
      s = kts
          ? s.replaceAll('signingConfig = signingConfigs.getByName("debug")', 'signingConfig = signingConfigs.getByName("release")')
          : s.replaceAll('signingConfig signingConfigs.debug', 'signingConfig signingConfigs.release');
      stdout.writeln('✓ $name: release builds signed with the upload key');
    }
    f.writeAsStringSync(s);
    return;
  }
}

/// Push notifications: when android/app/google-services.json exists (CI writes it from the
/// GOOGLE_SERVICES_JSON secret), apply the Google Services Gradle plugin so Firebase works.
void _googleServices() {
  if (!File('android/app/google-services.json').existsSync()) return;
  final settings = File('android/settings.gradle.kts').existsSync() ? File('android/settings.gradle.kts') : File('android/settings.gradle');
  final app = File('android/app/build.gradle.kts').existsSync() ? File('android/app/build.gradle.kts') : File('android/app/build.gradle');
  if (!settings.existsSync() || !app.existsSync()) return;
  final kts = settings.path.endsWith('.kts');
  var s = settings.readAsStringSync();
  if (!s.contains('com.google.gms.google-services')) {
    s = s.replaceFirst(RegExp(r'plugins\s*\{'),
        kts ? 'plugins {\n    id("com.google.gms.google-services") version "4.4.2" apply false' : 'plugins {\n    id "com.google.gms.google-services" version "4.4.2" apply false');
    settings.writeAsStringSync(s);
  }
  var a = app.readAsStringSync();
  if (!a.contains('com.google.gms.google-services')) {
    a = a.replaceFirst(RegExp(r'plugins\s*\{'), kts ? 'plugins {\n    id("com.google.gms.google-services")' : 'plugins {\n    id "com.google.gms.google-services"');
    app.writeAsStringSync(a);
  }
  stdout.writeln('✓ Firebase (push notifications) enabled');
}
