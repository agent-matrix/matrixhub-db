#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------
# Import servers into pgAdmin and list them afterwards (NO setup.py).
#
# Env overrides:
#   PGADMIN_CONTAINER_NAME=pgadmin
#   PGADMIN_USER_EMAIL=admin@matrixhub.io
#   SERVERS_JSON=./servers.json    # optional; if omitted, a minimal one is generated
#   HOST=matrixhub-db PORT=5432 DB=postgres USERNAME=postgres SSLMODE=prefer NAME="MatrixHub DB"
# ---------------------------------------------------------------------

PGADMIN_CONTAINER_NAME="${PGADMIN_CONTAINER_NAME:-pgadmin}"
PGADMIN_USER_EMAIL="${PGADMIN_USER_EMAIL:-admin@matrixhub.io}"
SERVERS_JSON="${SERVERS_JSON:-}"

HOST="${HOST:-matrixhub-db}"
PORT="${PORT:-5432}"
DB="${DB:-postgres}"
USERNAME="${USERNAME:-postgres}"
SSLMODE="${SSLMODE:-prefer}"
NAME="${NAME:-MatrixHub DB}"

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

# Optional heads-up if a stale bind to /pgadmin4/servers.json exists
MOUNT_SRC="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/pgadmin4/servers.json"}}{{.Source}}{{end}}{{end}}' "${PGADMIN_CONTAINER_NAME}")" || true
if [[ -n "${MOUNT_SRC}" ]]; then
  warn "Container has a bind-mount to /pgadmin4/servers.json (host: ${MOUNT_SRC})."
  warn "This is harmless here (we never touch that path), but best practice is to recreate the container without it."
fi

# Make sure we can exec
docker exec "${PGADMIN_CONTAINER_NAME}" true >/dev/null 2>&1 || die "docker exec into '${PGADMIN_CONTAINER_NAME}' failed."

# Prepare servers.json (generate minimal if not provided)
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

# Stream the JSON into the container (avoid docker cp & any overlay quirk)
INSIDE_JSON="/tmp/servers.json"
step "Uploading ${SERVERS_JSON} -> ${PGADMIN_CONTAINER_NAME}:${INSIDE_JSON}"
docker exec -i "${PGADMIN_CONTAINER_NAME}" bash -lc "cat > ${INSIDE_JSON}" < "${SERVERS_JSON}"

# Import WITHOUT setup.py: write directly to /var/lib/pgadmin/pgadmin4.db, adapting to schema
step "Importing servers (schema-aware SQLite)"
docker exec -e PGADMIN_USER_EMAIL="${PGADMIN_USER_EMAIL}" "${PGADMIN_CONTAINER_NAME}" bash -lc "python - <<'PY'
import json, sqlite3, sys, os

DB_PATH = '/var/lib/pgadmin/pgadmin4.db'
JSON_PATH = '/tmp/servers.json'
USER_EMAIL = os.environ.get('PGADMIN_USER_EMAIL')

if not USER_EMAIL:
    print('ERROR: PGADMIN_USER_EMAIL not set', file=sys.stderr); sys.exit(1)

# Load servers.json
with open(JSON_PATH, 'r', encoding='utf-8') as f:
    data = json.load(f)
servers = (data or {}).get('Servers') or {}

con = sqlite3.connect(DB_PATH)
con.row_factory = sqlite3.Row
cur = con.cursor()

