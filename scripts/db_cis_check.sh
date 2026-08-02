#!/usr/bin/env bash
# Read-only CIS-oriented checks for the ElxMCP Postgres role/cluster.
# Usage: ./scripts/db_cis_check.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

DB_HOST="${DB_HOST:?}"
DB_PORT="${DB_PORT:-5481}"
DB_USER="${DB_USER:?}"
DB_PASSWORD="${DB_PASSWORD:?}"
DB_NAME="${DB_NAME:-elx_mcp_dev}"

export PGPASSWORD="$DB_PASSWORD"
export PGSSLMODE="${PGSSLMODE:-require}"
PSQL="$(command -v psql || true)"
[[ -x /opt/homebrew/opt/libpq/bin/psql ]] && PSQL=/opt/homebrew/opt/libpq/bin/psql

echo "== Role / limits =="
"$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolbypassrls, rolconnlimit
   FROM pg_roles WHERE rolname = current_user;"

echo "== SSL / logging (visible settings) =="
"$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT name, setting FROM pg_settings
   WHERE name IN (
     'ssl','port','password_encryption','log_connections','log_disconnections',
     'log_lock_waits','log_temp_files','log_min_duration_statement','log_checkpoints'
   ) ORDER BY 1;"

echo "== Extensions =="
"$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT extname, extversion FROM pg_extension ORDER BY 1;"

echo "== RLS status (public tables) =="
"$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT c.relname, c.relrowsecurity AS rls, c.relforcerowsecurity AS force_rls
   FROM pg_class c
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r'
   ORDER BY 1;"

echo "== CONNECT privilege matrix (sample) =="
"$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT d.datname, has_database_privilege(current_user, d.datname, 'CONNECT') AS can_connect
   FROM pg_database d WHERE NOT d.datistemplate ORDER BY 1;"

echo "OK: cis check finished"
