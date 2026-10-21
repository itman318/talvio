/// App configuration.
///
/// Set the server URL at build time, e.g.
///   flutter run --dart-define=API_BASE=http://192.168.1.10:4000
///   flutter build apk --dart-define=API_BASE=https://chat.example.com
///
/// Android emulator → use http://10.0.2.2:4000 to reach your computer's localhost.
class AppConfig {
  static const String serverUrl = String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:4000');
  static const String apiBase = '$serverUrl/api';
  static const String appName = 'Talvio';
  static const String appVersion = '1.0.0';
  static const String defaultCountryCode = '+92';

  /// Absolute URL for a path returned by the API (e.g. "/api/media/12/public").
  static String absolute(String path) => path.startsWith('http') ? path : '$serverUrl$path';
}
