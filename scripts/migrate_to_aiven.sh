#!/usr/bin/env bash
#
# scripts/migrate_to_aiven.sh
#
# One-shot migration of the local matrixhub-db Postgres into the Aiven
# managed Postgres service `pg-37455d5` on DigitalOcean SFO.
#
# Pre-baked target (override via env if your service moves):
#
#     AIVEN_HOST=pg-37455d5-matrixhub-db.c.aivencloud.com
#     AIVEN_PORT=24870
#     AIVEN_USER=avnadmin
#     AIVEN_DB=defaultdb
#     AIVEN_SSLMODE=require
#
# Password is read from $AIVEN_PASSWORD if set, otherwise prompted
# interactively (hidden input). It is automatically URL-encoded so
# `@`, `:`, `/`, `#`, etc. in the password don't break the URI.
#
# Usage:
#   bash scripts/migrate_to_aiven.sh                       # interactive
#   AIVEN_PASSWORD='…' bash scripts/migrate_to_aiven.sh    # non-interactive
#   AUTO=1 AIVEN_PASSWORD='…' bash scripts/migrate_to_aiven.sh
#
# What this script does (in order):
#   0. preflight (docker, psql, pg_restore, source container)
#   1. read .env.db; smoke-test the source DB
#   2. read/prompt the Aiven password and URL-encode it
#   3. probe the Aiven target (psql SELECT version();)
#   4. record source row counts
#   5. pg_dump the source (inside the local container)
#   6. ensure pg_trgm (and optionally vector) on the target
#   7. pg_restore --clean --if-exists --no-owner --no-privileges
#   8. parity check (entity / embedding_chunk / remote)
#   9. make verify against the target
#  10. print the new DATABASE_URL for the Hub's .env
#  11. offer to delete the local dump
#
# It NEVER:
#   - touches the local DB,
#   - rewrites the Hub's .env,
#   - issues DROP DATABASE (only --clean per-object).

set -Eeuo pipefail

# --- baked-in target ---
AIVEN_HOST="${AIVEN_HOST:-pg-37455d5-matrixhub-db.c.aivencloud.com}"
AIVEN_PORT="${AIVEN_PORT:-24870}"
AIVEN_USER="${AIVEN_USER:-avnadmin}"
AIVEN_DB="${AIVEN_DB:-defaultdb}"
AIVEN_SSLMODE="${AIVEN_SSLMODE:-require}"

# --- source ---
CONTAINER_NAME="${CONTAINER_NAME:-matrixhub-db}"
ENV_FILE="${ENV_FILE:-.env.db}"

# --- behaviour ---
AUTO="${AUTO:-0}"
ENABLE_VECTOR="${ENABLE_VECTOR:-0}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"
KEEP_DUMP="${KEEP_DUMP:-1}"   # default keep dump (you'll want it as a fallback)

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
info()  { printf '    %s\n' "$*"; }
hr()    { printf '%.0s-' {1..72}; printf '\n'; }
step()  { printf '\n'; bold "▶ $*"; hr; }

