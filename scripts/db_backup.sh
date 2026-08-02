#!/usr/bin/env bash
# Encrypted logical backup of ElxMCP Postgres databases (pg_dump custom format + GPG AES-256).
#
# Usage (from project root):
#   ./scripts/db_backup.sh
#   ./scripts/db_backup.sh --db elx_mcp_dev
#   ./scripts/db_backup.sh --db both
#
# Env (from .env or shell):
#   DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME, DB_NAME_TEST
#   DB_SSL_CA, DB_SSL_HOSTNAME (optional; used for sslmode=verify-full when CA set)
#   ELX_MCP_BACKUP_PASSPHRASE  (required) — GPG symmetric passphrase
#   ELX_MCP_BACKUP_DIR         (optional, default priv/backups)
#
# Output: $ELX_MCP_BACKUP_DIR/elx_mcp_<db>_<UTC-timestamp>.dump.gpg
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
DB_NAME="${DB_NAME:-elx_mcp_dev}"
DB_NAME_TEST="${DB_NAME_TEST:-elx_mcp_test}"
BACKUP_DIR="${ELX_MCP_BACKUP_DIR:-priv/backups}"
PASSPHRASE="${ELX_MCP_BACKUP_PASSPHRASE:?ELX_MCP_BACKUP_PASSPHRASE required (set in .env)}"

TARGET="elx_mcp_dev"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)
      TARGET="${2:?}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

PG_DUMP="${PG_DUMP:-$(command -v pg_dump || true)}"
if [[ -z "$PG_DUMP" && -x /opt/homebrew/opt/libpq/bin/pg_dump ]]; then
  PG_DUMP=/opt/homebrew/opt/libpq/bin/pg_dump
fi
if [[ -z "$PG_DUMP" ]]; then
  echo "pg_dump not found (install libpq / postgresql client)" >&2
  exit 1
fi

GPG="$(command -v gpg || true)"
if [[ -z "$GPG" ]]; then
  echo "gpg not found" >&2
  exit 1
fi

export PGPASSWORD="$DB_PASSWORD"
export PGSSLMODE="${PGSSLMODE:-require}"
if [[ -n "${DB_SSL_CA:-}" && -f "${DB_SSL_CA}" ]]; then
  export PGSSLROOTCERT="$(cd "$ROOT" && python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$DB_SSL_CA")"
  # verify-full needs hostname matching cert; prefer DB_SSL_HOSTNAME via PGHOST if set for verify
  export PGSSLMODE=verify-ca
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR" 2>/dev/null || true

stamp="$(date -u +%Y%m%dT%H%M%SZ)"

backup_one() {
  local db="$1"
  local base="$BACKUP_DIR/elx_mcp_${db}_${stamp}"
  local plain="${base}.dump"
  local enc="${plain}.gpg"

  echo "==> Dumping ${db} → ${enc}"
  "$PG_DUMP" \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --username="$DB_USER" \
    --dbname="$db" \
    --format=custom \
    --no-owner \
    --no-acl \
    --file="$plain"

  "$GPG" --batch --yes \
    --symmetric \
    --cipher-algo AES256 \
    --s2k-mode 3 \
    --s2k-digest-algo SHA512 \
    --s2k-count 65011712 \
    --compress-algo none \
    --passphrase "$PASSPHRASE" \
    --output "$enc" \
    "$plain"

  rm -f "$plain"
  chmod 600 "$enc"
  ls -la "$enc"
  echo "OK: $enc"
}

case "$TARGET" in
  elx_mcp_dev | "$DB_NAME")
    backup_one "$DB_NAME"
    ;;
  elx_mcp_test | "$DB_NAME_TEST")
    backup_one "$DB_NAME_TEST"
    ;;
  both)
    backup_one "$DB_NAME"
    backup_one "$DB_NAME_TEST"
    ;;
  *)
    backup_one "$TARGET"
    ;;
esac
