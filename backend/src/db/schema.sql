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
-- (message types: the full list is set once, further down)
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
-- (message types: the full list is set once, further down)
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

-- (message types: the full list is set once, further down)

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
-- (message types: the full list is set once, further down)

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
-- (messages_type_check: set once further down with every value — a shorter list here would reject rows already stored)

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

-- ---------------------------------------------------------------- call links, birthdays, highlights, privacy exceptions, read receipts
CREATE TABLE IF NOT EXISTS call_links (
  code       VARCHAR(24) PRIMARY KEY,
  user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  video      BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS call_links_user_idx ON call_links (user_id);

ALTER TABLE users ADD COLUMN IF NOT EXISTS birthday DATE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_birthday VARCHAR(16) NOT NULL DEFAULT 'contacts';
ALTER TABLE users ADD COLUMN IF NOT EXISTS read_receipts BOOLEAN NOT NULL DEFAULT TRUE;

CREATE TABLE IF NOT EXISTS privacy_exceptions (
  owner_id  BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  setting   VARCHAR(16) NOT NULL,
  target_id BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  allow     BOOLEAN     NOT NULL,
  PRIMARY KEY (owner_id, setting, target_id)
);
CREATE INDEX IF NOT EXISTS privacy_exceptions_target_idx ON privacy_exceptions (target_id);

CREATE TABLE IF NOT EXISTS story_highlights (
  id         BIGSERIAL PRIMARY KEY,
  user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title      VARCHAR(32) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS story_highlights_user_idx ON story_highlights (user_id, id);
CREATE TABLE IF NOT EXISTS story_highlight_items (
  highlight_id BIGINT NOT NULL REFERENCES story_highlights(id) ON DELETE CASCADE,
  story_id     BIGINT NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
  PRIMARY KEY (highlight_id, story_id)
);
CREATE INDEX IF NOT EXISTS story_highlight_items_story_idx ON story_highlight_items (story_id);
CREATE TABLE IF NOT EXISTS job_runs (name VARCHAR(32) NOT NULL, day DATE NOT NULL, PRIMARY KEY (name, day));
ALTER TABLE polls ADD COLUMN IF NOT EXISTS close_at TIMESTAMPTZ;
ALTER TABLE stories ADD COLUMN IF NOT EXISTS mentions BIGINT[] NOT NULL DEFAULT '{}';

-- ---------------------------------------------------------------- privacy & security plus
ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_bio VARCHAR(10) NOT NULL DEFAULT 'everyone';
ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_forwards VARCHAR(10) NOT NULL DEFAULT 'everyone';
ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_messages VARCHAR(10) NOT NULL DEFAULT 'everyone';
ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_phone_search VARCHAR(10) NOT NULL DEFAULT 'everyone';
ALTER TABLE users ADD COLUMN IF NOT EXISTS default_disappear_sec INT NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS account_ttl_days INT NOT NULL DEFAULT 365;
ALTER TABLE users ADD COLUMN IF NOT EXISTS session_ttl_days INT NOT NULL DEFAULT 180;
ALTER TABLE users ADD COLUMN IF NOT EXISTS hide_from_search BOOLEAN NOT NULL DEFAULT FALSE;

-- ---------------------------------------------------------------- BotForge conversations
CREATE TABLE IF NOT EXISTS botfather_state (
  user_id    BIGINT      PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  step       VARCHAR(32) NOT NULL,
  data       JSONB       NOT NULL DEFAULT '{}',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- group protection
ALTER TABLE chats ADD COLUMN IF NOT EXISTS join_captcha BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS anti_flood BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS anti_links BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS hide_service BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS banned_words JSONB NOT NULL DEFAULT '[]';
ALTER TABLE chats ADD COLUMN IF NOT EXISTS member_perms JSONB NOT NULL DEFAULT '{}';
ALTER TABLE chat_members ADD COLUMN IF NOT EXISTS captcha_until TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS chat_members_captcha_idx ON chat_members (captcha_until) WHERE captcha_until IS NOT NULL;

-- ---------------------------------------------------------------- Plus: prices in the buyer's currency
ALTER TABLE premium_plans ADD COLUMN IF NOT EXISTS prices JSONB NOT NULL DEFAULT '{}';
UPDATE premium_plans SET prices = '{"USD": 3.99, "EUR": 3.79, "GBP": 3.29, "AED": 14.99, "SAR": 14.99, "INR": 249, "BDT": 399, "CAD": 5.49, "AUD": 5.99, "TRY": 129, "MYR": 17.9}'
  WHERE prices = '{}' AND months = 1;
UPDATE premium_plans SET prices = '{"USD": 35.99, "EUR": 33.99, "GBP": 29.99, "AED": 129.99, "SAR": 134.99, "INR": 2199, "BDT": 3499, "CAD": 48.99, "AUD": 53.99, "TRY": 1149, "MYR": 159}'
  WHERE prices = '{}' AND months = 12;
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS currency VARCHAR(3) NOT NULL DEFAULT 'PKR';
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS amount NUMERIC(12, 2);
ALTER TABLE users ALTER COLUMN bio TYPE VARCHAR(300);
ALTER TABLE chat_members ADD COLUMN IF NOT EXISTS member_tag VARCHAR(16);

-- ---------------------------------------------------------------- voice / round video "listened"
CREATE TABLE IF NOT EXISTS message_plays (
  message_id BIGINT      NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  played_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

-- ---------------------------------------------------------------- read later (bookmarks, on all my devices)
CREATE TABLE IF NOT EXISTS bookmarks (
  user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  message_id BIGINT      NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, message_id)
);
CREATE INDEX IF NOT EXISTS bookmarks_user_idx ON bookmarks (user_id, created_at DESC);

-- ---------------------------------------------------------------- login activity (Settings → Login activity)
CREATE TABLE IF NOT EXISTS login_events (
  id          BIGSERIAL    PRIMARY KEY,
  user_id     BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind        VARCHAR(24)  NOT NULL,  -- login | wrong_password | password_needed
  session_id  BIGINT,
  ip          VARCHAR(64),
  device_name VARCHAR(120),
  platform    VARCHAR(40),
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS login_events_user_idx ON login_events (user_id, created_at DESC);

-- ---------------------------------------------------------------- bot inline mode ("@bot query" in any chat)
ALTER TABLE bots ADD COLUMN IF NOT EXISTS inline_placeholder VARCHAR(64);

-- ---------------------------------------------------------------- live voice chats in groups & channels
CREATE TABLE IF NOT EXISTS voice_chats (
  id          BIGSERIAL    PRIMARY KEY,
  chat_id     BIGINT       NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  started_by  BIGINT       REFERENCES users(id) ON DELETE SET NULL,
  title       VARCHAR(64)  NOT NULL DEFAULT '',
  started_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  ended_at    TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS voice_chats_active_idx ON voice_chats (chat_id) WHERE ended_at IS NULL;
CREATE TABLE IF NOT EXISTS voice_chat_participants (
  voice_chat_id BIGINT      NOT NULL REFERENCES voice_chats(id) ON DELETE CASCADE,
  user_id       BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_id    BIGINT,
  joined_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  left_at       TIMESTAMPTZ,
  muted         BOOLEAN     NOT NULL DEFAULT TRUE,
  can_speak     BOOLEAN     NOT NULL DEFAULT TRUE,
  hand_raised   BOOLEAN     NOT NULL DEFAULT FALSE,
  PRIMARY KEY (voice_chat_id, user_id)
);
ALTER TABLE voice_chat_participants ADD COLUMN IF NOT EXISTS video BOOLEAN NOT NULL DEFAULT FALSE;

-- ---------------------------------------------------------------- Hushavia Bot API v2 (own event shape, signed hooks)
ALTER TABLE bots ADD COLUMN IF NOT EXISTS api_version VARCHAR(4) NOT NULL DEFAULT 'v1';

-- Settings → Notifications (private / groups / channels on-off, message text in notifications)
ALTER TABLE users ADD COLUMN IF NOT EXISTS notify_settings JSONB NOT NULL DEFAULT '{}'::jsonb;

-- who made this admin (admins with "add new admins" may only change the admins they added)
ALTER TABLE chat_members ADD COLUMN IF NOT EXISTS promoted_by BIGINT;

-- the refresh token that was just replaced stays valid for a while (lost answers must not log people out)
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS prev_refresh_hash CHAR(64);
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS prev_valid_until TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS sessions_prev_refresh_idx ON sessions (prev_refresh_hash) WHERE prev_refresh_hash IS NOT NULL;

-- support: screenshots, the phone it was sent from, and a rating after help
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS media_id BIGINT REFERENCES media(id) ON DELETE SET NULL;
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS device VARCHAR(120);
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS rating SMALLINT;
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS rating_comment VARCHAR(500);

-- in-app notifications (Settings bell): logins, security, groups, admin rights, support, payments
CREATE TABLE IF NOT EXISTS notices (
  id         BIGSERIAL PRIMARY KEY,
  user_id    BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind       VARCHAR(16)  NOT NULL,
  title      VARCHAR(120) NOT NULL,
  body       VARCHAR(500) NOT NULL DEFAULT '',
  data       JSONB        NOT NULL DEFAULT '{}'::jsonb,
  read_at    TIMESTAMPTZ,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notices_user_idx ON notices (user_id, id DESC);

-- numbers from people's phone books that aren't on Hushavia yet (only a hash) → "contact joined Hushavia"
CREATE TABLE IF NOT EXISTS contact_hints (
  owner_id   BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  phone_hash CHAR(64)    NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_id, phone_hash)
);
CREATE INDEX IF NOT EXISTS contact_hints_hash_idx ON contact_hints (phone_hash);

-- Hushavia Business: greeting, away message, working hours, quick replies
CREATE TABLE IF NOT EXISTS business_settings (
  user_id          BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  greeting_on      BOOLEAN      NOT NULL DEFAULT false,
  greeting_text    VARCHAR(1000) NOT NULL DEFAULT '',
  greeting_days    SMALLINT     NOT NULL DEFAULT 7,
  away_on          BOOLEAN      NOT NULL DEFAULT false,
  away_text        VARCHAR(1000) NOT NULL DEFAULT '',
  away_mode        VARCHAR(16)  NOT NULL DEFAULT 'outside_hours',
  hours            JSONB        NOT NULL DEFAULT '{}'::jsonb,
  tz_offset_min    SMALLINT     NOT NULL DEFAULT 0,
  updated_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS business_auto_log (
  owner_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  peer_id  BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind     VARCHAR(10) NOT NULL,
  sent_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_id, peer_id, kind)
);
CREATE TABLE IF NOT EXISTS quick_replies (
  id         BIGSERIAL PRIMARY KEY,
  user_id    BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  shortcut   VARCHAR(32)  NOT NULL,
  text       VARCHAR(4000) NOT NULL,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (user_id, shortcut)
);

-- ---------------------------------------------------------------- public-looking IDs
-- New accounts get 10-digit IDs (from 5 000 000 000) with small random gaps, so an ID says nothing
-- about how many people use Hushavia; new chats start at 1 000 000 000 (bots see groups as -100<id>).
CREATE TABLE IF NOT EXISTS hushavia_migrations (name VARCHAR(64) PRIMARY KEY, ran_at TIMESTAMPTZ NOT NULL DEFAULT now());

CREATE OR REPLACE FUNCTION hushavia_next_user_id() RETURNS trigger AS $$
DECLARE nid BIGINT;
BEGIN
  PERFORM pg_advisory_xact_lock(731100);
  nid := nextval('users_id_seq');
  IF nid < 5000000000 THEN nid := 5000000000 + floor(random() * 900)::bigint; END IF;
  PERFORM setval('users_id_seq', nid + 1 + floor(random() * 37)::bigint, false);
  NEW.id := nid;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS users_public_id ON users;
CREATE TRIGGER users_public_id BEFORE INSERT ON users FOR EACH ROW EXECUTE FUNCTION hushavia_next_user_id();

DO $$
BEGIN
  IF (SELECT last_value FROM chats_id_seq) < 1000000000 THEN
    PERFORM setval('chats_id_seq', 1000000000 + floor(random() * 5000)::bigint, false);
  END IF;
END $$;

-- one-time: give the accounts made before this the new kind of ID (keeps every chat, message and link)
DO $$
DECLARE r RECORD; def TEXT; nxt BIGINT := 5000000000;
BEGIN
  IF EXISTS (SELECT 1 FROM hushavia_migrations WHERE name = 'user_ids_v1') THEN RETURN; END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id < 5000000000) THEN
    INSERT INTO hushavia_migrations (name) VALUES ('user_ids_v1');
    RETURN;
  END IF;

  -- every foreign key to users(id) follows the change
  FOR r IN
    SELECT c.conname, c.conrelid::regclass AS tbl, pg_get_constraintdef(c.oid) AS d
    FROM pg_constraint c WHERE c.contype = 'f' AND c.confrelid = 'users'::regclass
  LOOP
    IF position('ON UPDATE' IN r.d) = 0 THEN
      EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, r.conname);
      EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s ON UPDATE CASCADE', r.tbl, r.conname, r.d);
    END IF;
  END LOOP;

  CREATE TEMP TABLE id_map (old_id BIGINT PRIMARY KEY, new_id BIGINT UNIQUE) ON COMMIT DROP;
  FOR r IN SELECT id FROM users WHERE id < 5000000000 ORDER BY id LOOP
    nxt := nxt + 1 + floor(random() * 37)::bigint;
    INSERT INTO id_map VALUES (r.id, nxt);
  END LOOP;

  -- columns that hold user IDs without a foreign key
  UPDATE reports t SET target_id = m.new_id FROM id_map m WHERE t.target_type = 'user' AND t.target_id = m.old_id;
  UPDATE admin_logs t SET target_id = m.new_id FROM id_map m WHERE t.target_type = 'user' AND t.target_id = m.old_id;
  UPDATE chat_events t SET target_id = m.new_id FROM id_map m WHERE t.target_id = m.old_id;
  UPDATE calls t SET ended_by = m.new_id FROM id_map m WHERE t.ended_by = m.old_id;
  UPDATE secret_chats t SET closed_by = m.new_id FROM id_map m WHERE t.closed_by = m.old_id;
  UPDATE client_errors t SET last_user_id = m.new_id FROM id_map m WHERE t.last_user_id = m.old_id;
  UPDATE client_error_users t SET user_id = m.new_id FROM id_map m WHERE t.user_id = m.old_id;
  UPDATE chat_members t SET promoted_by = m.new_id FROM id_map m WHERE t.promoted_by = m.old_id;
  UPDATE messages t SET via_bot_id = m.new_id FROM id_map m WHERE t.via_bot_id = m.old_id;
  UPDATE stories t SET mentions = ARRAY(SELECT COALESCE(m.new_id, x) FROM unnest(t.mentions) x LEFT JOIN id_map m ON m.old_id = x)
    WHERE cardinality(t.mentions) > 0;
  -- system messages that name a person
  UPDATE messages t SET meta = jsonb_set(t.meta, '{user_id}', to_jsonb(m.new_id)) FROM id_map m
    WHERE t.meta ? 'user_id' AND jsonb_typeof(t.meta->'user_id') = 'number' AND (t.meta->>'user_id')::bigint = m.old_id;
  DELETE FROM bot_updates;
  DELETE FROM botfather_state;

  -- the IDs themselves (foreign keys cascade)
  UPDATE users u SET id = m.new_id FROM id_map m WHERE u.id = m.old_id;

  -- private chats are keyed "smallerId:biggerId"
  UPDATE chats c SET private_key = k.key FROM (
    SELECT cm.chat_id, min(cm.user_id)::text || ':' || max(cm.user_id)::text AS key
    FROM chat_members cm JOIN chats c2 ON c2.id = cm.chat_id AND c2.type = 'private' GROUP BY cm.chat_id
  ) k WHERE c.id = k.chat_id AND c.type = 'private';

  PERFORM setval('users_id_seq', nxt + 1 + floor(random() * 37)::bigint, false);
  INSERT INTO hushavia_migrations (name) VALUES ('user_ids_v1');
END $$;

-- ---------------------------------------------------------------- emoji status (an emoji next to your name, optionally for a while)
ALTER TABLE users ADD COLUMN IF NOT EXISTS emoji_status TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS emoji_status_until TIMESTAMPTZ;

-- ---------------------------------------------------------------- more privacy: typing, voice messages
ALTER TABLE users ADD COLUMN IF NOT EXISTS show_typing BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy_voice TEXT NOT NULL DEFAULT 'everyone';

-- ---------------------------------------------------------------- Button Maker bot: steps survive restarts, published posts can be edited
CREATE TABLE IF NOT EXISTS buttonbot_state (
  user_id    BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  data       JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS buttonbot_posts (
  id           BIGSERIAL PRIMARY KEY,
  user_id      BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  chat_id      BIGINT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  message_id   BIGINT,
  scheduled_id BIGINT,
  title        TEXT NOT NULL DEFAULT '',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS buttonbot_posts_user_idx ON buttonbot_posts (user_id, id DESC);

-- ---------------------------------------------------------------- sticker packs only Hushavia Plus members can send
ALTER TABLE sticker_packs ADD COLUMN IF NOT EXISTS is_premium BOOLEAN NOT NULL DEFAULT FALSE;

-- fast photos: tiny inline preview sent with the message (bubble-size WebP lives next to the file)
ALTER TABLE media ADD COLUMN IF NOT EXISTS thumb TEXT;
ALTER TABLE media ADD COLUMN IF NOT EXISTS thumb_failed BOOLEAN NOT NULL DEFAULT FALSE;

-- Group Guard: forwarded messages, @mention spam, raid shield, penalty after 3 warnings
ALTER TABLE chats ADD COLUMN IF NOT EXISTS anti_forward BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS anti_mentions BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS raid_shield BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS guard_penalty VARCHAR(8) NOT NULL DEFAULT 'none';
CREATE INDEX IF NOT EXISTS chat_events_guard_idx ON chat_events (chat_id, target_id, created_at) WHERE action LIKE 'guard_%';

-- removed members stay out (no rejoining by invite link) until an admin unbans them
CREATE TABLE IF NOT EXISTS chat_bans (
  chat_id    BIGINT      NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  banned_by  BIGINT      REFERENCES users(id) ON DELETE SET NULL,
  reason     VARCHAR(16) NOT NULL DEFAULT 'removed',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (chat_id, user_id)
);

-- admin panel: switch a sticker pack off, or decide Plus-only by hand (kept across restarts)
ALTER TABLE sticker_packs ADD COLUMN IF NOT EXISTS is_disabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE sticker_packs ADD COLUMN IF NOT EXISTS premium_by_admin BOOLEAN NOT NULL DEFAULT FALSE;

-- ------------------------------------------------------------------ support desk v2
-- Public request numbers: start in the hundred-thousands and grow in uneven steps, so a number
-- never tells how many requests (or users) there are. The internal id stays for links.
CREATE SEQUENCE IF NOT EXISTS support_ticket_no_seq START WITH 482137;
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS number BIGINT;
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS first_reply_at TIMESTAMPTZ;
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ;
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS is_note BOOLEAN NOT NULL DEFAULT FALSE; -- team-only note
CREATE OR REPLACE FUNCTION hushavia_next_ticket_no() RETURNS BIGINT AS $$
DECLARE n BIGINT;
BEGIN
  n := nextval('support_ticket_no_seq') + floor(random() * 23)::bigint;
  PERFORM setval('support_ticket_no_seq', n, true);
  RETURN n;
END $$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION hushavia_ticket_number() RETURNS trigger AS $$
BEGIN
  IF NEW.number IS NULL THEN NEW.number := hushavia_next_ticket_no(); END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS support_tickets_number ON support_tickets;
CREATE TRIGGER support_tickets_number BEFORE INSERT ON support_tickets FOR EACH ROW EXECUTE FUNCTION hushavia_ticket_number();
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id FROM support_tickets WHERE number IS NULL ORDER BY id LOOP
    UPDATE support_tickets SET number = hushavia_next_ticket_no() WHERE id = r.id;
  END LOOP;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS support_tickets_number_idx ON support_tickets (number);
-- saved answers the team can drop into a reply
CREATE TABLE IF NOT EXISTS support_canned (
  id         BIGSERIAL PRIMARY KEY,
  title      VARCHAR(80)   NOT NULL,
  text       VARCHAR(4000) NOT NULL,
  created_by BIGINT        REFERENCES admins(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- ------------------------------------------------------------------ wallet in chats
-- (messages_type_check: set once further down with every value — a shorter list here would reject rows already stored)
-- public wallet addresses a person CHOSE to share with the people they chat with (never keys)
ALTER TABLE users ADD COLUMN IF NOT EXISTS wallet_tron VARCHAR(40);
ALTER TABLE users ADD COLUMN IF NOT EXISTS wallet_evm VARCHAR(42);
ALTER TABLE users ADD COLUMN IF NOT EXISTS wallet_btc VARCHAR(90);
ALTER TABLE users ADD COLUMN IF NOT EXISTS wallet_ltc VARCHAR(90);
ALTER TABLE users ADD COLUMN IF NOT EXISTS wallet_doge VARCHAR(40);
ALTER TABLE users ADD COLUMN IF NOT EXISTS wallet_sol VARCHAR(48);

-- ------------------------------------------------------------------ Plus packages (1 / 3 / 6 / 12 months) + paying from the in-app wallet
ALTER TABLE premium_plans ADD COLUMN IF NOT EXISTS badge VARCHAR(20);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM hushavia_migrations WHERE name = 'plus_packages_v1') THEN RETURN; END IF;
  INSERT INTO premium_plans (name, months, price_pkr, sort, badge, prices)
    SELECT '3 months', 3, 799, 3, 'Popular',
      '{"USD": 10.49, "EUR": 9.99, "GBP": 8.69, "AED": 38.99, "SAR": 39.99, "INR": 659, "BDT": 1049, "CAD": 14.49, "AUD": 15.79, "TRY": 339, "MYR": 46.9}'::jsonb
    WHERE NOT EXISTS (SELECT 1 FROM premium_plans WHERE months = 3);
  INSERT INTO premium_plans (name, months, price_pkr, sort, prices)
    SELECT '6 months', 6, 1499, 6,
      '{"USD": 19.99, "EUR": 18.99, "GBP": 16.49, "AED": 74.99, "SAR": 74.99, "INR": 1249, "BDT": 1999, "CAD": 27.49, "AUD": 29.99, "TRY": 645, "MYR": 89.9}'::jsonb
    WHERE NOT EXISTS (SELECT 1 FROM premium_plans WHERE months = 6);
  -- the yearly plan must be the best deal: Rs 2,999 was the same per month as 6 months
  UPDATE premium_plans SET price_pkr = 2699 WHERE months = 12 AND price_pkr = 2999;
  UPDATE premium_plans SET badge = 'Best value' WHERE months = 12 AND badge IS NULL;
  UPDATE premium_plans SET sort = months WHERE sort IN (1, 2) AND months IN (1, 12);
  INSERT INTO hushavia_migrations (name) VALUES ('plus_packages_v1');
END $$;

-- paying with USDT straight from the person's own wallet; the server only ever sees public data
-- (payment_orders_provider_check: set once further down with every value — a shorter list here would reject rows already stored)
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS crypto_network VARCHAR(12);
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS crypto_to VARCHAR(64);
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS crypto_amount NUMERIC(40, 0);
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS crypto_tx VARCHAR(80);
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS crypto_checked_at TIMESTAMPTZ;
-- one network transaction can pay for one order only
CREATE UNIQUE INDEX IF NOT EXISTS payment_orders_crypto_tx_idx ON payment_orders (crypto_network, crypto_tx) WHERE crypto_tx IS NOT NULL;

-- ------------------------------------------------------------------ Hushavia Coins (in-app balance, not a crypto token)
ALTER TABLE users ADD COLUMN IF NOT EXISTS coins BIGINT NOT NULL DEFAULT 0 CHECK (coins >= 0);
CREATE TABLE IF NOT EXISTS coin_packs (
  id         BIGSERIAL     PRIMARY KEY,
  coins      INTEGER       NOT NULL CHECK (coins > 0),
  bonus      INTEGER       NOT NULL DEFAULT 0 CHECK (bonus >= 0),
  price_usd  NUMERIC(10,2) NOT NULL CHECK (price_usd > 0),
  badge      VARCHAR(20),
  is_active  BOOLEAN       NOT NULL DEFAULT TRUE,
  sort       INTEGER       NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ   NOT NULL DEFAULT now()
);
INSERT INTO coin_packs (coins, bonus, price_usd, badge, sort)
SELECT * FROM (VALUES (100, 0, 0.99, NULL, 100), (500, 25, 4.99, NULL, 500), (1000, 100, 9.99, 'Popular', 1000), (2500, 400, 24.99, NULL, 2500), (5000, 1000, 49.99, 'Best value', 5000))
  AS p(coins, bonus, price_usd, badge, sort)
WHERE NOT EXISTS (SELECT 1 FROM coin_packs);
-- every change of a balance (the balance itself lives in users.coins)
CREATE TABLE IF NOT EXISTS coin_tx (
  id         BIGSERIAL    PRIMARY KEY,
  user_id    BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  delta      BIGINT       NOT NULL,
  balance    BIGINT       NOT NULL,
  kind       VARCHAR(16)  NOT NULL CHECK (kind IN ('purchase', 'gift_sent', 'gift_received', 'plus', 'admin')),
  peer_id    BIGINT       REFERENCES users(id) ON DELETE SET NULL,
  order_id   BIGINT       REFERENCES payment_orders(id) ON DELETE SET NULL,
  note       VARCHAR(120),
  created_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS coin_tx_user_idx ON coin_tx (user_id, id DESC);
-- (payment_orders_provider_check: set once further down with every value — a shorter list here would reject rows already stored)
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS coins INTEGER;
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS coin_pack_id BIGINT REFERENCES coin_packs(id) ON DELETE SET NULL;
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS crypto_submitted_at TIMESTAMPTZ;

-- ------------------------------------------------------------------ speed: the member count is kept on the chat
-- (counting the members of a big channel for every row of every chat list was the slowest part of opening the app)
ALTER TABLE chats ADD COLUMN IF NOT EXISTS member_count INTEGER NOT NULL DEFAULT 0;
CREATE OR REPLACE FUNCTION hushavia_member_count() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE chats SET member_count = member_count + 1 WHERE id = NEW.chat_id;
    RETURN NEW;
  END IF;
  UPDATE chats SET member_count = GREATEST(member_count - 1, 0) WHERE id = OLD.chat_id;
  RETURN OLD;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS chat_members_count ON chat_members;
CREATE TRIGGER chat_members_count AFTER INSERT OR DELETE ON chat_members FOR EACH ROW EXECUTE FUNCTION hushavia_member_count();
-- put right whatever is off (first run, or a restore)
UPDATE chats c SET member_count = x.n FROM (SELECT chat_id, count(*)::int AS n FROM chat_members GROUP BY chat_id) x WHERE x.chat_id = c.id AND c.member_count <> x.n;
UPDATE chats c SET member_count = 0 WHERE c.member_count <> 0 AND NOT EXISTS (SELECT 1 FROM chat_members m WHERE m.chat_id = c.id);

-- ------------------------------------------------------------------ coins: gifts, tips, paid channels, giveaways
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_type_check
  CHECK (type IN ('text', 'image', 'video', 'voice', 'video_note', 'file', 'system', 'poll', 'location', 'call', 'sticker', 'gif', 'contact', 'crypto', 'gift', 'giveaway'));
ALTER TABLE messages ADD COLUMN IF NOT EXISTS coin_tips INTEGER NOT NULL DEFAULT 0;
-- (the list of coin kinds is set once, further down, with every kind — an older, shorter list here would reject rows already stored)
ALTER TABLE chats ADD COLUMN IF NOT EXISTS sub_price INTEGER NOT NULL DEFAULT 0 CHECK (sub_price >= 0);
CREATE TABLE IF NOT EXISTS channel_subs (
  chat_id    BIGINT      NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  price      INTEGER     NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (chat_id, user_id)
);
CREATE INDEX IF NOT EXISTS channel_subs_expires_idx ON channel_subs (expires_at);
CREATE TABLE IF NOT EXISTS giveaways (
  id         BIGSERIAL   PRIMARY KEY,
  chat_id    BIGINT      NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  creator_id BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  message_id BIGINT,
  coins_each INTEGER     NOT NULL CHECK (coins_each > 0),
  winners    INTEGER     NOT NULL CHECK (winners > 0),
  ends_at    TIMESTAMPTZ NOT NULL,
  status     VARCHAR(8)  NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS giveaways_due_idx ON giveaways (ends_at) WHERE status = 'open';
CREATE TABLE IF NOT EXISTS giveaway_entries (
  giveaway_id BIGINT  NOT NULL REFERENCES giveaways(id) ON DELETE CASCADE,
  user_id     BIGINT  NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  won         BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (giveaway_id, user_id)
);

-- ------------------------------------------------------------------ coins by deposit: an own USDT address for every member
CREATE TABLE IF NOT EXISTS coin_deposit_addresses (
  user_id     BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  xpub_fp     VARCHAR(16) NOT NULL,
  idx         INTEGER     NOT NULL,
  address     VARCHAR(42) NOT NULL,
  watch_until TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, xpub_fp),
  UNIQUE (xpub_fp, idx),
  UNIQUE (xpub_fp, address)
);
CREATE INDEX IF NOT EXISTS coin_deposit_addresses_watch_idx ON coin_deposit_addresses (xpub_fp, watch_until);
CREATE TABLE IF NOT EXISTS coin_deposits (
  id         BIGSERIAL    PRIMARY KEY,
  user_id    BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  address    VARCHAR(42)  NOT NULL,
  tx_hash    VARCHAR(66)  NOT NULL,
  log_index  INTEGER      NOT NULL,
  block      BIGINT       NOT NULL,
  amount     NUMERIC(40, 0) NOT NULL,
  coins      INTEGER      NOT NULL DEFAULT 0,
  status     VARCHAR(10)  NOT NULL CHECK (status IN ('credited', 'too_small')),
  created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (tx_hash, log_index)
);
CREATE INDEX IF NOT EXISTS coin_deposits_user_idx ON coin_deposits (user_id, id DESC);
CREATE TABLE IF NOT EXISTS coin_deposit_state (id INTEGER PRIMARY KEY CHECK (id = 1), last_block BIGINT NOT NULL);
-- (the list of coin kinds is set once, further down, with every kind — an older, shorter list here would reject rows already stored)

-- ------------------------------------------------------------------ self-service ads (paid with coins)
ALTER TABLE ad_campaigns ADD COLUMN IF NOT EXISTS owner_id BIGINT REFERENCES users(id) ON DELETE SET NULL; -- the member who runs it (NULL = sold by the team)
ALTER TABLE ad_campaigns ADD COLUMN IF NOT EXISTS review VARCHAR(10) NOT NULL DEFAULT 'approved' CHECK (review IN ('pending', 'approved', 'rejected'));
ALTER TABLE ad_campaigns ADD COLUMN IF NOT EXISTS reject_reason VARCHAR(300);
ALTER TABLE ad_campaigns ADD COLUMN IF NOT EXISTS cpm_coins INTEGER NOT NULL DEFAULT 0;      -- coins for 1,000 views
ALTER TABLE ad_campaigns ADD COLUMN IF NOT EXISTS budget_coins INTEGER NOT NULL DEFAULT 0;   -- held when the ad was made / topped up
ALTER TABLE ad_campaigns ADD COLUMN IF NOT EXISTS spent_millis BIGINT NOT NULL DEFAULT 0;    -- 1 coin = 1,000 millis (one view costs cpm millis)
ALTER TABLE ad_campaigns ADD COLUMN IF NOT EXISTS refunded_coins INTEGER NOT NULL DEFAULT 0;
ALTER TABLE ad_campaigns ADD COLUMN IF NOT EXISTS daily_cap_coins INTEGER;
ALTER TABLE ad_campaigns ADD COLUMN IF NOT EXISTS categories JSONB NOT NULL DEFAULT '[]';
ALTER TABLE ad_campaigns ADD COLUMN IF NOT EXISTS countries JSONB NOT NULL DEFAULT '[]';
ALTER TABLE ad_campaigns ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
CREATE INDEX IF NOT EXISTS ad_campaigns_owner_idx ON ad_campaigns (owner_id, id DESC) WHERE owner_id IS NOT NULL;
ALTER TABLE ad_views ADD COLUMN IF NOT EXISTS chat_id BIGINT;
ALTER TABLE ad_views ADD COLUMN IF NOT EXISTS cost_millis INTEGER NOT NULL DEFAULT 0;
CREATE TABLE IF NOT EXISTS ad_daily (
  campaign_id BIGINT  NOT NULL REFERENCES ad_campaigns(id) ON DELETE CASCADE,
  day         DATE    NOT NULL DEFAULT current_date,
  views       INTEGER NOT NULL DEFAULT 0,
  clicks      INTEGER NOT NULL DEFAULT 0,
  millis      BIGINT  NOT NULL DEFAULT 0,
  PRIMARY KEY (campaign_id, day)
);
-- channel owners' share, paid out in whole coins
CREATE TABLE IF NOT EXISTS ad_owner_earnings (
  owner_id       BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  pending_millis BIGINT NOT NULL DEFAULT 0,
  paid_coins     BIGINT NOT NULL DEFAULT 0,
  views          BIGINT NOT NULL DEFAULT 0
);
ALTER TABLE chats ADD COLUMN IF NOT EXISTS ads_off BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE coin_tx DROP CONSTRAINT IF EXISTS coin_tx_kind_check;
ALTER TABLE coin_tx ADD CONSTRAINT coin_tx_kind_check CHECK (kind IN ('deposit', 'purchase', 'gift_sent', 'gift_received', 'plus', 'admin',
  'tip_sent', 'tip_received', 'sub_paid', 'sub_income', 'giveaway', 'giveaway_win', 'giveaway_refund', 'ad_budget', 'ad_refund', 'ad_income',
  'shop_paid', 'shop_income'));

-- ------------------------------------------------------------------ channel monetization, card payments
ALTER TABLE chats ADD COLUMN IF NOT EXISTS monetized BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS monetized_at TIMESTAMPTZ;
ALTER TABLE payment_orders DROP CONSTRAINT IF EXISTS payment_orders_provider_check;
ALTER TABLE payment_orders ADD CONSTRAINT payment_orders_provider_check CHECK (provider IN ('jazzcash', 'easypaisa', 'manual', 'admin', 'crypto', 'coins', 'stripe'));
ALTER TABLE payment_orders ADD COLUMN IF NOT EXISTS stripe_session VARCHAR(255);
CREATE UNIQUE INDEX IF NOT EXISTS payment_orders_stripe_idx ON payment_orders (stripe_session) WHERE stripe_session IS NOT NULL;

-- ------------------------------------------------------------------ Plus: story stealth (a Plus member's view is not shown to the author)
ALTER TABLE story_views ADD COLUMN IF NOT EXISTS stealth BOOLEAN NOT NULL DEFAULT FALSE;

-- ------------------------------------------------------------------ business catalog
CREATE TABLE IF NOT EXISTS catalog_items (
  id             BIGSERIAL PRIMARY KEY,
  owner_id       BIGINT        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title          VARCHAR(80)   NOT NULL,
  description    VARCHAR(1000) NOT NULL DEFAULT '',
  price_text     VARCHAR(40),
  price_coins    INTEGER,
  photo_media_id BIGINT        REFERENCES media(id) ON DELETE SET NULL,
  sold_out       BOOLEAN       NOT NULL DEFAULT false,
  sold           INTEGER       NOT NULL DEFAULT 0,
  position       INTEGER       NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
  deleted_at     TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS catalog_items_owner_idx ON catalog_items (owner_id) WHERE deleted_at IS NULL;
CREATE TABLE IF NOT EXISTS catalog_orders (
  id         BIGSERIAL PRIMARY KEY,
  item_id    BIGINT      NOT NULL REFERENCES catalog_items(id) ON DELETE CASCADE,
  buyer_id   BIGINT      REFERENCES users(id) ON DELETE SET NULL,
  seller_id  BIGINT      REFERENCES users(id) ON DELETE SET NULL,
  coins      INTEGER     NOT NULL,
  title      VARCHAR(80) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS catalog_orders_buyer_idx ON catalog_orders (buyer_id, created_at DESC);

-- ------------------------------------------------------------------ profile tags (scam, fake, spam … verified business)
ALTER TABLE users ADD COLUMN IF NOT EXISTS tags TEXT[] NOT NULL DEFAULT '{}';
CREATE TABLE IF NOT EXISTS user_tags (
  id         BIGSERIAL PRIMARY KEY,
  user_id    BIGINT        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  tag        VARCHAR(24)   NOT NULL,
  reason     VARCHAR(500)  NOT NULL DEFAULT '',
  evidence   VARCHAR(2000) NOT NULL DEFAULT '',
  admin_id   BIGINT        REFERENCES admins(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ   NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ,
  removed_at TIMESTAMPTZ,
  removed_by BIGINT        REFERENCES admins(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS user_tags_user_idx ON user_tags (user_id, tag) WHERE removed_at IS NULL;

ALTER TABLE chats ADD COLUMN IF NOT EXISTS hidden_members BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS sys_flags (key VARCHAR(64) PRIMARY KEY, at TIMESTAMPTZ NOT NULL DEFAULT now());

-- ------------------------------------------------------------------ verification requests (@HushaviaVerifyBot)
CREATE TABLE IF NOT EXISTS verify_requests (
  id          BIGSERIAL PRIMARY KEY,
  user_id     BIGINT        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind        VARCHAR(10)   NOT NULL CHECK (kind IN ('person', 'business', 'chat')),
  chat_id     BIGINT        REFERENCES chats(id) ON DELETE SET NULL,
  details     VARCHAR(4000) NOT NULL DEFAULT '',
  media_ids   JSONB         NOT NULL DEFAULT '[]',
  status      VARCHAR(10)   NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'approved', 'declined')),
  admin_note  VARCHAR(500),
  decided_by  BIGINT        REFERENCES admins(id) ON DELETE SET NULL,
  decided_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS verify_requests_status_idx ON verify_requests (status, id);
ALTER TABLE verify_requests ADD COLUMN IF NOT EXISTS fields JSONB;
