#!/usr/bin/env bash
# Runs ON THE SERVER (Ubuntu 22.04/24.04) as root. Safe to run again and again:
# first run installs everything, later runs just update the app.
#   Node 22 · PostgreSQL · nginx (port 80 → app) · coturn (calls) · firewall · systemd service
# Secrets are generated once on the server and stay in /etc/hushavia/hushavia.env (never printed).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

APP_DIR=/opt/hushavia/app
DATA_DIR=/var/lib/hushavia
ENV_FILE=/etc/hushavia/hushavia.env
TARBALL=/root/hushavia-backend.tgz
PUBLIC_IP=$(curl -4 -fsS https://api.ipify.org || hostname -I | awk '{print $1}')

log() { echo "==> $*"; }
rand() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-40}"; }

# ------------------------------------------------------------------ packages (first run)
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
  log "Installing Node.js 22"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg >/dev/null
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
for pkg in postgresql nginx coturn ufw; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log "Installing $pkg"
    apt-get update -qq
    apt-get install -y -qq "$pkg" >/dev/null
  fi
done
systemctl enable --now postgresql >/dev/null 2>&1 || true

# swap: small servers survive npm installs and peaks
if [ ! -f /swapfile ] && [ "$(free -m | awk '/Swap/ {print $2}')" -lt 512 ]; then
  log "Adding 2 GB swap"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ------------------------------------------------------------------ user, folders, secrets
id hushavia >/dev/null 2>&1 || useradd --system --home /opt/hushavia --shell /usr/sbin/nologin hushavia
mkdir -p /opt/hushavia "$DATA_DIR/uploads" /etc/hushavia
chown -R hushavia:hushavia "$DATA_DIR"

if [ ! -f "$ENV_FILE" ]; then
  log "Creating secrets (first run)"
  DB_PASS=$(rand 32)
  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
PORT=4000
TRUST_PROXY=true
DATABASE_URL=postgres://hushavia:${DB_PASS}@127.0.0.1:5432/hushavia
JWT_SECRET=$(rand 48)
ADMIN_JWT_SECRET=$(rand 48)
OTP_SECRET=$(rand 48)
UPLOAD_DIR=${DATA_DIR}/uploads
PUBLIC_URL=http://${PUBLIC_IP}
TURN_SECRET=$(rand 40)
TURN_URLS=turn:${PUBLIC_IP}:3478?transport=udp,turn:${PUBLIC_IP}:3478?transport=tcp
# Until an SMS / email provider is set up, login codes are shown in the app (testing only).
OTP_DEV_MODE=true
EOF
  chmod 600 "$ENV_FILE"
