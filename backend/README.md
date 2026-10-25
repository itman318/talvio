# Talvio backend — Node.js + PostgreSQL + Socket.IO

One server process provides:

- **REST API** for the mobile app — `/api/...`
- **Realtime** messaging over Socket.IO (same port)
- **Admin API** — `/api/admin/...`
- **Admin panel** (web) — `/admin`

## Local setup

Requirements: Node.js 20+, PostgreSQL 13+.

```bash
cd backend
cp .env.example .env            # edit DATABASE_URL and the secrets
npm install
createdb chatapp                # or create it in pgAdmin
npm run migrate                 # creates tables (safe to re-run on every deploy)
npm run create-admin -- admin@example.com "ChangeThisPassword!" "Your Name"
npm run dev                     # http://localhost:4000  → admin panel at /admin
```

With `OTP_DEV_MODE=true` the OTP is returned in the API response and printed in the log,
so you can log in from the app without an SMS provider.

## Tests

The tests run against a real PostgreSQL database **and wipe it first**, so use a separate one:

```bash
createdb chatapp_test
TEST_DATABASE_URL=postgres://user:pass@127.0.0.1:5432/chatapp_test npm test
```

64 end-to-end tests (`test/services.test.js` = Phase 1, `test/phase2.test.js` = Phase 2, `test/batchA.test.js` = Batch A, `test/batchB.test.js` = calls, `test/batchC.test.js` = secret chats, `test/batchD1.test.js` = bots/comments/topics, `test/batchD2.test.js` = premium/payments/ads, `test/batchE.test.js` = QR login/albums) cover OTP login &
token refresh, profiles & privacy, private chats, receipts, pagination, edit/delete, blocking, groups,
media access control, forwarding, reports, admin flows, account deletion — plus channels, polls & quizzes,
reactions, scheduled posts, folders, stories, automatic moderation, support tickets, broadcasts and admin 2FA — plus pins, mentions, message search, slow mode, join requests,
invite links, owner transfer, ban appeals, reserved usernames, IP blacklist, feature flags and version-targeted broadcasts.

## Production deployment (VPS)

Realtime chat needs a long-running Node process with WebSockets, so use a VPS
(Ubuntu, 2 GB RAM is enough to start). Shared cPanel hosting is not suitable for this part.

```bash
# on the server
sudo apt install -y nodejs npm postgresql nginx
sudo -u postgres createuser -P chat && sudo -u postgres createdb -O chat chatapp
cd /var/www/chatapp/backend && npm ci --omit=dev
cp .env.example .env   # NODE_ENV=production, OTP_DEV_MODE=false, TRUST_PROXY=true, real secrets, SMS provider
npm run migrate && npm run create-admin -- you@example.com "StrongPassword" "Name"
sudo npm i -g pm2 && pm2 start src/server.js --name chatapp && pm2 save && pm2 startup
```

Generate secrets with `openssl rand -hex 32`.

Nginx (then `sudo certbot --nginx -d chat.yourdomain.com` for HTTPS):

```nginx
server {
    server_name chat.yourdomain.com;
    client_max_body_size 60m;            # keep ≥ the "max upload size" admin setting

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;   # WebSockets
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }
}
```

Back up PostgreSQL and the `uploads/` folder daily.

## SMS for OTP

`SMS_PROVIDER=http` posts `{"to": "+92...", "message": "..."}` with a Bearer token to `SMS_HTTP_URL`
— point it at your SMS gateway, or adapt `src/services/sms.service.js` (`sendHttp`) to its format.
`SMS_PROVIDER=twilio` is built in.

## API reference

All responses are JSON. Errors look like `{"error": {"code": "otp_invalid", "message": "Incorrect code"}}`.
Authenticated routes need `Authorization: Bearer <access_token>`.

