# Talvio — messaging app

| Folder | What | Tech |
|---|---|---|
| `backend/` | API, realtime server, admin API **and** the admin panel (`/admin`) | Node.js 20, Express, Socket.IO, PostgreSQL |
| `backend/admin-panel/` | Admin web panel (served by the backend) | Plain HTML/CSS/JS, no build step |
| `mobile/` | User app | Flutter (Android + iOS) |

## Quick start

1. **Backend** — see `backend/README.md`: `npm install`, `npm run migrate`, `npm run create-admin`, `npm run dev`.
2. **Admin panel** — open `http://localhost:4000/admin` and log in with the admin you created.
3. **App** — see `mobile/README.md`: `flutter create .`, `dart run tool/patch_platforms.dart`,
   `flutter run --dart-define=API_BASE=http://10.0.2.2:4000`.

## Phase 1 — what's included

**User app:** phone + OTP login, profile (name, @username, bio, photo), 1-to-1 chats, Saved Messages,
groups (create, add/remove, admins, invite codes, ownership transfer), text / photo / video / file /
voice messages, reply, edit, forward, delete for me / everyone, sent-delivered-read ticks, typing and
online / last seen, unread counts, mute / pin / archive / clear history, privacy settings, contacts,
block, report, device sessions, account deletion, push notifications (FCM), maintenance & force-update screens.

**Admin panel:** dashboard (users, online, active, messages, signups chart), user search & detail
(ban with duration, unban, log out all devices, verified badge, delete), reports queue with saved
evidence (delete message, ban, suspend group), groups (suspend / delete), app settings
(registration on/off, maintenance mode, max group size, upload limit, edit window, app versions),
admin team with roles (super admin / moderator / support), activity log.

## Phase 2 — what's included

**User app:** channels (public @link or private invite, admin-only posting, optional signatures, view
counts, statistics), public search & join for groups/channels, polls & quizzes (anonymous/public,
multiple answers, correct answer + explanation, stop poll, voters list), emoji reactions, scheduled
messages (hold the send button), chat folders (tabs above the chat list), 24-hour stories (photo/video,
privacy, viewers, replies, ❤️), help & support tickets, announcement banners.

**Admin panel:** groups & channels (type filter, verified badge), restrict/mute users, automatic
moderation (banned words, new-account link limit, copy-paste spam, mass-report restriction, phone
prefix blacklist) with auto-reports, broadcast (in-app banner and/or push, targeted by country code
or platform), support desk (tickets, replies, priority, assignment), two-factor authentication for
admins with backup codes and an optional "require 2FA" policy.

## Batch A — what's included

**User app:** pinned messages (bar on top + list), @mentions with an @ badge in the chat list,
mark as unread, drafts kept per chat, silent messages (hold send), search inside all messages,
find friends from phone contacts, share location, dark mode & text size, app lock (PIN + fingerprint/
Face ID, auto-lock), media cache size & clear, download my data, Terms / Privacy / FAQ pages,
ban appeal from the login screen. Groups: slow mode, approve new members (join requests), extra
invite links with expiry and usage limit, transfer ownership.

**Admin panel:** ban appeals queue, moderator notes on users, export a user's data, set usernames
and a reserved-usernames list, group members & owner transfer, IP blacklist, feature switches
(channels, stories, polls, voice messages, location), Terms/Privacy/FAQ editor, broadcasts to app
versions below X.

## Batch B — what's included

**User app:** one-to-one voice and video calls (WebRTC) — ringing screen with ringtone, accept /
decline, mute, speaker, camera on/off, flip camera, auto-reconnect when the network changes,
"line busy", missed-call notifications, call entries inside the chat, a Calls screen (all / missed,
call back, delete), call buttons in the chat and profile, rate the call quality, privacy
"who can call me".

**Admin panel:** Calls page (calls now/today, answer rate, average length & rating, failed calls,
14-day charts, call log with filters, force-end), call settings (on/off, video on/off, ring time,
max length, STUN/TURN servers), calls on the dashboard and user page.

## Batch C — what's included

**Secret chats** — end-to-end encrypted (X25519 + AES-256-GCM with a ratchet), on one phone per person.
Start from a profile or chat menu; green lock in the chat list; self-destruct timer (5 s … 1 week);
encrypted photos and files; delete for both; screenshots blocked; no forwarding; encryption-key
emoji to compare; nothing stays on the server after delivery; closed automatically on logout.
Admin panel: on/off switch and counts only (content can't be read by anyone but the two phones).

## Batch D — what's included

**Bots & mini apps:** create bots in the app (token like BotFather), Telegram-style Bot API (long polling
or webhooks), commands menu, START screen, inline buttons (callback / link / mini app), mini apps in an
in-app web view with signed user data. **Channel comments** under posts. **Topics** in groups.
**Premium** (⭐ badge, bigger uploads, more folders, no ads) with **JazzCash**, **Easypaisa** and
**manual transfer + screenshot** payments. **Sponsored messages** in big public channels.

**Admin panel:** Bots (disable/enable), Revenue (by month & method), Payments (review screenshots,
approve/reject), Premium plans editor, Sponsored message campaigns with views/clicks/CTR, give/remove
Premium on the user page, new switches in Settings.

## Batch E — what's included

**Web & desktop app** at `/web` (installable from Chrome/Edge as a desktop app) with **QR login**:
open it on a computer, scan with the phone (Settings → Devices → Link a device), confirm, done.
**Multiple accounts** on one phone (Settings → Add account, tap to switch; up to 3, configurable).
**Photo editor** before sending (crop, rotate, draw, text), **albums** (pick up to 10 photos → one
grid bubble), **auto-download** setting for photos (always / Wi-Fi only / never).

## Design — "Ember" (our own look)

- **Palette:** coral `#F2603D` → rose `#E9447A` gradient, mint `#12B3A3` for online, warm neutrals (`#FBF8F5`), deep ink dark mode (`#121120`). All in `mobile/lib/theme/brand.dart` (`Brand`), `backend/web-client/web.css` and `backend/admin-panel/style.css` — change once, re-skins everything.
- **Shapes:** squircle avatars with gradients, "pebble" message bubbles (round, soft inner corner, no tail), dotted warm chat wallpaper, rounded-square send button with an up-arrow, gradient story rings.
- **Navigation:** bottom bar (Chats · Calls · Settings) in the app (`screens/root_shell.dart`); brand mark (`BrandMark`) on splash, login and chat list header; new app icon (`web-client/icon.svg`).
- App name comes from `AppConfig.appName`. Flutter now needs Dart ≥ 3.6 (Flutter 3.27+).
- Fixes in this pass: web sender-name colour crash after palette change, login background height, attach button styling, dark-mode tile subtitles.

## Next

All planned batches are done (Urdu was skipped on request). Ideas: group calls (LiveKit), CallKit, Urdu/RTL, iPad layout.
