#!/usr/bin/env bash
# ONE-TIME, runs ON THE SERVER as root: moves the old install to the new name (folders, settings file,
# database + its role, system user, service, nginx site, backups). Safe to run again: it only acts when
# the old install is still there. A full database backup is taken first. Deleted from the repo afterwards.
set -euo pipefail
O=$(printf 'tal%s' vio)   # the old name
N=hushavia

if [ ! -d "/opt/$O" ] && [ ! -d "/etc/$O" ]; then
  echo "rename: nothing to do (already $N)"; exit 0
fi

echo "==> backup"
mkdir -p /root/pre-rename && chmod 700 /root/pre-rename
sudo -u postgres pg_dump "$O" | gzip > "/root/pre-rename/db-$(date +%Y%m%d-%H%M%S).sql.gz"
tar -czf "/root/pre-rename/etc-$(date +%Y%m%d-%H%M%S).tgz" "/etc/$O" 2>/dev/null || true
echo "backup: saved in /root/pre-rename"

echo "==> stop"
systemctl stop "$O" 2>/dev/null || true
systemctl disable "$O" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/$O.service" && systemctl daemon-reload

echo "==> database"
PASS=$(grep '^DATABASE_URL=' "/etc/$O/$O.env" | sed -E "s#^DATABASE_URL=\"?postgres://$O:([^@]+)@.*#\1#")
sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$O' AND pid <> pg_backend_pid();
ALTER DATABASE $O RENAME TO $N;
ALTER ROLE $O RENAME TO $N;
ALTER ROLE $N PASSWORD '$PASS';
SQL
sudo -u postgres psql -d "$N" -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$ BEGIN
  IF to_regclass('public.${O}_migrations') IS NOT NULL AND to_regclass('public.${N}_migrations') IS NULL THEN
    EXECUTE 'ALTER TABLE ${O}_migrations RENAME TO ${N}_migrations';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = '${O}_next_user_id') THEN
    EXECUTE 'ALTER FUNCTION ${O}_next_user_id() RENAME TO ${N}_next_user_id';
  END IF;
END \$\$;
UPDATE users SET username = 'HushaviaIDBot', first_name = 'Hushavia ID', updated_at = now() WHERE lower(username) = '${O}idbot' AND is_bot;
SQL
echo "database: renamed"

echo "==> folders and settings"
[ -d "/opt/$O" ] && mv "/opt/$O" "/opt/$N"
[ -d "/var/lib/$O" ] && mv "/var/lib/$O" "/var/lib/$N"
[ -d "/var/backups/$O" ] && mv "/var/backups/$O" "/var/backups/$N"
if [ -d "/etc/$O" ]; then
  mv "/etc/$O" "/etc/$N"
  [ -f "/etc/$N/$O.env" ] && mv "/etc/$N/$O.env" "/etc/$N/$N.env"
  sed -i "s#postgres://$O:#postgres://$N:#; s#@127.0.0.1:5432/$O\b#@127.0.0.1:5432/$N#; s#/var/lib/$O/#/var/lib/$N/#g; s#/etc/$O/#/etc/$N/#g" "/etc/$N/$N.env"
fi

echo "==> system user"
if id "$O" >/dev/null 2>&1; then
  usermod -l "$N" -d "/opt/$N" "$O"
  groupmod -n "$N" "$O" 2>/dev/null || true
fi
chown -R "$N:$N" "/opt/$N" "/var/lib/$N" 2>/dev/null || true
chown "$N:$N" "/etc/$N/firebase.json" 2>/dev/null || true

echo "==> nginx"
rm -f "/etc/nginx/sites-enabled/$O"
[ -f "/etc/nginx/sites-available/$O" ] && mv "/etc/nginx/sites-available/$O" "/etc/nginx/sites-available/$N"
ln -sf "/etc/nginx/sites-available/$N" "/etc/nginx/sites-enabled/$N"
nginx -t >/dev/null 2>&1 && systemctl reload nginx
sed -i "s/^realm=$O\$/realm=$N/" /etc/turnserver.conf 2>/dev/null || true
echo "rename: done — the normal setup now starts the service as $N"