# Helper: table columns
def cols(table):
    cur.execute(f\"PRAGMA table_info({table})\")
    return {r['name'] for r in cur.fetchall()}

server_cols      = cols('server')
servergroup_cols = cols('servergroup')
user_cols        = cols('user')

# Locate user
if 'email' not in user_cols or 'id' not in user_cols:
    print('ERROR: Unexpected pgAdmin schema (no user.email/id).', file=sys.stderr); sys.exit(2)
cur.execute('SELECT id FROM user WHERE email = ?', (USER_EMAIL,))
row = cur.fetchone()
if not row:
    print(f\"ERROR: pgAdmin user '{USER_EMAIL}' not found. Log into pgAdmin once with that email.\", file=sys.stderr)
    sys.exit(3)
user_id = row['id']

# Ensure server group 'Servers'
group_name = 'Servers'
if not {'user_id','name'}.issubset(servergroup_cols):
    print('ERROR: Unexpected pgAdmin schema (servergroup).', file=sys.stderr); sys.exit(4)

cur.execute('SELECT id FROM servergroup WHERE user_id=? AND name=?', (user_id, group_name))
r = cur.fetchone()
if r:
    sg_id = r['id']
else:
    # Try to honor 'position' if present, else rely on defaults
    if 'position' in servergroup_cols:
        cur.execute('INSERT INTO servergroup (user_id, name, position) VALUES (?, ?, 1)', (user_id, group_name))
    else:
        cur.execute('INSERT INTO servergroup (user_id, name) VALUES (?, ?)', (user_id, group_name))
    sg_id = cur.lastrowid

created, updated = 0, 0

for _, srv in servers.items():
    name  = (srv.get('Name') or 'Unnamed').strip()
    host  = (srv.get('Host') or 'localhost').strip()
    port  = int(srv.get('Port') or 5432)
    mdb   = (srv.get('MaintenanceDB') or 'postgres').strip()
    uname = (srv.get('Username') or '').strip()
    sslm  = (srv.get('SSLMode') or '').strip()

    # Build column/value dict based on existing schema
    kv = {}
    if 'name' in server_cols:            kv['name'] = name
    if 'host' in server_cols:            kv['host'] = host
    if 'port' in server_cols:            kv['port'] = port
    if 'maintenance_db' in server_cols:  kv['maintenance_db'] = mdb
    if 'username' in server_cols:        kv['username'] = uname
    # Only set ssl_mode if the column exists in this pgAdmin build
    if 'ssl_mode' in server_cols and sslm:
        kv['ssl_mode'] = sslm

    # Does a server with this (user_id, name) exist?
    cur.execute('SELECT id FROM server WHERE user_id=? AND name=?', (user_id, name))
    r = cur.fetchone()
    if r:
        sid = r['id']
        # UPDATE with only present columns
        set_cols = [f\"{c}=?\" for c in kv.keys()]
        cur.execute(f\"UPDATE server SET {', '.join(set_cols)} WHERE id=?\", (*kv.values(), sid))
        updated += 1
    else:
        # INSERT with only present columns + required FKs
        insert_cols = ['user_id', 'servergroup_id'] + list(kv.keys())
        placeholders = ','.join('?' for _ in insert_cols)
        cur.execute(f\"INSERT INTO server ({', '.join(insert_cols)}) VALUES ({placeholders})\",
                    (user_id, sg_id, *kv.values()))
        created += 1

con.commit()
print(f'Import complete. Created: {created}, Updated: {updated}')
PY"

# List servers for the user (works across schema variants)
step "Listing servers for '${PGADMIN_USER_EMAIL}'"
docker exec -e PGADMIN_USER_EMAIL="${PGADMIN_USER_EMAIL}" -i "${PGADMIN_CONTAINER_NAME}" bash -lc "python - <<'PY'
import json, sqlite3, os

DB_PATH = '/var/lib/pgadmin/pgadmin4.db'
EMAIL = os.environ['PGADMIN_USER_EMAIL']

con = sqlite3.connect(DB_PATH)
con.row_factory = sqlite3.Row
cur = con.cursor()

def table_exists(name):
    cur.execute(\"SELECT 1 FROM sqlite_master WHERE type='table' AND name=?\", (name,))
    return cur.fetchone() is not None

def cols(table):
    cur.execute(f\"PRAGMA table_info({table})\")
    return {r['name'] for r in cur.fetchall()}

if not table_exists('server') or not table_exists('user'):
    print('[]'); raise SystemExit

server_cols = cols('server')

# Build SELECT with only columns that exist
sel = [\"u.email AS user\"]
if table_exists('servergroup'): sel.append(\"sg.name AS group_name\")
if 'name' in server_cols:       sel.append('s.name AS server')
if 'host' in server_cols:       sel.append('s.host AS host')
if 'port' in server_cols:       sel.append('s.port AS port')
if 'maintenance_db' in server_cols: sel.append('s.maintenance_db AS database')
if 'username' in server_cols:   sel.append('s.username AS username')

q  = f\"SELECT {', '.join(sel)} FROM server s JOIN user u ON s.user_id = u.id \"
if table_exists('servergroup'): q += \"JOIN servergroup sg ON s.servergroup_id = sg.id \"
q += \"WHERE u.email = ? ORDER BY \"
q += \"group_name, server\" if table_exists('servergroup') else \"server\"

cur.execute(q, (EMAIL,))
print(json.dumps([dict(r) for r in cur.fetchall()], indent=2))
PY"

# Cleanup temp file if created
if [[ -n "${TMP_JSON}" && -f "${TMP_JSON}" ]]; then rm -f "${TMP_JSON}"; fi

printf "✓ Done.\n"