| Method & path | Purpose |
|---|---|
| `GET /api/app-config` | Public: maintenance flag, min app version, upload limit |
| `POST /api/auth/otp/request` `{phone}` | Send OTP (E.164, e.g. `+923001234567`) |
| `POST /api/auth/otp/verify` `{phone, code, device}` | → tokens, user, `needs_profile` |
| `POST /api/auth/refresh` `{refresh_token}` | Rotate tokens |
| `POST /api/auth/logout` | End this session |
| `GET/PATCH /api/me` | Own profile (first/last name, username, bio) |
| `PUT /api/me/privacy` | `last_seen`, `avatar`, `phone`, `group_add` = everyone/contacts/nobody |
| `PUT/DELETE /api/me/avatar` | Set (`{media_id}`) / remove profile photo |
| `GET /api/me/username-check?username=` | Availability |
| `GET /api/me/sessions`, `DELETE /api/me/sessions/:id`, `POST /api/me/sessions/terminate-others` | Devices |
| `PUT /api/me/push-token` `{token}` | FCM token for this device |
| `DELETE /api/me` `{confirm:"DELETE"}` | Delete account |
| `GET /api/users/search?q=` | By @username, exact phone, or contact name |
| `GET /api/users/:id` | Profile (privacy applied) |
| `GET/POST/DELETE /api/contacts…`, `POST /api/contacts/sync` `{phones}` | Contacts |
| `GET/POST/DELETE /api/blocks…` | Block list |
| `GET /api/chats?archived=` | Chat list with last message, unread count, receipts |
| `POST /api/chats/private` `{user_id}` | Open/create a 1-to-1 chat (own id = Saved Messages) |
| `POST /api/chats/group` `{title, member_ids}` | Create group → `{chat, skipped}` |
| `GET/PATCH /api/chats/:id`, `PUT /api/chats/:id/avatar` | Group info / edit |
| `GET/POST /api/chats/:id/members`, `DELETE /api/chats/:id/members/:uid`, `PUT …/:uid/role` | Members & admins |
| `POST /api/chats/:id/leave`, `/clear`, `PATCH /api/chats/:id/settings` | Leave/delete, clear, mute/pin/archive |
| `GET /api/chats/invite/:code`, `POST /api/chats/invite/:code/join`, `POST /api/chats/:id/invite/regenerate` | Invites |
| `GET /api/chats/:id/messages?before=&after=&limit=` | History (newest first) |
| `POST /api/chats/:id/messages` | Send (`type`, `text`, `media_id`, `reply_to_id`, `client_id`) |
| `POST /api/chats/:id/messages/delete` `{message_ids, for_everyone}` | Delete |
| `POST /api/chats/:id/read` `{message_id}` | Mark read |
| `PATCH /api/messages/:id` `{text}`, `POST /api/messages/forward` | Edit, forward |
| `POST /api/media` (multipart `file`, `kind`) / `GET /api/media/:id` | Upload / download |
| `POST /api/reports` `{target_type, target_id, reason, details}` | Report user/message/group |
| **Phase 2** | |
| `POST /api/chats/channel` `{title, description, username?}` | Create a channel (only admins post) |
| `GET /api/chats/search?q=`, `GET /api/chats/public/:username`, `POST /api/chats/:id/join` | Find & join public groups/channels |
| `PUT /api/chats/:id/username` `{username\|null}` | Make a group/channel public or private (owner) |
| `PATCH /api/chats/:id` `{signatures}` | Show admin names on channel posts |
| `GET /api/chats/:id/stats` | Members, growth, views, top posts (admins) |
| `POST /api/chats/:id/views` `{message_ids}` | Count channel post views (once per user) |
| `POST /api/chats/:id/messages` `{type:"poll", poll:{question, options, anonymous, multiple, quiz, correct_option, explanation}}` | Poll / quiz |
| `POST /api/chats/:id/messages` `{..., schedule_at}` → `{scheduled}` | Schedule a message; `GET /api/chats/:id/scheduled`, `DELETE /api/scheduled/:id` |
| `POST /api/messages/:id/vote` `{options}`, `POST …/poll/close`, `GET …/poll/voters?option=` | Polls |
| `PUT /api/messages/:id/reaction` `{emoji\|null}` | Reactions (👍 ❤️ 🔥 😂 😮 😢 👏 🙏 🎉 👎) |
| `GET/POST /api/folders`, `PATCH/DELETE /api/folders/:id`, `PUT /api/folders/order` | Chat folders |
| `GET/POST /api/stories`, `POST /api/stories/:id/view\|reply`, `GET …/viewers`, `DELETE /api/stories/:id` | 24-hour stories |
| `GET/POST /api/support/tickets`, `GET …/:id`, `POST …/:id/messages`, `POST …/:id/close` | Support tickets |
| `GET /api/announcements`, `POST /api/announcements/:id/dismiss` | In-app broadcast banners |
| **Batch A** | |
| `GET/POST /api/chats/:id/pins`, `DELETE /api/chats/:id/pins/:messageId\|all` | Pinned messages |
| `GET /api/search/messages?q=&chat_id=` | Full-text search across your chats |
| `POST /api/chats/:id/messages` `{silent:true}` / `{type:"location", location:{lat,lng,title}}` | Silent message / location |
| `PATCH /api/chats/:id/settings` `{marked_unread}` | Mark a chat unread |
| `PATCH /api/chats/:id` `{slow_mode_sec, join_approval}` | Slow mode (0/10/30/60/300/900/3600 s), approve new members |
| `GET/POST /api/chats/:id/invites`, `DELETE …/invites/:code` | Extra invite links with expiry / usage limit |
| `GET /api/chats/:id/join-requests`, `POST …/:userId/approve\|decline` | Join requests |
| `PUT /api/chats/:id/owner` `{user_id}` | Transfer ownership |
| `GET /api/me/export` | Download my data (JSON) |
| `POST /api/appeals` `{appeal_token, message}` | Banned user appeals (token comes with the `account_banned` error at login) |
| `GET /api/pages/:slug` (`terms`, `privacy`, `faq`, `about`) — also as HTML at `/p/:slug` | Legal pages & FAQ |
| **Batch B — calls** | |
| `POST /api/calls` `{user_id\|chat_id, video}` → `{call, ice_servers}` | Start a call (same as socket `call:start`; status `busy` = line busy) |
| `POST /api/calls/:id/accept\|decline\|hangup\|rate` | Answer, decline, hang up, rate 1–5 after the call |
| `GET /api/calls?missed=1&before=`, `POST /api/calls/delete` `{ids\|all}` | Call history |
| `GET /api/calls/active`, `GET /api/calls/ice-servers` | Ringing/ongoing call (after opening a call notification), STUN/TURN list |
| `PUT /api/me/privacy` `{calls}` | Who can call me: everyone / contacts / nobody |
| **Batch C — secret chats** (ciphertext only; also over Socket.IO `secret:*`) | |
| `GET /api/secret-chats`, `GET /api/secret-chats/pending` | This device's secret chats / undelivered encrypted messages |
| `POST /api/secret-chats` `{user_id, public_key}`, `POST …/:id/accept` `{public_key}`, `POST …/:id/close` | Key exchange, decline / close |
| `POST /api/secret-chats/:id/messages` `{ciphertext, media_id?, ttl_sec, client_id}` | Relay an encrypted message to the other device |
| `POST /api/secret-chats/:id/ack` `{message_ids}`, `POST …/:id/read` `{max_id}` | Delivered (server deletes the ciphertext) / read |
| **Batch D** | |
| `GET/POST /api/bots`, `PATCH/DELETE /api/bots/:id`, `POST /api/bots/:id/token` | My bots (create → token) |
| `POST /api/messages/:id/callback` `{data}` | Press an inline button (answer arrives as socket `bot:callback_answer`) |
| `POST /api/bots/:id/web-app`, `POST /api/bots/:id/web-app-data` | Mini app launch data / send data to the bot |
| `GET /api/chats/:id/messages?thread_id=` · send with `{thread_id}` · `PATCH /api/chats/:id {comments_enabled}` | Channel comments |
| `GET/POST /api/chats/:id/topics`, `PATCH/DELETE …/topics/:topicId` · `?topic_id=` / `{topic_id}` · `PATCH {is_forum}` | Group topics |
| `GET /api/premium`, `POST /api/payments/checkout` `{plan_id, provider}` | Plans & perks; start a JazzCash / Easypaisa / manual payment |
| `GET /api/payments/orders[/:id]`, `POST …/:id/proof` `{media_id, txn_id, sender}`, `POST …/:id/cancel` | Payment status, manual-payment screenshot |
| `GET /api/chats/:id/sponsored`, `POST /api/ads/:id/view\|click` | Sponsored message under a big public channel |
| **Batch E** | |
| `POST /api/auth/qr` → `{token, qr}`, `GET /api/auth/qr/status?token=&wait=25` | Web/desktop: show a login QR, long-poll until the phone approves (tokens once) |
| `POST /api/auth/qr/scan\|approve\|decline` `{token}` | Phone side of QR login |
| `POST /api/chats/:id/messages` `{type:"image", media_id, album_id}` | Photos sent together (album) |

