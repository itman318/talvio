#!/usr/bin/env bash
# Runs ON THE SERVER (Ubuntu 22.04/24.04) as root. Safe to run again and again:
# first run installs everything, later runs just update the app.
#   Node 22 · PostgreSQL · nginx (port 80 → app) · coturn (calls) · firewall · systemd service
# Secrets are generated once on the server and stay in /etc/talvio/talvio.env (never printed).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

APP_DIR=/opt/talvio/app
DATA_DIR=/var/lib/talvio
ENV_FILE=/etc/talvio/talvio.env
TARBALL=/root/talvio-backend.tgz
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
id talvio >/dev/null 2>&1 || useradd --system --home /opt/talvio --shell /usr/sbin/nologin talvio
mkdir -p /opt/talvio "$DATA_DIR/uploads" /etc/talvio
chown -R talvio:talvio "$DATA_DIR"

if [ ! -f "$ENV_FILE" ]; then
  log "Creating secrets (first run)"
  DB_PASS=$(rand 32)
  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
PORT=4000
TRUST_PROXY=true
DATABASE_URL=postgres://talvio:${DB_PASS}@127.0.0.1:5432/talvio
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
# keep the address current if the server IP changed
sed -i "s#^PUBLIC_URL=http://[0-9.]*\$#PUBLIC_URL=http://${PUBLIC_IP}#" "$ENV_FILE"

set -a; . "$ENV_FILE"; set +a
DB_PASS=$(echo "$DATABASE_URL" | sed -E 's#^postgres://talvio:([^@]+)@.*#\1#')

# ------------------------------------------------------------------ database
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='talvio'" | grep -q 1; then
  log "Creating database"
  sudo -u postgres psql -qc "CREATE ROLE talvio LOGIN PASSWORD '${DB_PASS}'"
fi
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='talvio'" | grep -q 1; then
  sudo -u postgres psql -qc "CREATE DATABASE talvio OWNER talvio"
fi

# ------------------------------------------------------------------ app code
log "Updating the app"
rm -rf /opt/talvio/new && mkdir -p /opt/talvio/new
tar -xzf "$TARBALL" -C /opt/talvio/new
(cd /opt/talvio/new && npm install --omit=dev --no-audit --no-fund --loglevel=error >/dev/null)
rm -rf /opt/talvio/old
[ -d "$APP_DIR" ] && mv "$APP_DIR" /opt/talvio/old
mv /opt/talvio/new "$APP_DIR"
chown -R talvio:talvio /opt/talvio

# (the settings from the env file are already exported in this shell)
log "Database migration"
(cd "$APP_DIR" && node scripts/migrate.js)

if [ -n "${ADMIN_EMAIL:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
  log "Admin account"
  (cd "$APP_DIR" && node scripts/create-admin.js "$ADMIN_EMAIL" "$ADMIN_PASSWORD" "Admin" >/dev/null && echo "admin: ready") || echo "admin: could not be created (password needs 10+ characters)"
fi

# ------------------------------------------------------------------ service
cat > /etc/systemd/system/talvio.service <<EOF
[Unit]
Description=Talvio server
After=network.target postgresql.service

[Service]
User=talvio
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
systemctl enable talvio >/dev/null 2>&1
systemctl restart talvio

# ------------------------------------------------------------------ nginx (port 80 → app, websockets, big uploads)
cat > /etc/nginx/sites-available/talvio <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    client_max_body_size 2100m;

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
ln -sf /etc/nginx/sites-available/talvio /etc/nginx/sites-enabled/talvio
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 && systemctl reload nginx

# ------------------------------------------------------------------ coturn (voice / video calls through firewalls)
cat > /etc/turnserver.conf <<EOF
listening-port=3478
fingerprint
use-auth-secret
static-auth-secret=${TURN_SECRET}
realm=talvio
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
echo "service: $(systemctl is-active talvio) · nginx: $(systemctl is-active nginx) · coturn: $(systemctl is-active coturn) · postgres: $(systemctl is-active postgresql)"
echo "node: $(node -v) · public address: http://${PUBLIC_IP}"
if [ "$(systemctl is-active talvio)" != active ]; then
  echo "--- last server log lines ---"
  journalctl -u talvio -n 30 --no-pager | sed -E 's/(SECRET|PASSWORD|postgres:\/\/)[^ ]*/\1***/g'
  exit 1
fi
rm -f "$TARBALL"
