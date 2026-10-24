-- ChatApp Phase 1 schema (PostgreSQL 13+). Safe to run repeatedly.

-- ---------------------------------------------------------------- users
CREATE TABLE IF NOT EXISTS users (
  id                BIGSERIAL PRIMARY KEY,
  phone             VARCHAR(32)  NOT NULL UNIQUE,
  username          VARCHAR(32),
  first_name        VARCHAR(64)  NOT NULL DEFAULT '',
  last_name         VARCHAR(64)  NOT NULL DEFAULT '',
  bio               VARCHAR(140) NOT NULL DEFAULT '',
  avatar_media_id   BIGINT,
  status            VARCHAR(16)  NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'banned', 'deleted')),
  ban_reason        TEXT,
  banned_until      TIMESTAMPTZ,
  is_verified       BOOLEAN      NOT NULL DEFAULT FALSE,
  privacy_last_seen VARCHAR(10)  NOT NULL DEFAULT 'everyone'
                    CHECK (privacy_last_seen IN ('everyone', 'contacts', 'nobody')),
  privacy_avatar    VARCHAR(10)  NOT NULL DEFAULT 'everyone'
                    CHECK (privacy_avatar IN ('everyone', 'contacts', 'nobody')),
  privacy_phone     VARCHAR(10)  NOT NULL DEFAULT 'contacts'
                    CHECK (privacy_phone IN ('everyone', 'contacts', 'nobody')),
  privacy_group_add VARCHAR(10)  NOT NULL DEFAULT 'everyone'
                    CHECK (privacy_group_add IN ('everyone', 'contacts', 'nobody')),
  last_seen_at      TIMESTAMPTZ,
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS users_username_lower_uq ON users (lower(username)) WHERE username IS NOT NULL;
CREATE INDEX IF NOT EXISTS users_created_at_idx ON users (created_at);
CREATE INDEX IF NOT EXISTS users_last_seen_idx ON users (last_seen_at);

-- ---------------------------------------------------------------- sessions (one per logged-in device)
CREATE TABLE IF NOT EXISTS sessions (
  id                 BIGSERIAL PRIMARY KEY,
  user_id            BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  refresh_token_hash CHAR(64)     NOT NULL UNIQUE,
  device_name        VARCHAR(100) NOT NULL DEFAULT '',
  platform           VARCHAR(20)  NOT NULL DEFAULT '',
  app_version        VARCHAR(20)  NOT NULL DEFAULT '',
  ip                 VARCHAR(64),
  fcm_token          TEXT,
  created_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
  last_active_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
  expires_at         TIMESTAMPTZ  NOT NULL,
  revoked_at         TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS sessions_user_active_idx ON sessions (user_id) WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------- OTP codes
CREATE TABLE IF NOT EXISTS otp_codes (
  id          BIGSERIAL PRIMARY KEY,
  phone       VARCHAR(32) NOT NULL,
  code_hash   CHAR(64)    NOT NULL,
  attempts    INT         NOT NULL DEFAULT 0,
  ip          VARCHAR(64),
  expires_at  TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS otp_codes_phone_idx ON otp_codes (phone, created_at DESC);

-- ---------------------------------------------------------------- contacts & blocks
CREATE TABLE IF NOT EXISTS contacts (
  owner_id   BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  contact_id BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_id, contact_id)
);
CREATE INDEX IF NOT EXISTS contacts_contact_idx ON contacts (contact_id);

CREATE TABLE IF NOT EXISTS blocks (
  blocker_id BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id)
);
CREATE INDEX IF NOT EXISTS blocks_blocked_idx ON blocks (blocked_id);