Socket.IO events are documented at the top of `src/realtime/socket.js`
(`message:send` with ack, `message:new`, receipts, typing, presence, `session:revoked`, …).

Admin API (`/api/admin`): login (with 2FA code), dashboard, users (ban / unban / restrict / log out / verify / delete),
reports (resolve with delete / restrict / ban / suspend), groups & channels (suspend / verify / delete),
support desk, broadcasts, settings (incl. moderation), admin team (roles, reset 2FA), activity log, own 2FA setup —
and in Batch A: ban appeals, moderator notes, user data export, set/reserve usernames, group members & owner transfer,
IP blacklist, feature flags, pages & FAQ editor, broadcasts to app versions below X.

## Automatic moderation (Phase 2)

Configured in the admin panel → Settings → *Moderation & spam*:

- **Banned words** — block the message, or send it and open an automatic report ("flag").
- **Links from new accounts** — accounts younger than N hours cannot send links.
- **Copy-paste spam** — the same text sent to N chats within 10 minutes restricts the sender automatically.
- **Mass reports** — reports from N different people within 24 hours restrict the account pending review.
- **Blocked phone prefixes** — numbers starting with these cannot sign up.

A *restricted* user can read but not send; moderators can lift or apply restrictions from the user page.

## Admin two-factor authentication

