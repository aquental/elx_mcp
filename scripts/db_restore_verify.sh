#!/usr/bin/env bash
# Decrypt the newest (or given) encrypted backup, restore into a temporary DB, verify, drop.
#
# Usage:
#   ./scripts/db_restore_verify.sh
#   ./scripts/db_restore_verify.sh priv/backups/elx_mcp_elx_mcp_dev_....dump.gpg
#
# Requires: same DB_* + ELX_MCP_BACKUP_PASSPHRASE as backup; role must have CREATEDB.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

DB_HOST="${DB_HOST:?DB_HOST required}"
DB_PORT="${DB_PORT:-5481}"
DB_USER="${DB_USER:?DB_USER required}"
DB_PASSWORD="${DB_PASSWORD:?DB_PASSWORD required}"
BACKUP_DIR="${ELX_MCP_BACKUP_DIR:-priv/backups}"
PASSPHRASE="${ELX_MCP_BACKUP_PASSPHRASE:?ELX_MCP_BACKUP_PASSPHRASE required}"
MAINT_DB="${ELX_MCP_MAINT_DB:-postgres}"

PG_RESTORE="${PG_RESTORE:-$(command -v pg_restore || true)}"
PSQL="${PSQL:-$(command -v psql || true)}"
if [[ -z "$PG_RESTORE" && -x /opt/homebrew/opt/libpq/bin/pg_restore ]]; then
  PG_RESTORE=/opt/homebrew/opt/libpq/bin/pg_restore
fi
if [[ -z "$PSQL" && -x /opt/homebrew/opt/libpq/bin/psql ]]; then
  PSQL=/opt/homebrew/opt/libpq/bin/psql
fi
for bin in "$PG_RESTORE" "$PSQL" gpg; do
  command -v "${bin%% *}" >/dev/null 2>&1 || [[ -x "$bin" ]] || {
    echo "missing tool: $bin" >&2
    exit 1
  }
done
GPG="$(command -v gpg)"

ENC="${1:-}"
if [[ -z "$ENC" ]]; then
  ENC="$(ls -1t "$BACKUP_DIR"/elx_mcp_*.dump.gpg 2>/dev/null | head -1 || true)"
fi
if [[ -z "$ENC" || ! -f "$ENC" ]]; then
  echo "No backup file found. Run ./scripts/db_backup.sh first." >&2
  exit 1
fi

export PGPASSWORD="$DB_PASSWORD"
export PGSSLMODE="${PGSSLMODE:-require}"
if [[ -n "${DB_SSL_CA:-}" && -f "${DB_SSL_CA}" ]]; then
  export PGSSLROOTCERT="$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$DB_SSL_CA")"
  export PGSSLMODE=verify-ca
fi

TMPDIR_LOCAL="$(mktemp -d "${TMPDIR:-/tmp}/elx_mcp_restore.XXXXXX")"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

PLAIN="$TMPDIR_LOCAL/restore.dump"
# Fixed name (must match pg_hba allowlist on hermes — not a wildcard).
VERIFY_DB="${ELX_MCP_RESTORE_VERIFY_DB:-elx_mcp_restore_verify}"

echo "==> Decrypt $ENC"
"$GPG" --batch --yes --decrypt \
  --passphrase "$PASSPHRASE" \
  --output "$PLAIN" \
  "$ENC"

echo "==> Recreate temp database $VERIFY_DB (via $MAINT_DB)"
"$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$MAINT_DB" -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${VERIFY_DB}' AND pid <> pg_backend_pid();" \
  >/dev/null 2>&1 || true
"$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$MAINT_DB" -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS ${VERIFY_DB};"
"$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$MAINT_DB" -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE ${VERIFY_DB} OWNER ${DB_USER};"

echo "==> Restore into $VERIFY_DB"
"$PG_RESTORE" \
  --host="$DB_HOST" \
  --port="$DB_PORT" \
  --username="$DB_USER" \
  --dbname="$VERIFY_DB" \
  --no-owner \
  --no-acl \
  --exit-on-error \
  "$PLAIN"

echo "==> Verify table count"
TABLES="$("$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$VERIFY_DB" -tAc \
  "SELECT count(*) FROM pg_tables WHERE schemaname = 'public';")"
echo "    public tables: $TABLES"
if [[ "${TABLES// /}" -lt 1 ]]; then
  echo "FAIL: expected at least 1 public table" >&2
  exit 1
fi

# Spot-check a few known relations if present
"$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$VERIFY_DB" -v ON_ERROR_STOP=1 <<'SQL'
SELECT 'projects' AS rel, to_regclass('public.projects') IS NOT NULL AS ok
UNION ALL
SELECT 'api_keys', to_regclass('public.api_keys') IS NOT NULL
UNION ALL
SELECT 'tickets', to_regclass('public.tickets') IS NOT NULL;
SQL

echo "==> Drop temp database $VERIFY_DB"
"$PSQL" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$MAINT_DB" -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE ${VERIFY_DB};"

echo "OK: restore verified from $ENC (tables=$TABLES)"