-- ---------------------------------------------------------------- media (uploaded files)
CREATE TABLE IF NOT EXISTS media (
  id            BIGSERIAL PRIMARY KEY,
  uploader_id   BIGINT       REFERENCES users(id) ON DELETE SET NULL,
  kind          VARCHAR(10)  NOT NULL CHECK (kind IN ('image', 'video', 'voice', 'file', 'avatar')),
  mime          VARCHAR(100) NOT NULL,
  size_bytes    BIGINT       NOT NULL,
  storage_path  TEXT         NOT NULL,
  original_name VARCHAR(255) NOT NULL DEFAULT '',
  duration_sec  INT,
  width         INT,
  height        INT,
  is_public     BOOLEAN      NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS media_uploader_idx ON media (uploader_id);

-- ---------------------------------------------------------------- chats (private + group)
CREATE TABLE IF NOT EXISTS chats (
  id              BIGSERIAL PRIMARY KEY,
  type            VARCHAR(10)  NOT NULL CHECK (type IN ('private', 'group')),
  private_key     VARCHAR(50)  UNIQUE,            -- "minUserId:maxUserId" for private chats
  title           VARCHAR(128) NOT NULL DEFAULT '',
  description     VARCHAR(255) NOT NULL DEFAULT '',
  avatar_media_id BIGINT       REFERENCES media(id) ON DELETE SET NULL,
  created_by      BIGINT       REFERENCES users(id) ON DELETE SET NULL,
  invite_code     VARCHAR(32)  UNIQUE,
  is_suspended    BOOLEAN      NOT NULL DEFAULT FALSE,
  suspend_reason  TEXT,
  last_message_id BIGINT,
  last_message_at TIMESTAMPTZ,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS chats_type_idx ON chats (type, created_at DESC);

CREATE TABLE IF NOT EXISTS chat_members (
  chat_id                   BIGINT      NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  user_id                   BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role                      VARCHAR(10) NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member')),
  joined_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_read_message_id      BIGINT      NOT NULL DEFAULT 0,
  last_delivered_message_id BIGINT      NOT NULL DEFAULT 0,
  cleared_before_id         BIGINT      NOT NULL DEFAULT 0,  -- "clear history" for this user
  muted_until               TIMESTAMPTZ,
  is_pinned                 BOOLEAN     NOT NULL DEFAULT FALSE,
  is_archived               BOOLEAN     NOT NULL DEFAULT FALSE,
  is_hidden                 BOOLEAN     NOT NULL DEFAULT FALSE, -- private chat deleted from list (reappears on new message)
  PRIMARY KEY (chat_id, user_id)
);
CREATE INDEX IF NOT EXISTS chat_members_user_idx ON chat_members (user_id);

-- ---------------------------------------------------------------- messages
CREATE TABLE IF NOT EXISTS messages (
  id                     BIGSERIAL PRIMARY KEY,
  chat_id                BIGINT       NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  sender_id              BIGINT       REFERENCES users(id) ON DELETE SET NULL,
  type                   VARCHAR(10)  NOT NULL CHECK (type IN ('text', 'image', 'video', 'voice', 'file', 'system')),
  text                   TEXT         NOT NULL DEFAULT '',
  media_id               BIGINT       REFERENCES media(id) ON DELETE SET NULL,
  reply_to_id            BIGINT       REFERENCES messages(id) ON DELETE SET NULL,
  forwarded_from_user_id BIGINT       REFERENCES users(id) ON DELETE SET NULL,
  forwarded_from_name    VARCHAR(130),
  meta                   JSONB,
  client_id              VARCHAR(64),
  edited_at              TIMESTAMPTZ,
  deleted_at             TIMESTAMPTZ,
  created_at             TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS messages_chat_id_idx ON messages (chat_id, id DESC);
CREATE INDEX IF NOT EXISTS messages_media_idx ON messages (media_id) WHERE media_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS messages_created_idx ON messages (created_at);
CREATE UNIQUE INDEX IF NOT EXISTS messages_client_id_uq ON messages (sender_id, client_id) WHERE client_id IS NOT NULL;

-- "Delete for me"
CREATE TABLE IF NOT EXISTS message_hidden (
  user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  message_id BIGINT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, message_id)
);

-- ---------------------------------------------------------------- admins
CREATE TABLE IF NOT EXISTS admins (
  id            BIGSERIAL PRIMARY KEY,
  email         VARCHAR(255) NOT NULL UNIQUE,
  password_hash TEXT         NOT NULL,
  name          VARCHAR(100) NOT NULL DEFAULT '',
  role          VARCHAR(20)  NOT NULL DEFAULT 'moderator' CHECK (role IN ('super_admin', 'moderator', 'support')),
  is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
  token_version INT          NOT NULL DEFAULT 0,
  last_login_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS admin_logs (
  id          BIGSERIAL PRIMARY KEY,
  admin_id    BIGINT      REFERENCES admins(id) ON DELETE SET NULL,
  action      VARCHAR(64) NOT NULL,
  target_type VARCHAR(20),
  target_id   BIGINT,
  details     JSONB,
  ip          VARCHAR(64),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_logs_created_idx ON admin_logs (created_at DESC);

-- ---------------------------------------------------------------- reports
CREATE TABLE IF NOT EXISTS reports (
  id           BIGSERIAL PRIMARY KEY,
  reporter_id  BIGINT       REFERENCES users(id) ON DELETE SET NULL,
  target_type  VARCHAR(10)  NOT NULL CHECK (target_type IN ('user', 'message', 'chat')),
  target_id    BIGINT       NOT NULL,
  reason       VARCHAR(20)  NOT NULL CHECK (reason IN ('spam', 'abuse', 'scam', 'violence', 'sexual', 'illegal', 'other')),
  details      VARCHAR(1000) NOT NULL DEFAULT '',
  snapshot     JSONB,
  status       VARCHAR(10)  NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'dismissed')),
  action_taken VARCHAR(30),
  admin_note   TEXT,
  resolved_by  BIGINT       REFERENCES admins(id) ON DELETE SET NULL,
  resolved_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS reports_status_idx ON reports (status, created_at DESC);
CREATE INDEX IF NOT EXISTS reports_target_idx ON reports (target_type, target_id);
CREATE UNIQUE INDEX IF NOT EXISTS reports_open_dedupe_uq
  ON reports (reporter_id, target_type, target_id) WHERE status = 'open';

-- ---------------------------------------------------------------- app settings (admin editable)
CREATE TABLE IF NOT EXISTS app_settings (
  key        VARCHAR(64) PRIMARY KEY,
  value      JSONB       NOT NULL,
  updated_by BIGINT      REFERENCES admins(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- Phase 2 — channels, polls, reactions, folders, stories, scheduled posts,
--           moderation, broadcast, support tickets, admin 2FA
-- (ALTERs are idempotent so existing Phase 1 databases upgrade in place)
-- =====================================================================

-- channels + public usernames for groups/channels
ALTER TABLE chats DROP CONSTRAINT IF EXISTS chats_type_check;
ALTER TABLE chats ADD CONSTRAINT chats_type_check CHECK (type IN ('private', 'group', 'channel'));
ALTER TABLE chats ADD COLUMN IF NOT EXISTS username    VARCHAR(32);
ALTER TABLE chats ADD COLUMN IF NOT EXISTS is_public   BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS signatures  BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS is_verified BOOLEAN NOT NULL DEFAULT FALSE;
CREATE UNIQUE INDEX IF NOT EXISTS chats_username_lower_uq ON chats (lower(username)) WHERE username IS NOT NULL;
CREATE INDEX IF NOT EXISTS chat_members_joined_idx ON chat_members (chat_id, joined_at);

-- polls & views on messages
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_type_check
  CHECK (type IN ('text', 'image', 'video', 'voice', 'file', 'system', 'poll'));
ALTER TABLE messages ADD COLUMN IF NOT EXISTS views_count INT NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS messages_sender_created_idx ON messages (sender_id, created_at DESC);

CREATE TABLE IF NOT EXISTS message_views (
  message_id BIGINT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  viewed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

CREATE TABLE IF NOT EXISTS message_reactions (
  message_id BIGINT      NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji      VARCHAR(16) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

CREATE TABLE IF NOT EXISTS polls (
  id             BIGSERIAL PRIMARY KEY,
  message_id     BIGINT       UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
  question       VARCHAR(300) NOT NULL,
  is_anonymous   BOOLEAN      NOT NULL DEFAULT TRUE,
  multiple       BOOLEAN      NOT NULL DEFAULT FALSE,
  is_quiz        BOOLEAN      NOT NULL DEFAULT FALSE,
  correct_option INT,
  explanation    VARCHAR(200) NOT NULL DEFAULT '',
  closed_at      TIMESTAMPTZ,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS poll_options (
  poll_id BIGINT       NOT NULL REFERENCES polls(id) ON DELETE CASCADE,
  idx     INT          NOT NULL,
  text    VARCHAR(100) NOT NULL,
  PRIMARY KEY (poll_id, idx)
);
CREATE TABLE IF NOT EXISTS poll_votes (
  poll_id    BIGINT      NOT NULL REFERENCES polls(id) ON DELETE CASCADE,
  user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  option_idx INT         NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (poll_id, user_id, option_idx)
);

-- scheduled messages
CREATE TABLE IF NOT EXISTS scheduled_messages (
  id           BIGSERIAL PRIMARY KEY,
  chat_id      BIGINT      NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  sender_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  payload      JSONB       NOT NULL,
  send_at      TIMESTAMPTZ NOT NULL,
  status       VARCHAR(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
  error        TEXT,
  message_id   BIGINT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS scheduled_due_idx ON scheduled_messages (send_at) WHERE status = 'pending';

-- chat folders
CREATE TABLE IF NOT EXISTS chat_folders (
  id               BIGSERIAL PRIMARY KEY,
  user_id          BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name             VARCHAR(24) NOT NULL,
  chat_ids         JSONB       NOT NULL DEFAULT '[]',
  include_private  BOOLEAN     NOT NULL DEFAULT FALSE,
  include_groups   BOOLEAN     NOT NULL DEFAULT FALSE,
  include_channels BOOLEAN     NOT NULL DEFAULT FALSE,
  include_unread_only BOOLEAN  NOT NULL DEFAULT FALSE,
  position         INT         NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS chat_folders_user_idx ON chat_folders (user_id, position);

-- stories
CREATE TABLE IF NOT EXISTS stories (
  id          BIGSERIAL PRIMARY KEY,
  user_id     BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_id    BIGINT       NOT NULL REFERENCES media(id) ON DELETE CASCADE,
  caption     VARCHAR(500) NOT NULL DEFAULT '',
  privacy     VARCHAR(10)  NOT NULL DEFAULT 'contacts' CHECK (privacy IN ('everyone', 'contacts')),
  views_count INT          NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  expires_at  TIMESTAMPTZ  NOT NULL,
  deleted_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS stories_user_active_idx ON stories (user_id, expires_at) WHERE deleted_at IS NULL;
CREATE TABLE IF NOT EXISTS story_views (
  story_id  BIGINT      NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
  viewer_id BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji     VARCHAR(16),
  viewed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (story_id, viewer_id)
);

-- moderation
ALTER TABLE users ADD COLUMN IF NOT EXISTS restricted_until TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS restrict_reason  TEXT;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS source VARCHAR(10) NOT NULL DEFAULT 'user';

-- broadcast announcements
CREATE TABLE IF NOT EXISTS announcements (
  id           BIGSERIAL PRIMARY KEY,
  title        VARCHAR(120)  NOT NULL,
  body         VARCHAR(1000) NOT NULL,
  target       JSONB         NOT NULL DEFAULT '{}',
  in_app       BOOLEAN       NOT NULL DEFAULT TRUE,
  push         BOOLEAN       NOT NULL DEFAULT FALSE,
  recipients   INT           NOT NULL DEFAULT 0,
  created_by   BIGINT        REFERENCES admins(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
  expires_at   TIMESTAMPTZ
);
CREATE TABLE IF NOT EXISTS announcement_dismissals (
  announcement_id BIGINT NOT NULL REFERENCES announcements(id) ON DELETE CASCADE,
  user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  PRIMARY KEY (announcement_id, user_id)
);

-- support tickets
CREATE TABLE IF NOT EXISTS support_tickets (
  id          BIGSERIAL PRIMARY KEY,
  user_id     BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  subject     VARCHAR(150) NOT NULL,
  category    VARCHAR(20)  NOT NULL DEFAULT 'other'
              CHECK (category IN ('account', 'bug', 'abuse', 'payment', 'feature', 'other')),
  status      VARCHAR(10)  NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'pending', 'resolved', 'closed')),
  priority    VARCHAR(10)  NOT NULL DEFAULT 'normal' CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
  assigned_to BIGINT       REFERENCES admins(id) ON DELETE SET NULL,
  user_unread BOOLEAN      NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS support_tickets_status_idx ON support_tickets (status, updated_at DESC);
CREATE INDEX IF NOT EXISTS support_tickets_user_idx ON support_tickets (user_id, updated_at DESC);
CREATE TABLE IF NOT EXISTS support_messages (
  id         BIGSERIAL PRIMARY KEY,
  ticket_id  BIGINT        NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE,
  admin_id   BIGINT        REFERENCES admins(id) ON DELETE SET NULL,
  from_user  BOOLEAN       NOT NULL,
  text       VARCHAR(4000) NOT NULL,
  created_at TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS support_messages_ticket_idx ON support_messages (ticket_id, id);

-- admin two-factor authentication (TOTP)
ALTER TABLE admins ADD COLUMN IF NOT EXISTS totp_secret  TEXT;
ALTER TABLE admins ADD COLUMN IF NOT EXISTS totp_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE admins ADD COLUMN IF NOT EXISTS backup_codes JSONB;

-- =====================================================================
-- Batch A — pins, mentions, unread marks, silent & location messages, message search,
--           slow mode, join requests, invite links, appeals, notes, content pages
-- =====================================================================
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_type_check
  CHECK (type IN ('text', 'image', 'video', 'voice', 'file', 'system', 'poll', 'location'));
ALTER TABLE messages ADD COLUMN IF NOT EXISTS silent BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS messages_fts_idx ON messages USING GIN (to_tsvector('simple', text));

CREATE TABLE IF NOT EXISTS pinned_messages (
  chat_id    BIGINT      NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  message_id BIGINT      NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  pinned_by  BIGINT      REFERENCES users(id) ON DELETE SET NULL,
  pinned_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (chat_id, message_id)
);

CREATE TABLE IF NOT EXISTS message_mentions (
  message_id BIGINT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  chat_id    BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  PRIMARY KEY (message_id, user_id)
);
CREATE INDEX IF NOT EXISTS message_mentions_user_idx ON message_mentions (user_id, chat_id, message_id);

ALTER TABLE chat_members ADD COLUMN IF NOT EXISTS marked_unread BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS slow_mode_sec INT NOT NULL DEFAULT 0;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS join_approval BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS chat_join_requests (
  chat_id     BIGINT      NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  user_id     BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  invite_code VARCHAR(32),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (chat_id, user_id)
);

CREATE TABLE IF NOT EXISTS chat_invites (
  code        VARCHAR(32) PRIMARY KEY,
  chat_id     BIGINT      NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  created_by  BIGINT      REFERENCES users(id) ON DELETE SET NULL,
  name        VARCHAR(32) NOT NULL DEFAULT '',
  expires_at  TIMESTAMPTZ,
  usage_limit INT,
  usage_count INT         NOT NULL DEFAULT 0,
  revoked     BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS chat_invites_chat_idx ON chat_invites (chat_id);

CREATE TABLE IF NOT EXISTS ban_appeals (
  id          BIGSERIAL PRIMARY KEY,
  user_id     BIGINT        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  message     VARCHAR(2000) NOT NULL,
  status      VARCHAR(10)   NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'rejected')),
  admin_reply VARCHAR(1000),
  resolved_by BIGINT        REFERENCES admins(id) ON DELETE SET NULL,
  resolved_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ban_appeals_status_idx ON ban_appeals (status, created_at DESC);

CREATE TABLE IF NOT EXISTS admin_notes (
  id         BIGSERIAL PRIMARY KEY,
  user_id    BIGINT        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  admin_id   BIGINT        REFERENCES admins(id) ON DELETE SET NULL,
  text       VARCHAR(2000) NOT NULL,
  created_at TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_notes_user_idx ON admin_notes (user_id, id DESC);

CREATE TABLE IF NOT EXISTS content_pages (
  slug       VARCHAR(32)  PRIMARY KEY,
  title      VARCHAR(120) NOT NULL,
  body       TEXT         NOT NULL DEFAULT '',
  updated_by BIGINT       REFERENCES admins(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);
INSERT INTO content_pages (slug, title, body) VALUES
  ('terms', 'Terms of Service', ''),
  ('privacy', 'Privacy Policy', ''),
  ('faq', 'Frequently Asked Questions', '')
ON CONFLICT (slug) DO NOTHING;

-- =====================================================================
-- Batch B: voice & video calls
-- =====================================================================
ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_calls VARCHAR(10) NOT NULL DEFAULT 'everyone';
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_privacy_calls_check;
ALTER TABLE users ADD CONSTRAINT users_privacy_calls_check CHECK (privacy_calls IN ('everyone', 'contacts', 'nobody'));

ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_type_check
  CHECK (type IN ('text', 'image', 'video', 'voice', 'file', 'system', 'poll', 'location', 'call'));

CREATE TABLE IF NOT EXISTS calls (
  id                BIGSERIAL PRIMARY KEY,
  chat_id           BIGINT       REFERENCES chats(id) ON DELETE SET NULL,
  caller_id         BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  callee_id         BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  caller_session_id BIGINT,
  callee_session_id BIGINT,
  video             BOOLEAN      NOT NULL DEFAULT FALSE,
  status            VARCHAR(10)  NOT NULL DEFAULT 'ringing'
                    CHECK (status IN ('ringing', 'accepted', 'ended', 'missed', 'declined', 'busy', 'failed')),
  end_reason        VARCHAR(20),
  ended_by          BIGINT,
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
  answered_at       TIMESTAMPTZ,
  ended_at          TIMESTAMPTZ,
  rating_caller     SMALLINT     CHECK (rating_caller BETWEEN 1 AND 5),
  rating_callee     SMALLINT     CHECK (rating_callee BETWEEN 1 AND 5),
  rating_comment    VARCHAR(500),
  hidden_caller     BOOLEAN      NOT NULL DEFAULT FALSE,
  hidden_callee     BOOLEAN      NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS calls_caller_idx ON calls (caller_id, id DESC);
CREATE INDEX IF NOT EXISTS calls_callee_idx ON calls (callee_id, id DESC);
CREATE INDEX IF NOT EXISTS calls_active_idx ON calls (status) WHERE status IN ('ringing', 'accepted');
CREATE INDEX IF NOT EXISTS calls_created_idx ON calls (created_at DESC);

-- =====================================================================
-- Batch C: secret chats (end-to-end encrypted, device-to-device)
-- The server only ever sees public keys and ciphertext.
-- =====================================================================
CREATE TABLE IF NOT EXISTS secret_chats (
  id                    BIGSERIAL PRIMARY KEY,
  initiator_id          BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  initiator_session_id  BIGINT       NOT NULL,
  initiator_key         VARCHAR(100) NOT NULL,
  peer_id               BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  peer_session_id       BIGINT,
  peer_key              VARCHAR(100),
  status                VARCHAR(10)  NOT NULL DEFAULT 'requested'
                        CHECK (status IN ('requested', 'active', 'closed')),
  closed_by             BIGINT,
  close_reason          VARCHAR(20),
  created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
  accepted_at           TIMESTAMPTZ,
  closed_at             TIMESTAMPTZ,
  last_message_at       TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS secret_chats_init_idx ON secret_chats (initiator_session_id) WHERE status <> 'closed';
CREATE INDEX IF NOT EXISTS secret_chats_peer_idx ON secret_chats (peer_id, status);
CREATE INDEX IF NOT EXISTS secret_chats_peer_sess_idx ON secret_chats (peer_session_id) WHERE status <> 'closed';

CREATE TABLE IF NOT EXISTS secret_messages (
  id              BIGSERIAL PRIMARY KEY,
  secret_chat_id  BIGINT       NOT NULL REFERENCES secret_chats(id) ON DELETE CASCADE,
  sender_id       BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  client_id       VARCHAR(64),
  ciphertext      TEXT,                 -- NULL once delivered to the other device
  media_id        BIGINT       REFERENCES media(id) ON DELETE SET NULL,  -- encrypted blob
  ttl_sec         INTEGER      NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  delivered_at    TIMESTAMPTZ,
  read_at         TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS secret_messages_chat_idx ON secret_messages (secret_chat_id, id);
CREATE INDEX IF NOT EXISTS secret_messages_pending_idx ON secret_messages (secret_chat_id) WHERE delivered_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS secret_messages_client_idx ON secret_messages (sender_id, client_id) WHERE client_id IS NOT NULL;

-- =====================================================================
-- Batch D1: bots & mini apps, channel comments, group topics
-- =====================================================================
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_bot BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE users ALTER COLUMN phone DROP NOT NULL;

CREATE TABLE IF NOT EXISTS bots (
  user_id         BIGINT        PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  owner_id        BIGINT        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash      VARCHAR(64)   NOT NULL UNIQUE,
  about           VARCHAR(512)  NOT NULL DEFAULT '',
  commands        JSONB         NOT NULL DEFAULT '[]',
  menu_url        VARCHAR(500),
  webhook_url     VARCHAR(500),
  webhook_secret  VARCHAR(256),
  webhook_error   VARCHAR(300),
  webhook_error_at TIMESTAMPTZ,
  group_privacy   BOOLEAN       NOT NULL DEFAULT TRUE,
  status          VARCHAR(10)   NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  disabled_reason VARCHAR(300),
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
  last_used_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS bots_owner_idx ON bots (owner_id);

CREATE TABLE IF NOT EXISTS bot_updates (
  id          BIGSERIAL    PRIMARY KEY,
  bot_id      BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  payload     JSONB        NOT NULL,
  attempts    INTEGER      NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bot_updates_bot_idx ON bot_updates (bot_id, id);

CREATE TABLE IF NOT EXISTS bot_callback_queries (
  id          VARCHAR(32)  PRIMARY KEY,
  bot_id      BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_id     BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  message_id  BIGINT       NOT NULL,
  answered    BOOLEAN      NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_markup JSONB;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS via_bot_id BIGINT;

-- channel comments: replies under a post live in the same chat with thread_id = post id
ALTER TABLE chats ADD COLUMN IF NOT EXISTS comments_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS thread_id BIGINT;
CREATE INDEX IF NOT EXISTS messages_thread_idx ON messages (thread_id, id) WHERE thread_id IS NOT NULL;

-- group topics (forum mode)
ALTER TABLE chats ADD COLUMN IF NOT EXISTS is_forum BOOLEAN NOT NULL DEFAULT FALSE;
CREATE TABLE IF NOT EXISTS chat_topics (
  id          BIGSERIAL    PRIMARY KEY,
  chat_id     BIGINT       NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  title       VARCHAR(128) NOT NULL,
  icon_color  INTEGER      NOT NULL DEFAULT 0,
  created_by  BIGINT       REFERENCES users(id) ON DELETE SET NULL,
  is_closed   BOOLEAN      NOT NULL DEFAULT FALSE,
  is_pinned   BOOLEAN      NOT NULL DEFAULT FALSE,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  last_message_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS chat_topics_chat_idx ON chat_topics (chat_id);
ALTER TABLE messages ADD COLUMN IF NOT EXISTS topic_id BIGINT REFERENCES chat_topics(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS messages_topic_idx ON messages (topic_id, id) WHERE topic_id IS NOT NULL;

-- =====================================================================
-- Batch D2: premium, payments (JazzCash / Easypaisa / manual), sponsored messages, revenue
-- =====================================================================
ALTER TABLE users ADD COLUMN IF NOT EXISTS premium_until TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS premium_plans (
  id          BIGSERIAL    PRIMARY KEY,
  name        VARCHAR(60)  NOT NULL,
  months      INTEGER      NOT NULL CHECK (months BETWEEN 1 AND 60),
  price_pkr   INTEGER      NOT NULL CHECK (price_pkr >= 0),
  is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
  sort        INTEGER      NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
INSERT INTO premium_plans (name, months, price_pkr, sort)
SELECT * FROM (VALUES ('1 month', 1, 299, 1), ('12 months', 12, 2999, 2)) AS p(name, months, price_pkr, sort)
WHERE NOT EXISTS (SELECT 1 FROM premium_plans);

CREATE TABLE IF NOT EXISTS payment_orders (
  id               BIGSERIAL    PRIMARY KEY,
  user_id          BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan_id          BIGINT       REFERENCES premium_plans(id) ON DELETE SET NULL,
  months           INTEGER      NOT NULL,
  amount_pkr       INTEGER      NOT NULL,
  provider         VARCHAR(12)  NOT NULL CHECK (provider IN ('jazzcash', 'easypaisa', 'manual', 'admin')),
  status           VARCHAR(10)  NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'review', 'paid', 'failed', 'cancelled', 'rejected')),
  txn_ref          VARCHAR(40)  NOT NULL UNIQUE,
  provider_ref     VARCHAR(100),
  provider_message VARCHAR(300),
  raw_response     JSONB,
  proof_media_id   BIGINT       REFERENCES media(id) ON DELETE SET NULL,
  proof_txn_id     VARCHAR(60),
  proof_sender     VARCHAR(60),
  review_note      VARCHAR(300),
  reviewed_by      BIGINT       REFERENCES admins(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
  paid_at          TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS payment_orders_user_idx ON payment_orders (user_id, id DESC);
CREATE INDEX IF NOT EXISTS payment_orders_status_idx ON payment_orders (status, created_at DESC);

CREATE TABLE IF NOT EXISTS ad_campaigns (
  id               BIGSERIAL     PRIMARY KEY,
  advertiser       VARCHAR(80)   NOT NULL,
  text             VARCHAR(300)  NOT NULL,
  button_text      VARCHAR(30)   NOT NULL DEFAULT 'Open',
  url              VARCHAR(500)  NOT NULL,
  target_chat_ids  JSONB         NOT NULL DEFAULT '[]',   -- empty = all eligible public channels
  min_subscribers  INTEGER       NOT NULL DEFAULT 0,
  status           VARCHAR(10)   NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'ended')),
  starts_at        TIMESTAMPTZ,
  ends_at          TIMESTAMPTZ,
  max_impressions  INTEGER,
  impressions      INTEGER       NOT NULL DEFAULT 0,
  clicks           INTEGER       NOT NULL DEFAULT 0,
  price_pkr        INTEGER       NOT NULL DEFAULT 0,
  created_by       BIGINT        REFERENCES admins(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS ad_views (
  campaign_id  BIGINT   NOT NULL REFERENCES ad_campaigns(id) ON DELETE CASCADE,
  user_id      BIGINT   NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  day          DATE     NOT NULL DEFAULT current_date,
  clicked      BOOLEAN  NOT NULL DEFAULT FALSE,
  PRIMARY KEY (campaign_id, user_id, day)
);

-- =====================================================================
-- Batch E: QR login for web/desktop, photo albums
-- =====================================================================
CREATE TABLE IF NOT EXISTS qr_logins (
  id           BIGSERIAL    PRIMARY KEY,
  token_hash   VARCHAR(64)  NOT NULL UNIQUE,
  status       VARCHAR(10)  NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'scanned', 'approved', 'declined', 'consumed')),
  user_id      BIGINT       REFERENCES users(id) ON DELETE CASCADE,
  device_name  VARCHAR(100) NOT NULL DEFAULT '',
  platform     VARCHAR(10)  NOT NULL DEFAULT 'web',
  ip           VARCHAR(64),
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
  expires_at   TIMESTAMPTZ  NOT NULL
);
CREATE INDEX IF NOT EXISTS qr_logins_expiry_idx ON qr_logins (expires_at);

ALTER TABLE messages ADD COLUMN IF NOT EXISTS album_id VARCHAR(36);
CREATE INDEX IF NOT EXISTS messages_album_idx ON messages (album_id) WHERE album_id IS NOT NULL;

-- ---------------------------------------------------------------- email login
-- Accounts can sign in with a phone number (SMS code) or an email address (email code).
ALTER TABLE users ALTER COLUMN phone DROP NOT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS email VARCHAR(254);
CREATE UNIQUE INDEX IF NOT EXISTS users_email_lower_uq ON users (lower(email)) WHERE email IS NOT NULL;
-- otp_codes.phone holds the login target: "+92…" for SMS or "name@mail.com" for email codes
ALTER TABLE otp_codes ALTER COLUMN phone TYPE VARCHAR(254);

-- ---------------------------------------------------------------- crash reports from the apps (self-hosted)
CREATE TABLE IF NOT EXISTS client_errors (
  id           BIGSERIAL PRIMARY KEY,
  fingerprint  CHAR(64)     NOT NULL UNIQUE,
  platform     VARCHAR(16)  NOT NULL DEFAULT 'other',
  app_version  VARCHAR(20)  NOT NULL DEFAULT '',
  message      TEXT         NOT NULL,
  stack        TEXT         NOT NULL DEFAULT '',
  last_device  VARCHAR(100) NOT NULL DEFAULT '',
  last_user_id BIGINT,
  count        INT          NOT NULL DEFAULT 1,
  users_count  INT          NOT NULL DEFAULT 1,
  resolved_at  TIMESTAMPTZ,
  first_seen   TIMESTAMPTZ  NOT NULL DEFAULT now(),
  last_seen    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS client_errors_last_seen_idx ON client_errors (last_seen DESC);
CREATE TABLE IF NOT EXISTS client_error_users (
  error_id BIGINT NOT NULL REFERENCES client_errors(id) ON DELETE CASCADE,
  user_id  BIGINT NOT NULL,
  PRIMARY KEY (error_id, user_id)
);

-- ---------------------------------------------------------------- link previews
ALTER TABLE messages ADD COLUMN IF NOT EXISTS link_preview JSONB;
CREATE TABLE IF NOT EXISTS link_previews (
  url_hash   CHAR(64)    PRIMARY KEY,
  url        TEXT        NOT NULL,
  data       JSONB,
  fetched_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- stickers
CREATE TABLE IF NOT EXISTS sticker_packs (
  id            BIGSERIAL PRIMARY KEY,
  title         VARCHAR(64)  NOT NULL,
  slug          VARCHAR(40)  UNIQUE,
  owner_id      BIGINT REFERENCES users(id) ON DELETE SET NULL,
  is_official   BOOLEAN      NOT NULL DEFAULT FALSE,
  is_public     BOOLEAN      NOT NULL DEFAULT TRUE,
  installs      INT          NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS stickers (
  id         BIGSERIAL PRIMARY KEY,
  pack_id    BIGINT      NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
  media_id   BIGINT      NOT NULL REFERENCES media(id),
  emoji      VARCHAR(16) NOT NULL DEFAULT '',
  position   INT         NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS stickers_pack_idx ON stickers (pack_id, position);
CREATE TABLE IF NOT EXISTS user_sticker_packs (
  user_id  BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  pack_id  BIGINT      NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
  added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, pack_id)
);
ALTER TABLE media DROP CONSTRAINT IF EXISTS media_kind_check;
ALTER TABLE media ADD CONSTRAINT media_kind_check CHECK (kind IN ('image', 'video', 'voice', 'file', 'avatar', 'sticker'));
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_type_check
  CHECK (type IN ('text', 'image', 'video', 'voice', 'file', 'system', 'poll', 'location', 'call', 'sticker', 'gif', 'contact'));

-- ---------------------------------------------------------------- disappearing messages
ALTER TABLE chats ADD COLUMN IF NOT EXISTS disappear_after_sec INT NOT NULL DEFAULT 0;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS messages_expires_idx ON messages (expires_at) WHERE expires_at IS NOT NULL AND deleted_at IS NULL;

-- ---------------------------------------------------------------- two-step verification
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hint VARCHAR(64);
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_set_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_reset_after TIMESTAMPTZ;

-- ---------------------------------------------------------------- round video messages
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_type_check
  CHECK (type IN ('text', 'image', 'video', 'voice', 'video_note', 'file', 'system', 'poll', 'location', 'call', 'sticker', 'gif', 'contact'));

-- ---------------------------------------------------------------- message requests (spam protection)
ALTER TABLE chat_members ADD COLUMN IF NOT EXISTS is_request BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS message_requests BOOLEAN NOT NULL DEFAULT TRUE;

-- ---------------------------------------------------------------- passkeys (device key + fingerprint login)
CREATE TABLE IF NOT EXISTS user_passkeys (
  id           BIGSERIAL PRIMARY KEY,
  user_id      BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  public_key   TEXT         NOT NULL,
  name         VARCHAR(100) NOT NULL DEFAULT '',
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
  last_used_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS user_passkeys_user_idx ON user_passkeys (user_id);

-- ---------------------------------------------------------------- edit history
CREATE TABLE IF NOT EXISTS message_edits (
  id         BIGSERIAL PRIMARY KEY,
  message_id BIGINT      NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  text       TEXT        NOT NULL,
  edited_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS message_edits_msg_idx ON message_edits (message_id, id);

-- deleting a message (for everyone, expiry, admin) also wipes its earlier versions
CREATE OR REPLACE FUNCTION message_edits_purge() RETURNS trigger AS $$
BEGIN
  DELETE FROM message_edits WHERE message_id = NEW.id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS messages_purge_edits ON messages;
CREATE TRIGGER messages_purge_edits AFTER UPDATE OF deleted_at ON messages
  FOR EACH ROW WHEN (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL)
  EXECUTE FUNCTION message_edits_purge();

-- ---------------------------------------------------------------- view-once media, chat lock
CREATE TABLE IF NOT EXISTS message_once_views (
  message_id BIGINT      NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  opened_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);
ALTER TABLE chat_members ADD COLUMN IF NOT EXISTS is_locked BOOLEAN NOT NULL DEFAULT FALSE;

-- ---------------------------------------------------------------- groups & channels: admin rights, restrictions, log, welcome/rules
ALTER TABLE chat_members ADD COLUMN IF NOT EXISTS admin_rights JSONB;
ALTER TABLE chat_members ADD COLUMN IF NOT EXISTS admin_title VARCHAR(24);
ALTER TABLE chat_members ADD COLUMN IF NOT EXISTS restricted_until TIMESTAMPTZ;
ALTER TABLE chat_members ADD COLUMN IF NOT EXISTS draft TEXT;
ALTER TABLE chat_members ADD COLUMN IF NOT EXISTS draft_at TIMESTAMPTZ;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS welcome_text VARCHAR(500);
ALTER TABLE chats ADD COLUMN IF NOT EXISTS rules VARCHAR(2000);
ALTER TABLE chats ADD COLUMN IF NOT EXISTS new_member_limits BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS protected_content BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS allowed_reactions JSONB;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS category VARCHAR(24);
ALTER TABLE chats ADD COLUMN IF NOT EXISTS linked_chat_id BIGINT REFERENCES chats(id) ON DELETE SET NULL;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS forward_source_id BIGINT;
CREATE INDEX IF NOT EXISTS messages_fwd_source_idx ON messages (forward_source_id) WHERE forward_source_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS chats_directory_idx ON chats (category) WHERE type = 'channel' AND username IS NOT NULL;

CREATE TABLE IF NOT EXISTS chat_events (
  id         BIGSERIAL PRIMARY KEY,
  chat_id    BIGINT      NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  actor_id   BIGINT      REFERENCES users(id) ON DELETE SET NULL,
  target_id  BIGINT,
  action     VARCHAR(32) NOT NULL,
  details    JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS chat_events_chat_idx ON chat_events (chat_id, id DESC);

-- channel posts waiting for approval / saved as drafts by admins
CREATE TABLE IF NOT EXISTS post_queue (
  id         BIGSERIAL PRIMARY KEY,
  chat_id    BIGINT      NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  author_id  BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  body       JSONB       NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS post_queue_chat_idx ON post_queue (chat_id, id);
