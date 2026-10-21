# ChatApp backend — Node.js + PostgreSQL + Socket.IO

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

15 end-to-end tests cover OTP login & token refresh, profiles & privacy, private chats,
receipts, pagination, edit/delete, blocking, groups & roles & invites, media access control,
forwarding, reports, the admin flows (ban, report resolution, settings, roles) and account deletion.

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

Socket.IO events are documented at the top of `src/realtime/socket.js`
(`message:send` with ack, `message:new`, receipts, typing, presence, `session:revoked`, …).

Admin API (`/api/admin`): login, dashboard, users (ban / unban / log out / verify / delete),
reports (resolve with delete / ban / suspend), groups (suspend / delete), settings, admin team, activity log.

## Scaling later

Rate limits and online status are kept in memory (one process). When you run several
instances, move them to Redis and add the Socket.IO Redis adapter. Uploads are stored on
local disk (`UPLOAD_DIR`); move to S3-compatible storage + CDN when needed.
