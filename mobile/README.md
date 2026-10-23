# Talvio — Flutter app (Android + iOS)

Phase 1: OTP login, profile, 1-to-1 chats, groups, photos/videos/files, voice notes,
replies, edit, forward, delete (for me / everyone), read receipts, typing & online status,
mute / pin / archive, privacy settings, block & report, devices, push notifications.

Phase 2: channels, public search & join, polls & quizzes, reactions, scheduled messages
(hold the send button), chat folders, stories, help & support tickets, announcement banners.

## First-time setup

Requirements: Flutter 3.27+ (Dart 3.6+), Android Studio and/or Xcode.

```bash
cd mobile
flutter create . --org com.yourcompany --project-name chatapp --platforms=android,ios
dart run tool/patch_platforms.dart      # permissions, minSdk 23, iOS 13
flutter pub get
```

`flutter create .` only adds the missing `android/` and `ios/` folders — it keeps `lib/` and `pubspec.yaml`.

## Run

```bash
# Android emulator talking to the backend on your computer:
flutter run --dart-define=API_BASE=http://10.0.2.2:4000

# Real phone on the same Wi-Fi (use your computer's LAN IP):
flutter run --dart-define=API_BASE=http://192.168.1.10:4000

# Release build against your live server:
flutter build apk --release --dart-define=API_BASE=https://chat.yourdomain.com
flutter build ipa --release --dart-define=API_BASE=https://chat.yourdomain.com
```

With `OTP_DEV_MODE=true` on the server, the code is shown on the OTP screen, so you can test without SMS.

## Push notifications (optional)

The app runs without Firebase; push is simply off. To enable it:

1. Create a Firebase project and add Android + iOS apps (same package / bundle id as `--org` + `chatapp`).
2. `dart pub global activate flutterfire_cli && flutterfire configure` — or place
   `google-services.json` in `android/app/` and `GoogleService-Info.plist` in `ios/Runner/`.
3. iOS: in Xcode enable *Push Notifications* and *Background Modes → Remote notifications*,
   and upload your APNs key in Firebase → Project settings → Cloud Messaging.
4. On the server set `FIREBASE_SERVICE_ACCOUNT_PATH` to a service-account JSON from the same project.

## Code map

| Path | What it does |
|---|---|
| `lib/config.dart` | Server URL (`--dart-define=API_BASE`), app version |
| `lib/core/api_client.dart` | REST calls, token storage, automatic token refresh, uploads/downloads |
| `lib/core/socket_service.dart` | Socket.IO realtime connection |
| `lib/core/media_cache.dart` | Downloads protected media once and caches it |
| `lib/state/auth_state.dart` | Login / logout / maintenance / forced update |
| `lib/state/chat_store.dart` | Chats, messages, optimistic sending, receipts, typing, presence |
| `lib/screens/` | All screens (`channel_screens.dart`, `story_screens.dart`, `folder_support_screens.dart` are Phase 2) |
| `lib/state/call_manager.dart` | Batch B: WebRTC calls (signaling, ICE restart, mute/speaker/camera) |
| `lib/screens/call_screen.dart`, `calls_screen.dart` | Call UI, call history, call entries in chats |
| `lib/core/e2e.dart`, `lib/state/secret_store.dart`, `lib/screens/secret_screens.dart` | Batch C: secret chats — crypto, encrypted local storage, UI |
| `lib/widgets/bot_widgets.dart`, `lib/screens/bot_screens.dart` | Batch D: inline buttons, mini apps (web view), My bots |
| `lib/screens/thread_screen.dart` | Channel comments and group topics |
| `lib/screens/premium_screens.dart` | Premium plans, JazzCash/Easypaisa checkout, manual payment proof |
| `lib/screens/link_device_screen.dart` | Batch E: scan the web/desktop login QR |
| `lib/core/accounts.dart` | Multiple accounts on one phone |
| `lib/screens/image_editor_screen.dart`, `lib/widgets/album_view.dart` | Photo editor, albums |
| `lib/core/prefs.dart` | Device settings: theme, text size, drafts, app lock |
| `lib/screens/more_screens.dart` | Batch A: invite links, join requests, contacts sync, appearance, app lock, storage, legal pages, ban appeal |
| `lib/widgets/` | Message bubble, avatar, media players, report dialog, `extras.dart` (dark-mode chat colours, @mention/link text, location card) |

`patch_platforms.dart` also adds the `talvio://` link (back from the payment page), camera/microphone/network permissions for calls (and iOS background audio), location, contacts and fingerprint/Face ID permissions and switches
`MainActivity` to `FlutterFragmentActivity` (needed for fingerprint unlock). If you created the
platform folders before Batch A, run it again.

Before publishing: change the app name/icon, remove the http (cleartext) exceptions added by
`patch_platforms.dart`, and point `API_BASE` at an `https://` server.
