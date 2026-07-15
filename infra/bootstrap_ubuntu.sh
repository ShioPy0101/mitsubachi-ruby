#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="${APP_ROOT}/.kamal/secrets.local"

if [[ -f "${SECRETS_FILE}" ]]; then
  # shellcheck source=/dev/null
  . "${SECRETS_FILE}"
fi

DATABASE_URL="${DATABASE_URL:-}"

if [[ -z "${DATABASE_URL}" ]]; then
  echo "DATABASE_URL is required. Run infra/install_local.sh first or export DATABASE_URL." >&2
  exit 1
fi

read_db_password() {
  ruby -ruri -rcgi -e 'uri = URI.parse(ARGV.fetch(0)); print CGI.unescape(uri.password.to_s)' "${DATABASE_URL}"
}

DB_USER="${DB_USER:-mitsubachi}"
DB_PASSWORD="${DB_PASSWORD:-$(read_db_password)}"

if [[ -z "${DB_PASSWORD}" ]]; then
  echo "Database password is required but was not present in DATABASE_URL." >&2
  exit 1
fi

sudo -u postgres psql -v ON_ERROR_STOP=1 \
  --set=db_user="${DB_USER}" \
  --set=db_password="${DB_PASSWORD}" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'db_user', :'db_password')
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_roles
  WHERE rolname = :'db_user'
)
\gexec

ALTER ROLE :"db_user" WITH LOGIN PASSWORD :'db_password';

SELECT format('CREATE DATABASE %I OWNER %I', db.name, :'db_user')
FROM (
  VALUES
    ('mitsubachi_production'),
    ('mitsubachi_production_cache'),
    ('mitsubachi_production_queue'),
    ('mitsubachi_production_cable')
) AS db(name)
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_database
  WHERE datname = db.name
)
\gexec

ALTER DATABASE mitsubachi_production OWNER TO :"db_user";
ALTER DATABASE mitsubachi_production_cache OWNER TO :"db_user";
ALTER DATABASE mitsubachi_production_queue OWNER TO :"db_user";
ALTER DATABASE mitsubachi_production_cable OWNER TO :"db_user";
SQL

echo "PostgreSQL role and databases are ready."
echo "Database password and URLs were not printed."