Each admin can turn on 2FA (Google Authenticator / Authy) from the panel sidebar and gets 8 one-time backup codes.
Settings → Security → *Require 2FA for all admins* forces everyone to set it up. A super admin can reset
another admin's 2FA from *Admin team* if they lose their phone.

Scheduled messages are published by the server every 15 seconds (no cron job needed).

## Voice & video calls (Batch B)

Calls are one-to-one WebRTC calls. The server only rings, relays the WebRTC offer/answer/ICE
messages over Socket.IO (`call:start`, `call:accept`, `call:signal`, `call:hangup`, …, see
`src/realtime/socket.js`) and keeps the history — audio and video go directly between the two
phones, or through your TURN server when a direct path isn't possible.

**Install a TURN server (coturn) — needed for reliable calls on mobile data:**

```bash
sudo apt install coturn
sudo nano /etc/turnserver.conf
```
```
listening-port=3478
tls-listening-port=5349
fingerprint
use-auth-secret
static-auth-secret=PUT_A_LONG_RANDOM_SECRET_HERE
realm=turn.yourdomain.com
cert=/etc/letsencrypt/live/turn.yourdomain.com/fullchain.pem
pkey=/etc/letsencrypt/live/turn.yourdomain.com/privkey.pem
no-multicast-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
```
```bash
sudo sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
sudo systemctl restart coturn
sudo ufw allow 3478 && sudo ufw allow 5349 && sudo ufw allow 49152:65535/udp
```
Then in the backend `.env`: `TURN_SECRET=` (same secret) and
`TURN_URLS=turn:turn.yourdomain.com:3478?transport=udp,turn:turn.yourdomain.com:3478?transport=tcp,turns:turn.yourdomain.com:5349`.
The admin panel → *Calls* page shows whether TURN is configured.