confirm() {
  local prompt="$1" default="${2:-n}" reply
  if [ "$AUTO" = "1" ]; then info "AUTO=1 → answering YES to: $prompt"; return 0; fi
  local hint="[y/N]"; [ "$default" = "y" ] && hint="[Y/n]"
  read -r -p "  $prompt $hint " reply || reply=""
  reply="${reply:-$default}"
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

mask_url() { echo "$1" | sed -E 's#(://[^:]+:)[^@]+(@)#\1***\2#'; }

urlencode() {
  # Encodes everything except A-Z a-z 0-9 - _ . ~
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

trap 'bad "migrate_to_aiven.sh aborted on line $LINENO"' ERR

# ============================================================================
# 0. preflight
# ============================================================================
step "0. Preflight"
[ -f Makefile ] || { bad "run from the matrixhub-db repo root (no Makefile here)"; exit 1; }
command -v docker     >/dev/null || { bad "docker not installed"; exit 1; }
command -v psql       >/dev/null || { bad "psql not installed (sudo dnf install -y postgresql)"; exit 1; }
command -v pg_restore >/dev/null || { bad "pg_restore not installed (same package as psql)"; exit 1; }
command -v python3    >/dev/null || { bad "python3 not installed (needed to URL-encode the password)"; exit 1; }

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  bad "source container '$CONTAINER_NAME' is not running. Start it (make up) and retry."; exit 1
fi
ok "source container '$CONTAINER_NAME' is running"

[ -f "$ENV_FILE" ] || { bad "$ENV_FILE not found at $(pwd)/$ENV_FILE"; exit 1; }

SRC_USER="$(grep -E '^POSTGRES_USER='     "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r')"
SRC_PASS="$(grep -E '^POSTGRES_PASSWORD=' "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r')"
SRC_DB="$(  grep -E '^POSTGRES_DB='       "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r')"
SRC_USER="${SRC_USER:-matrix}"
SRC_DB="${SRC_DB:-matrixhub}"
[ -n "$SRC_PASS" ] || { bad "POSTGRES_PASSWORD missing in $ENV_FILE"; exit 1; }
ok "source: db=$SRC_DB user=$SRC_USER (password masked)"

# ============================================================================
# 1. source smoke test
# ============================================================================
step "1. Smoke test source"
SRC_VER="$(docker exec "$CONTAINER_NAME" psql -U "$SRC_USER" -d "$SRC_DB" -tAc 'SELECT version();' || true)"
[ -n "$SRC_VER" ] || { bad "could not query source DB"; exit 1; }
ok "source: $(echo "$SRC_VER" | head -c 100)"

SRC_COUNTS="$(docker exec "$CONTAINER_NAME" psql -U "$SRC_USER" -d "$SRC_DB" -tAc \
  "SELECT 'entity='||(SELECT count(*) FROM entity)||', embedding_chunk='||(SELECT count(*) FROM embedding_chunk)||', remote='||(SELECT count(*) FROM remote);")"
ok "source rows: $SRC_COUNTS"

# ============================================================================
# 2. password
# ============================================================================
step "2. Aiven credentials"
info "target host: $AIVEN_HOST:$AIVEN_PORT"
info "target db:   $AIVEN_DB"
info "target user: $AIVEN_USER"

if [ -z "${AIVEN_PASSWORD:-}" ]; then
  if [ "$AUTO" = "1" ]; then
    bad "AUTO=1 but AIVEN_PASSWORD is not set"; exit 1
  fi
  read -r -s -p "  Aiven password for $AIVEN_USER (paste from Aiven UI, hidden input): " AIVEN_PASSWORD
  echo
fi
[ -n "$AIVEN_PASSWORD" ] || { bad "empty password"; exit 1; }

PW_ENC="$(urlencode "$AIVEN_PASSWORD")"
PSQL_URL="postgresql://${AIVEN_USER}:${PW_ENC}@${AIVEN_HOST}:${AIVEN_PORT}/${AIVEN_DB}?sslmode=${AIVEN_SSLMODE}"
SQLA_URL="postgresql+psycopg://${AIVEN_USER}:${PW_ENC}@${AIVEN_HOST}:${AIVEN_PORT}/${AIVEN_DB}?sslmode=${AIVEN_SSLMODE}"
ok "URI built: $(mask_url "$PSQL_URL")"

# ============================================================================
# 3. probe target
# ============================================================================
step "3. Probe Aiven target"
if ! PGCONNECT_TIMEOUT=15 psql "$PSQL_URL" -tAc 'SELECT version();' >/tmp/_aiven_ver 2>&1; then
  bad "cannot connect to Aiven:"
  sed 's/^/      /' /tmp/_aiven_ver
  info ""
  info "Common causes:"
  info "  • Service still in 'Building' state in the Aiven UI — wait for 'Running'."
  info "  • Wrong password (note: this script URL-encodes for you, so paste the raw value)."
  info "  • Outbound 24870 blocked (rare; OCI default egress allows it)."
  exit 1
fi
ok "Aiven: $(head -c 110 /tmp/_aiven_ver)"

# ============================================================================
# 4. confirm + region warning
# ============================================================================
warn "About to overwrite objects inside Aiven database '$AIVEN_DB' on $AIVEN_HOST."
warn "Aiven service region is DigitalOcean SFO; your OCI VMs are in IAD (~70 ms RTT)."
warn "If that's not what you want, cancel here and recreate the Aiven service in"
warn "aws-us-east-1 / do-nyc, then rerun."
confirm "Proceed with the migration?" "n" || { info "aborted."; exit 0; }

# ============================================================================
# 5. pg_dump
# ============================================================================
step "5. pg_dump source → ./backups/"
TS="$(date +%Y%m%d_%H%M%S)"
mkdir -p backups
DUMP_FILE="${DUMP_FILE:-backups/aiven-migration-${TS}.dump}"
info "writing → $DUMP_FILE"

# Use the container's pg_dump so server/client versions match exactly.
docker exec "$CONTAINER_NAME" pg_dump \
  -U "$SRC_USER" -d "$SRC_DB" \
  --format=custom --no-owner --no-privileges \
  --file="/tmp/aiven-migration-${TS}.dump"
docker cp "$CONTAINER_NAME:/tmp/aiven-migration-${TS}.dump" "$DUMP_FILE"
docker exec "$CONTAINER_NAME" rm -f "/tmp/aiven-migration-${TS}.dump"
ok "dump complete: $(ls -lh "$DUMP_FILE" | awk '{print $5, $9}')"

# ============================================================================
# 6. extensions
# ============================================================================
step "6. Ensure extensions on Aiven"
PGCONNECT_TIMEOUT=15 psql "$PSQL_URL" -v ON_ERROR_STOP=1 <<'SQL' \
  || warn "could not create pg_trgm — Aiven Free should support it; check service plan"
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL
ok "pg_trgm ready"

if [ "$ENABLE_VECTOR" = "1" ]; then
  PGCONNECT_TIMEOUT=15 psql "$PSQL_URL" -v ON_ERROR_STOP=1 <<'SQL' \
    || warn "could not create vector — pgvector may need to be enabled in Aiven service settings"
CREATE EXTENSION IF NOT EXISTS vector;
SQL
  ok "vector ready"
fi

# ============================================================================
# 7. pg_restore
# ============================================================================
step "7. pg_restore into Aiven"
pg_restore \
  --dbname="$PSQL_URL" \
  --no-owner --no-privileges \
  --clean --if-exists \
  --exit-on-error \
  --verbose \
  "$DUMP_FILE" 2> >(sed 's/^/    /' >&2) || {
    bad "pg_restore failed — Aiven left in partial state. The Hub still points at the old DB, you can retry safely."
    exit 1
  }
ok "restore complete"

# ============================================================================
# 8. parity check
# ============================================================================
step "8. Row-count parity"
TGT_COUNTS="$(PGCONNECT_TIMEOUT=15 psql "$PSQL_URL" -tAc \
  "SELECT 'entity='||(SELECT count(*) FROM entity)||', embedding_chunk='||(SELECT count(*) FROM embedding_chunk)||', remote='||(SELECT count(*) FROM remote);")"
ok "Aiven rows: $TGT_COUNTS"
if [ "$SRC_COUNTS" = "$TGT_COUNTS" ]; then
  ok "row counts match — migration is data-complete"
else
  warn "row counts differ; data may have changed during dump:"
  info "  source: $SRC_COUNTS"
  info "  Aiven : $TGT_COUNTS"
fi

# ============================================================================
# 9. make verify
# ============================================================================
step "9. make verify against Aiven"
if [ "$SKIP_VERIFY" = "1" ]; then
  info "SKIP_VERIFY=1, skipping"
elif grep -qE '^verify:' Makefile; then
  if DATABASE_URL="$PSQL_URL" make verify 2>&1 | sed 's/^/    /'; then
    ok "make verify passed"
  else
    bad "make verify FAILED — review above before flipping the Hub"
    exit 1
  fi
else
  info "no 'verify' target in Makefile, skipping"
fi

# ============================================================================
# 10. new Hub env line
# ============================================================================
step "10. New DATABASE_URL for the Hub"
echo
echo "  Paste this into ~/matrix-hub/.env on the Hub VM (replaces the old DATABASE_URL):"
echo
printf '    DATABASE_URL=%s\n' "$SQLA_URL"
echo
info "Then on the Hub host:"
info "  docker stop matrixhub && docker rm matrixhub"
info "  bash scripts/run_container.sh"
info "  docker logs -f matrixhub | grep -iE 'postgres|sqlite|alembic|listening'"
info "  curl -ksS https://127.0.0.1:443/health?check_db=true   # expect db:\"ok\""
info ""
info "Public smoke from your laptop:"
info "  curl -fsS https://api.matrixhub.io/health?check_db=true"
info "  curl -fsS https://api.matrixhub.io/catalog?limit=1"
info "  curl -fsS \"https://www.matrixhub.io/api/search?q=watsonx&type=any&limit=5\""

# ============================================================================
# 11. cleanup
# ============================================================================
step "11. Cleanup"
if [ "$KEEP_DUMP" = "1" ]; then
  ok "keeping local dump → $DUMP_FILE"
  info "(treat it as sensitive; .gitignore already excludes ./backups/)"
elif confirm "Delete the local dump file ($DUMP_FILE)?" "n"; then
  rm -f "$DUMP_FILE"
  ok "removed $DUMP_FILE"
else
  ok "kept $DUMP_FILE"
fi

bold "✓ Aiven migration complete"
info "Recommended next moves:"
info "  • leave the OL9 Postgres VM up for ~7 days as a hot backup,"
info "  • after stability, tighten Aiven IP allowlist:"
info "      $AIVEN_HOST → allow 129.213.165.60/32 (Hub) and 141.148.40.165/32 (this VM),"
info "  • if cross-coast latency (SFO ↔ IAD ~70 ms) hurts, recreate the Aiven service in"
info "    aws-us-east-1 or do-nyc and rerun this script."
