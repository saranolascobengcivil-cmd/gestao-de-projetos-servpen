#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR=/var/www/setup-novo-servidor
APP_DIR=/var/www/gestao-de-projetos
SERVICE=gestao-de-projetos
DB_ENV=/etc/gestao-de-projetos/db.env
TS="$(date +%Y%m%d-%H%M%S)"

if [ "$(id -u)" -ne 0 ]; then
    echo "Execute com sudo: sudo $0" >&2
    exit 1
fi

test -f "$SOURCE_DIR/app.py"
test -f "$SOURCE_DIR/database.py"
test -f "$SOURCE_DIR/requirements.txt"
test -f "$SOURCE_DIR/setup-novo-servidor/$SERVICE.service"
test -f "$DB_ENV"

echo "==> Backup dos dados"
mkdir -p "$APP_DIR/backups"
for db in gestao_equipe.db servpen.db; do
    if [ -f "$APP_DIR/$db" ]; then
        cp -a "$APP_DIR/$db" "$APP_DIR/backups/$db.$TS.pre-update.bak"
    fi
done

set -a
# shellcheck disable=SC1090
. "$DB_ENV"
set +a
PGPASSWORD="$DB_PASSWORD" pg_dump \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --username="$DB_USER" \
    --dbname="$DB_NAME" \
    | gzip -c > "$APP_DIR/backups/postgres-$DB_NAME-$TS.pre-update.sql.gz"

echo "==> Atualizando dependencias Python"
"$APP_DIR/venv/bin/pip" install -r "$SOURCE_DIR/requirements.txt"

echo "==> Publicando codigo novo"
systemctl stop "$SERVICE"
rsync -a --delete \
    --exclude='.local/' \
    --exclude='.streamlit/' \
    --exclude='__pycache__/' \
    --exclude='anexos/' \
    --exclude='backups/' \
    --exclude='venv/' \
    --exclude='*.db' \
    "$SOURCE_DIR/" "$APP_DIR/"

chown -R www-data:www-data "$APP_DIR"
chmod -R u+rwX,g+rwX "$APP_DIR"
find "$APP_DIR" -type d -exec chmod g+s {} \;

sed "s|__APP_DIR__|$APP_DIR|g" \
    "$APP_DIR/setup-novo-servidor/$SERVICE.service" \
    > "/etc/systemd/system/$SERVICE.service"
chmod 0644 "/etc/systemd/system/$SERVICE.service"

systemctl daemon-reload
systemctl restart "$SERVICE"

echo "==> Validando nginx e servicos"
/usr/sbin/nginx -t
systemctl reload nginx

for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 10 \
        "http://127.0.0.1:8501/gestao-de-projetos/_stcore/health" \
        >/dev/null; then
        break
    fi
    if [ "$attempt" -eq 10 ]; then
        echo "ERRO: Streamlit nao respondeu ao health check." >&2
        systemctl --no-pager -l status "$SERVICE" || true
        exit 1
    fi
    sleep 2
done

curl -fsS --max-time 10 \
    "http://127.0.0.1/gestao-de-projetos/_stcore/health"
curl -fsS --max-time 10 -o /dev/null \
    "http://127.0.0.1/geduerj-uploads/"

echo
echo "OK: http://152.92.238.40/gestao-de-projetos/"
echo "OK: http://152.92.238.40/geduerj-uploads/"
echo "Backup: $APP_DIR/backups/postgres-$DB_NAME-$TS.pre-update.sql.gz"