Admin panel → Settings → *Calls*: switch voice/video calls on or off, ring time, longest call, extra STUN/TURN URLs.
Admin panel → *Calls*: live and past calls, answer rate, average length and rating, failed calls, force-end a call.

Not included yet: group calls (needs an SFU such as LiveKit) and the native iOS CallKit / Android
full-screen incoming-call UI when the app is closed — today a closed app gets a push notification,
and tapping it opens the ringing call.

## Vault chats — end-to-end encrypted (Batch C)

End-to-end encrypted chats between **one device on each side** (shown in the app as "Vault chat"; the API calls them secret chats):

- Each phone makes a new X25519 key pair for the chat; only the public keys pass through the server.
- Both phones compute the same secret (X25519 → HKDF-SHA256) and encrypt every message with
  AES-256-GCM using a fresh key from a hash ratchet, so old messages stay safe even if a key leaks later.
- The server stores only ciphertext until the other phone confirms delivery, then deletes it
  (rows are purged after 2 days; undelivered ones after 30 days). Photos/files are encrypted on the
  phone before upload; the file key travels inside the encrypted message.
- Self-destruct timer, "delete for both", screenshots blocked, no forwarding, key fingerprint (emoji) to compare.
- Logging out or revoking the device closes its secret chats for good.

Admins and the server **cannot read vault chats** — the panel only shows counts, and the feature can be
switched off in Settings → Features. Reports about a secret chat need the user to include what they saw.

## Bots (Batch D)

Users create bots in the app (Settings → My bots) and get a token (`tlv_<id>_<secret>`). The Talvio Bot API:

```bash
API=https://chat.example.com/api/bot/v1
AUTH="Authorization: Bearer <TOKEN>"
curl -X POST $API/me -H "$AUTH"
curl -X POST "$API/updates?timeout=30" -H "$AUTH"                       # long polling
curl -X POST $API/messages.send -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"chat_id": 42, "text": "Kaun sa shehar?", "reply_markup": {"inline_keyboard": [[{"text":"Lahore","callback_data":"lhr"}]]}}'
curl -X POST $API/webhook.set -H "$AUTH" -d url=https://yourbot.example.com/hook -d secret_token=abc
```

Every call answers `{ "ok": true, "data": … }` or `{ "ok": false, "error": { "code", "message" } }`.

Methods: `me`, `updates`, `webhook.set`, `webhook.delete`, `webhook.info`, `messages.send`, `photos.send`,
`files.send` (multipart field `photo` / `document`), `messages.edit`, `messages.edit-buttons`, `messages.delete`,
`buttons.answer`, `commands.set`, `commands.get`, `commands.delete`, `chats.get`,
`chat.action` (`action`: typing, uploading_photo, recording_voice …), `polls.send` (`question`, `options`,
`type`=quiz, `correct_option_id`, `open_period`), `locations.send` (`latitude`, `longitude`), `messages.forward`
(`from_chat_id`, `message_id`), `messages.pin`, `messages.unpin`, `chats.member` (`user_id`),
`chats.member-count`, `me.set` (`name`, `description`, `menu_url`). Updates: `message`,
`callback_query`, and `message.web_app_data`. Webhooks get the header `X-Talvio-Webhook-Secret`.

**Keyboards:** `reply_markup` takes `inline_keyboard` (buttons under the message), `keyboard` (big buttons that
replace the phone keyboard — `resize_keyboard`, `one_time_keyboard`, `input_field_placeholder`,
`request_location`) or `{"remove_keyboard": true}`. The app shows a **Menu** button in bot chats (mini app or
commands). **Deep links:** `https://<server>/c/<botname>?start=ref123` opens the bot and sends `/start ref123`.