fi
# optional settings from GitHub secrets (email provider, test mode); empty = keep what's there
set_env() {
  local key=$1 val=$2
  [ -n "$val" ] || return 0
  grep -v "^${key}=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
  val=${val//\\/\\\\}; val=${val//\"/\\\"}
  printf '%s="%s"\n' "$key" "$val" >> "$ENV_FILE.tmp"  # quoted: works for systemd and for bash
  mv "$ENV_FILE.tmp" "$ENV_FILE" && chmod 600 "$ENV_FILE"
  echo "setting: $key updated"
}
set_env MAIL_PROVIDER "${MAIL_PROVIDER:-}"
set_env MAIL_FROM "${MAIL_FROM:-}"
set_env BREVO_API_KEY "${BREVO_API_KEY:-}"
set_env OTP_DEV_MODE "${OTP_DEV_MODE:-}"
# push notifications (Firebase service account from the FIREBASE_SERVICE_ACCOUNT secret)
if [ -n "${FIREBASE_SA_B64:-}" ]; then
  if echo "$FIREBASE_SA_B64" | base64 -d > /etc/hushavia/firebase.json.tmp 2>/dev/null && grep -q '"private_key"' /etc/hushavia/firebase.json.tmp; then
    mv /etc/hushavia/firebase.json.tmp /etc/hushavia/firebase.json
    chown hushavia:hushavia /etc/hushavia/firebase.json 2>/dev/null || true
    chmod 600 /etc/hushavia/firebase.json
    set_env FIREBASE_SERVICE_ACCOUNT_PATH /etc/hushavia/firebase.json
    echo "push notifications: Firebase key installed"
  else
    rm -f /etc/hushavia/firebase.json.tmp
    echo "push notifications: FIREBASE_SERVICE_ACCOUNT is not a valid service-account JSON"
  fi
fi

# keep the address current if the server IP changed
sed -i "s#^PUBLIC_URL=http://[0-9.]*\$#PUBLIC_URL=http://${PUBLIC_IP}#" "$ENV_FILE"

set -a; . "$ENV_FILE"; set +a
DB_PASS=$(echo "$DATABASE_URL" | sed -E 's#^postgres://hushavia:([^@]+)@.*#\1#')

# ------------------------------------------------------------------ database
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='hushavia'" | grep -q 1; then
  log "Creating database"
  sudo -u postgres psql -qc "CREATE ROLE hushavia LOGIN PASSWORD '${DB_PASS}'"
fi
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='hushavia'" | grep -q 1; then
  sudo -u postgres psql -qc "CREATE DATABASE hushavia OWNER hushavia"
fi

# ------------------------------------------------------------------ app code
log "Updating the app"
rm -rf /opt/hushavia/new && mkdir -p /opt/hushavia/new
tar -xzf "$TARBALL" -C /opt/hushavia/new
(cd /opt/hushavia/new && npm install --omit=dev --no-audit --no-fund --loglevel=error >/dev/null)
rm -rf /opt/hushavia/old
[ -d "$APP_DIR" ] && mv "$APP_DIR" /opt/hushavia/old
mv /opt/hushavia/new "$APP_DIR"
chown -R hushavia:hushavia /opt/hushavia

# (the settings from the env file are already exported in this shell)
log "Database backup"
mkdir -p /var/backups/hushavia && chmod 700 /var/backups/hushavia
sudo -u postgres pg_dump hushavia 2>/dev/null | gzip > "/var/backups/hushavia/before-deploy-$(date +%Y%m%d-%H%M%S).sql.gz" && echo "backup: saved" || echo "backup: skipped"
ls -1t /var/backups/hushavia/before-deploy-*.sql.gz 2>/dev/null | tail -n +11 | xargs -r rm -f   # keep the last 10
# and every night at 03:15 (server time): a full database copy, the last 14 days kept
cat > /etc/cron.d/hushavia-backup <<'CRON'
15 3 * * * root mkdir -p /var/backups/hushavia && sudo -u postgres pg_dump hushavia | gzip > /var/backups/hushavia/daily-$(date +\%Y\%m\%d).sql.gz && ls -1t /var/backups/hushavia/daily-*.sql.gz | tail -n +15 | xargs -r rm -f
CRON
chmod 644 /etc/cron.d/hushavia-backup

log "Database migration"
(cd "$APP_DIR" && node scripts/migrate.js)

if [ -n "${ADMIN_EMAIL:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
  log "Admin account"
  (cd "$APP_DIR" && node scripts/create-admin.js "$ADMIN_EMAIL" "$ADMIN_PASSWORD" "Admin" >/dev/null && echo "admin: ready") || echo "admin: could not be created (password needs 10+ characters)"
fi

# ------------------------------------------------------------------ service
cat > /etc/systemd/system/hushavia.service <<EOF
[Unit]
Description=Hushavia server
After=network.target postgresql.service

[Service]
User=hushavia
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/node src/server.js
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hushavia >/dev/null 2>&1
systemctl restart hushavia

# ------------------------------------------------------------------ nginx (port 80 → app, websockets, big uploads)
cat > /etc/nginx/sites-available/hushavia <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    client_max_body_size 2100m;
    keepalive_timeout 30s;

    # smaller responses = faster on mobile data
    gzip on;
    gzip_comp_level 5;
    gzip_min_length 512;
    gzip_proxied any;
    gzip_types application/json application/javascript text/css text/plain image/svg+xml;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_request_buffering off;
    }
}
EOF
ln -sf /etc/nginx/sites-available/hushavia /etc/nginx/sites-enabled/hushavia
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 && systemctl reload nginx

# ------------------------------------------------------------------ coturn (voice / video calls through firewalls)
cat > /etc/turnserver.conf <<EOF
listening-port=3478
fingerprint
use-auth-secret
static-auth-secret=${TURN_SECRET}
realm=hushavia
external-ip=${PUBLIC_IP}
min-port=49160
max-port=49400
no-cli
no-tlsv1
no-tlsv1_1
no-multicast-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
EOF
chmod 640 /etc/turnserver.conf
chgrp turnserver /etc/turnserver.conf 2>/dev/null || true
[ -f /etc/default/coturn ] && sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
systemctl enable coturn >/dev/null 2>&1
systemctl restart coturn

# ------------------------------------------------------------------ firewall
ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 3478 >/dev/null
ufw allow 49160:49400/udp >/dev/null
ufw --force enable >/dev/null

# ------------------------------------------------------------------ check
sleep 4
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS http://127.0.0.1/health >/dev/null; then break; fi
  sleep 3
done
echo "health: $(curl -fsS http://127.0.0.1/health || echo FAILED)"
echo "service: $(systemctl is-active hushavia) · nginx: $(systemctl is-active nginx) · coturn: $(systemctl is-active coturn) · postgres: $(systemctl is-active postgresql)"
echo "node: $(node -v) · public address: http://${PUBLIC_IP}"
if [ "$(systemctl is-active hushavia)" != active ]; then
  echo "--- last server log lines ---"
  journalctl -u hushavia -n 30 --no-pager | sed -E 's/(SECRET|PASSWORD|postgres:\/\/)[^ ]*/\1***/g'
  exit 1
fi
rm -f "$TARBALL"
