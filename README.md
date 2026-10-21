# ChatApp — Phase 1 (Telegram-style messaging)

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

## Next (Phase 2 ideas)

Channels, voice/video calls, stories, chat folders, polls, secret (end-to-end encrypted) chats,
auto-moderation (banned words, spam scoring), broadcast notifications, admin 2FA, support tickets,
Redis for multi-server scaling, S3 media storage.