**Mini apps:** a `web_app` button (or the bot's menu URL) opens the page inside the app with
`#talvioData=<init data>` and `window.Talvio = { initData, user, close(), sendData(text) }`.
Verify init data on your server: `secret = HMAC_SHA256(key="TalvioMiniApp", msg=SHA256_HEX(token))`,
`hash = HEX(HMAC_SHA256(key=secret, msg=data_check_string))` where data_check_string is every field except
`hash`, sorted, as `key=value` lines joined by `\n`.

**BotForge:** a built-in bot (@BotForge, created on start) makes and manages bots from a chat:
`/newbot`, `/mybots` (buttons: token, edit name/description/commands/photo, mini app, group privacy, revoke,
delete), `/setcommands`, `/setuserpic`, `/setmenu`, `/setprivacy`, `/deletebot`, `/cancel`.

## Privacy, security & group protection

- Privacy: last seen, photo, phone, birthday, **bio**, **forwarded messages** (link to your account),
  **who can message me** (everybody / contacts), group invites, calls, **who can find me by number** — with
  always/never exceptions. Default **auto-delete timer** for new chats, **log out inactive devices** after
  1 week–1 year, **delete my account if away** 1 month–2 years, hide from username search, Security checkup.
- Groups: **human check** for new members (removed after 5 minutes if not verified), **anti-flood**,
  **block links**, **blocked words**, **member permissions** (media, voice, stickers, polls, links),
  hide join/leave messages — admins are never limited.

## Talvio Plus (premium), payments & ads (Batch D)

- **Premium plans** are edited in the admin panel (default: 1 month Rs 299, 12 months Rs 2,999).
  Perks: ⭐ badge, bigger uploads (Settings → Premium & payments), 30 chat folders, no sponsored messages.
- **Manual payments** (works from day one): the user sends money to your JazzCash/Easypaisa/bank account,
  uploads the screenshot + transaction ID, and you approve it under *Payments*. Edit the instructions in Settings.
- **JazzCash** hosted page: set `JAZZCASH_MERCHANT_ID`, `JAZZCASH_PASSWORD`, `JAZZCASH_INTEGRITY_SALT`
  and `PUBLIC_URL`. Return URL: `https://<server>/pay/jazzcash/return`. Activation is automatic after the
  signed callback (pp_ResponseCode `000`).
- **Easypaisa** hosted page: set `EASYPAISA_STORE_ID`, `EASYPAISA_HASH_KEY`; add `EASYPAISA_USERNAME`,
  `EASYPAISA_PASSWORD`, `EASYPAISA_ACCOUNT_NUM` for automatic confirmation via the Inquire API — without
  them, Easypaisa payments wait for an admin under *Payments → To review*.
- Both gateways start in **sandbox** mode (`*_SANDBOX=true`). Test a full payment in sandbox with your own
  merchant credentials, then set `*_SANDBOX=false`. Field names and hash rules follow the JazzCash
  "Page Redirection 1.1" and Easypaisa "Easypay" hosted-checkout guides — if your merchant account uses
  a different version, adjust `src/services/payments/*.js`.
- **Sponsored messages:** admin → *Sponsored messages* → campaign (text, button, link, target channels,
  view limit, end date, price). Shown under big public channels (Settings → minimum size), never to Premium users.
- **Revenue:** admin → *Revenue* — Premium + ads income by month and by payment method.

## Web & desktop app (Batch E)

`https://<your server>/web` is a complete chat client for computers (no build step — plain files in
`web-client/`). Log in by scanning the QR code with the phone (Settings → Devices → Link a device) or
with phone number + code. Realtime through Socket.IO (falls back to polling), photos/albums, files,
voice, polls, reactions, replies, edit/delete, drag-and-drop & paste to send files, browser notifications,
dark mode. It is an installable PWA: in Chrome/Edge choose **Install Talvio** to get a desktop app
(Windows, macOS, Linux) with its own window and taskbar icon. Calls and secret chats stay on the phone.

## Scaling later

Rate limits and online status are kept in memory (one process). When you run several
instances, move them to Redis and add the Socket.IO Redis adapter. Uploads are stored on
local disk (`UPLOAD_DIR`); move to S3-compatible storage + CDN when needed.
