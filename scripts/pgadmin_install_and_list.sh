#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------
# Import servers into pgAdmin and list them afterwards.
#
# Env overrides:
#   PGADMIN_CONTAINER_NAME=pgadmin
#   PGADMIN_USER_EMAIL=contact@ruslanmv.com
#   SERVERS_JSON=./servers.json    # optional; if omitted, a minimal one is generated
#   HOST=matrixhub-db PORT=5432 DB=postgres USERNAME=postgres SSLMODE=prefer NAME="MatrixHub DB"
#   AUTO_RECREATE=0                # set to 1 to auto-recreate pgAdmin if a stale /pgadmin4/servers.json mount is found
# ---------------------------------------------------------------------

PGADMIN_CONTAINER_NAME="${PGADMIN_CONTAINER_NAME:-pgadmin}"
PGADMIN_USER_EMAIL="${PGADMIN_USER_EMAIL:-contact@ruslanmv.com}"
SERVERS_JSON="${SERVERS_JSON:-}"

HOST="${HOST:-matrixhub-db}"
PORT="${PORT:-5432}"
DB="${DB:-postgres}"
USERNAME="${USERNAME:-postgres}"
SSLMODE="${SSLMODE:-prefer}"
NAME="${NAME:-MatrixHub DB}"

AUTO_RECREATE="${AUTO_RECREATE:-0}"

step(){ printf "▶ %s\n" "$*"; }
info(){ printf "ℹ %s\n" "$*"; }
warn(){ printf "⚠ %s\n" "$*\n" >&2; }
die(){ printf "✖ %s\n" "$*\n" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker not found."
docker ps -q >/dev/null 2>&1 || die "Docker daemon not reachable."

# Container must be running
if ! docker ps -q -f "name=^${PGADMIN_CONTAINER_NAME}$" | grep -q .; then
  die "Container '${PGADMIN_CONTAINER_NAME}' is not running."
fi

# Detect bind-mount to /pgadmin4/servers.json (this is what breaks cp/exec if the host file no longer exists)
MOUNT_SRC="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/pgadmin4/servers.json"}}{{.Source}}{{end}}{{end}}' "${PGADMIN_CONTAINER_NAME}")" || true
if [[ -n "${MOUNT_SRC}" ]]; then
  warn "Container has a bind-mount to /pgadmin4/servers.json:"
  warn "  host source: ${MOUNT_SRC}"
  if [[ ! -e "${MOUNT_SRC}" ]]; then
    warn "The host source no longer exists. Docker commands may fail with 'not a directory'."
    if [[ "${AUTO_RECREATE}" == "1" ]]; then
      step "Auto-recreate enabled → removing container '${PGADMIN_CONTAINER_NAME}' and starting clean (no servers.json bind)."
      docker stop "${PGADMIN_CONTAINER_NAME}" >/dev/null || true
      docker rm   "${PGADMIN_CONTAINER_NAME}" >/dev/null || true
      # Start pgAdmin WITHOUT autoconfig bind mount; you'll import via this script anyway
      SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      PGADMIN_AUTOCONFIG=0 "${SCRIPT_DIR}/start_pgadmin.sh"
      step "Waiting 10s for pgAdmin to come up..."
      sleep 10
    else
      die $'Stale bind-mount to /pgadmin4/servers.json detected.\nFix: remove & recreate the pgAdmin container WITHOUT that mount.\n  e.g.:\n    docker stop '"${PGADMIN_CONTAINER_NAME}"$'\n    docker rm '"${PGADMIN_CONTAINER_NAME}"$'\n    PGADMIN_AUTOCONFIG=0 ./scripts/start_pgadmin.sh\n(or rerun this script with AUTO_RECREATE=1)'
    fi
  else
    warn "The host source exists; operations may still be flaky. Best practice is to recreate the container without this mount."
  fi
fi

# Sanity: prove we can exec before proceeding
if ! docker exec "${PGADMIN_CONTAINER_NAME}" true 2>/dev/null; then
  die "docker exec into '${PGADMIN_CONTAINER_NAME}' failed. If you saw 'not a directory', recreate the container as described above."
fi

# Prepare servers.json
TMP_JSON=""
if [[ -z "${SERVERS_JSON}" ]]; then
  step "Generating minimal servers.json"
  TMP_JSON="$(mktemp -p "${TMPDIR:-/tmp}" pgadmin-servers.XXXXXX.json)"
  cat > "${TMP_JSON}" <<JSON
{
  "Servers": {
    "1": {
      "Name": "${NAME}",
      "Group": "Servers",
      "Host": "${HOST}",
      "Port": ${PORT},
      "MaintenanceDB": "${DB}",
      "Username": "${USERNAME}",
      "SSLMode": "${SSLMODE}",
      "ConnectNow": false
    }
  }
}
JSON
  SERVERS_JSON="${TMP_JSON}"
fi

[[ -r "${SERVERS_JSON}" ]] || die "servers.json not found or unreadable: ${SERVERS_JSON}"

