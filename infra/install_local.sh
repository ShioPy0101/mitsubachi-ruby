#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="${APP_ROOT}/.kamal/secrets.local"

DB_USER="${DB_USER:-mitsubachi}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -base64 48 | tr -d '\n')}"

urlencode() {
  ruby -rcgi -e 'print CGI.escape(ARGV.fetch(0))' "$1"
}

encoded_password="$(urlencode "${DB_PASSWORD}")"

umask 077
cat > "${SECRETS_FILE}" <<SECRETS
DATABASE_URL='postgresql://${DB_USER}:${encoded_password}@${DB_HOST}:${DB_PORT}/mitsubachi_production'
DATABASE_CACHE_URL='postgresql://${DB_USER}:${encoded_password}@${DB_HOST}:${DB_PORT}/mitsubachi_production_cache'
DATABASE_QUEUE_URL='postgresql://${DB_USER}:${encoded_password}@${DB_HOST}:${DB_PORT}/mitsubachi_production_queue'
DATABASE_CABLE_URL='postgresql://${DB_USER}:${encoded_password}@${DB_HOST}:${DB_PORT}/mitsubachi_production_cable'
SECRETS
chmod 600 "${SECRETS_FILE}"

echo "Wrote ${SECRETS_FILE} with production database secrets."
echo "Database URLs and password are hidden."