# Copy into container at a safe path (avoid /pgadmin4 entirely)
INSIDE_JSON="/tmp/servers.json"
step "Copying ${SERVERS_JSON} -> ${PGADMIN_CONTAINER_NAME}:${INSIDE_JSON}"
if ! docker cp "${SERVERS_JSON}" "${PGADMIN_CONTAINER_NAME}:${INSIDE_JSON}"; then
  warn "docker cp failed; falling back to streaming via docker exec."
  # Stream content via stdin (avoids cp quirks)
  docker exec -i "${PGADMIN_CONTAINER_NAME}" bash -lc "cat > ${INSIDE_JSON}" < "${SERVERS_JSON}"
fi

# Choose importer: use setup.py only if 'typer' is present
if docker exec "${PGADMIN_CONTAINER_NAME}" python - <<'PY' >/dev/null 2>&1
import sys
try:
    import typer  # noqa
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
then
  step "Attempting import via setup.py"
  if docker exec "${PGADMIN_CONTAINER_NAME}" bash -lc \
    "python /pgadmin4/setup.py --load-servers ${INSIDE_JSON} --user '${PGADMIN_USER_EMAIL}'"
  then
    step "CLI import succeeded."
  else
    warn "setup.py importer failed; falling back to SQLite importer."
    FALLBACK=1
  fi
else
  info "pgAdmin 'typer' not present; using SQLite importer."
  FALLBACK=1
fi

# Fallback importer writes directly into pgadmin4.db
if [[ "${FALLBACK:-0}" == "1" ]]; then
  docker exec -e PGADMIN_USER_EMAIL="${PGADMIN_USER_EMAIL}" "${PGADMIN_CONTAINER_NAME}" bash -lc "python - <<'PY'
import json, sqlite3, sys, os
DB_PATH = '/var/lib/pgadmin/pgadmin4.db'
JSON_PATH = '/tmp/servers.json'
USER_EMAIL = os.environ.get('PGADMIN_USER_EMAIL')

if not USER_EMAIL:
    print('ERROR: PGADMIN_USER_EMAIL not set', file=sys.stderr); sys.exit(1)

with open(JSON_PATH, 'r', encoding='utf-8') as f:
    data = json.load(f)
servers = (data or {}).get('Servers') or {}

con = sqlite3.connect(DB_PATH)
con.row_factory = sqlite3.Row
cur = con.cursor()

# find user
cur.execute('SELECT id FROM user WHERE email = ?', (USER_EMAIL,))
row = cur.fetchone()
if not row:
    print(f\"ERROR: pgAdmin user '{USER_EMAIL}' not found. Log into pgAdmin once with that email.\", file=sys.stderr)
    sys.exit(2)
user_id = row['id']

# ensure group
group_name = 'Servers'
cur.execute('SELECT id FROM servergroup WHERE user_id=? AND name=?', (user_id, group_name))
r = cur.fetchone()
if r: sg_id = r['id']
else:
    cur.execute('INSERT INTO servergroup (user_id, name, position) VALUES (?, ?, 1)', (user_id, group_name))
    sg_id = cur.lastrowid

created, updated = 0, 0
for _, srv in servers.items():
    name  = srv.get('Name') or 'Unnamed'
    host  = srv.get('Host') or 'localhost'
    port  = int(srv.get('Port') or 5432)
    mdb   = srv.get('MaintenanceDB') or 'postgres'
    uname = srv.get('Username') or ''
    sslm  = srv.get('SSLMode') or 'prefer'

    cur.execute('SELECT id FROM server WHERE user_id=? AND name=?', (user_id, name))
    r = cur.fetchone()
    if r:
        sid = r['id']
        cur.execute('UPDATE server SET host=?, port=?, maintenance_db=?, username=?, ssl_mode=? WHERE id=?',
                    (host, port, mdb, uname, sslm, sid))
        updated += 1
    else:
        cur.execute('INSERT INTO server (user_id, servergroup_id, name, host, port, maintenance_db, username, ssl_mode) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                    (user_id, sg_id, name, host, port, mdb, uname, sslm))
        created += 1

con.commit()
print(f'Import complete. Created: {created}, Updated: {updated}')
PY"
fi

# List servers for the user
step "Listing servers for '${PGADMIN_USER_EMAIL}'"
docker exec -e PGADMIN_USER_EMAIL="${PGADMIN_USER_EMAIL}" -i "${PGADMIN_CONTAINER_NAME}" bash -lc "python - <<'PY'
import json, sqlite3, os
DB_PATH = '/var/lib/pgadmin/pgadmin4.db'
EMAIL = os.environ['PGADMIN_USER_EMAIL']
con = sqlite3.connect(DB_PATH)
con.row_factory = sqlite3.Row
cur = con.cursor()
cur.execute(\"\"\"SELECT u.email AS user,
                      sg.name  AS group_name,
                      s.name   AS server,
                      s.host   AS host,
                      s.port   AS port,
                      s.maintenance_db AS database,
                      s.username AS username
                FROM server s
                JOIN servergroup sg ON s.servergroup_id = sg.id
                JOIN user u ON s.user_id = u.id
                WHERE u.email = ?
                ORDER BY sg.name, s.name;\"\"\", (EMAIL,))
print(json.dumps([dict(r) for r in cur.fetchall()], indent=2))
PY"

# Cleanup temp file if created
if [[ -n "${TMP_JSON:-}" && -f "${TMP_JSON}" ]]; then rm -f "${TMP_JSON}"; fi

printf "✓ Done.\n"
