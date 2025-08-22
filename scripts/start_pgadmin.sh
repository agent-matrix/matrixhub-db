#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------
# Pretty printing
# ---------------------------
step(){ printf "▶ %s\n" "$*"; }
info(){ printf "ℹ %s\n" "$*"; }
warn(){ printf "⚠ %s\n" "$*\n" >&2; }
die(){ printf "✖ %s\n" "$*\n" >&2; exit 1; }

# ---------------------------
# Choose docker runner (docker or sudo docker)
# ---------------------------
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    DOCKER="sudo docker"
  else
    die "Docker daemon not accessible for user $(whoami). Install Docker, or run via sudo, or add your user to the 'docker' group."
  fi
fi

# ---------------------------
# Paths & env-file resolution
# ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

# Prefer explicit ENV_FILE, then Makefile-exported DB_ENV_FILE, then local files
ENV_FILE_CANDIDATE="${ENV_FILE:-${DB_ENV_FILE:-}}"
if [[ -z "${ENV_FILE_CANDIDATE}" ]]; then
  if [[ -f "${ROOT_DIR}/.env.db" ]]; then
    ENV_FILE_CANDIDATE="${ROOT_DIR}/.env.db"
  elif [[ -f "${ROOT_DIR}/.env.db.template" ]]; then
    ENV_FILE_CANDIDATE="${ROOT_DIR}/.env.db.template"
  fi
fi

# If still not found, create a template and use it (plus a friendly symlink)
if [[ -z "${ENV_FILE_CANDIDATE}" ]]; then
  step "No .env.db(.template) found — creating template with safe defaults"
  printf "POSTGRES_USER=postgres\nPOSTGRES_PASSWORD=postgres\nPOSTGRES_DB=postgres\nPGDATA=/var/lib/postgresql/data/pgdata\n" > "${ROOT_DIR}/.env.db.template"
  ln -sfn .env.db.template "${ROOT_DIR}/.env.db" || true
  ENV_FILE_CANDIDATE="${ROOT_DIR}/.env.db.template"
fi

ENV_FILE="${ENV_FILE_CANDIDATE}"
[[ -r "${ENV_FILE}" ]] || die "Missing or unreadable env file: ${ENV_FILE}"

# Load Postgres creds for pgAdmin login (do not export to env)
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}"
set -u
POSTGRES_USER_VAL="${POSTGRES_USER:-postgres}"
POSTGRES_DB_VAL="${POSTGRES_DB:-postgres}"
POSTGRES_PASSWORD_VAL="${POSTGRES_PASSWORD:-postgres}"

# ---------------------------
# Config (overridable via env)
# ---------------------------
PGADMIN_CONTAINER_NAME="${PGADMIN_CONTAINER_NAME:-pgadmin}"
PGADMIN_IMAGE="${PGADMIN_IMAGE:-dpage/pgadmin4}"
PGADMIN_TAG="${PGADMIN_TAG:-latest}"
PGADMIN_FULL_IMAGE="${PGADMIN_IMAGE}:${PGADMIN_TAG}"
PGADMIN_PORT="${PGADMIN_PORT:-5050}"
PGADMIN_EMAIL="${PGADMIN_EMAIL:-contact@ruslanmv.com}"   # valid default
PGADMIN_VOLUME_NAME="${PGADMIN_VOLUME_NAME:-matrixhub-pgadmin}"
NETWORK_NAME="${NETWORK_NAME:-matrixhub-net}"
TZ_VAL="${TZ:-UTC}"

# Auto-config & reset (ON by default)
PGADMIN_AUTOCONFIG="${PGADMIN_AUTOCONFIG:-1}"        # 1=enable servers.json + .pgpass
PGADMIN_RESET="${PGADMIN_RESET:-0}"                  # 1=wipe pgadmin volume before start
PGADMIN_DB_HOST="${PGADMIN_DB_HOST:-matrixhub-db}"   # host inside Docker network
PGADMIN_DB_PORT="${PGADMIN_DB_PORT:-5432}"

# Basic email sanity check to avoid restart loop
if ! [[ "${PGADMIN_EMAIL}" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
  warn "PGADMIN_EMAIL='${PGADMIN_EMAIL}' looks invalid; falling back to contact@ruslanmv.com"
  PGADMIN_EMAIL="contact@ruslanmv.com"
fi

# ---------------------------
# Ensure network & volume
# ---------------------------
if ! ${DOCKER} network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  step "Creating network ${NETWORK_NAME}"
  ${DOCKER} network create "${NETWORK_NAME}" >/dev/null
fi

if [[ "${PGADMIN_RESET}" == "1" ]]; then
  warn "PGADMIN_RESET=1 → removing volume '${PGADMIN_VOLUME_NAME}' (pgAdmin data will be reset)."
  ${DOCKER} volume rm "${PGADMIN_VOLUME_NAME}" >/dev/null 2>&1 || true
fi

if ! ${DOCKER} volume inspect "${PGADMIN_VOLUME_NAME}" >/dev/null 2>&1; then
  step "Creating volume ${PGADMIN_VOLUME_NAME}"
  ${DOCKER} volume create "${PGADMIN_VOLUME_NAME}" >/dev/null
fi

# ---------------------------
# Optional: prepare servers.json and .pgpass for auto-connect
# ---------------------------
EXTRA_MOUNTS=()
SERVERS_JSON=""
PGPASS_FILE=""

cleanup_tmp() {
  [[ -n "${SERVERS_JSON}" && -f "${SERVERS_JSON}" ]] && rm -f "${SERVERS_JSON}" || true
  [[ -n "${PGPASS_FILE}" && -f "${PGPASS_FILE}" ]] && rm -f "${PGPASS_FILE}" || true
}
trap cleanup_tmp EXIT

if [[ "${PGADMIN_AUTOCONFIG}" == "1" ]]; then
  step "Preparing auto-config for pgAdmin (servers.json + .pgpass)"

  # Create a temporary servers.json describing "MatrixHub DB"
  SERVERS_JSON="$(mktemp -p "${TMPDIR:-/tmp}" pgadmin-servers.XXXXXX.json)"
  cat > "${SERVERS_JSON}" <<JSON
{
  "Servers": {
    "1": {
      "Name": "MatrixHub DB",
      "Group": "Servers",
      "Host": "${PGADMIN_DB_HOST}",
      "Port": ${PGADMIN_DB_PORT},
      "MaintenanceDB": "${POSTGRES_DB_VAL}",
      "Username": "${POSTGRES_USER_VAL}",
      "SSLMode": "prefer",
      "ConnectNow": true
    }
  }
}
JSON

  # Create a temporary .pgpass so pgAdmin/libpq can connect without prompting.
  # IMPORTANT: libpq demands 0600 perms and ownership by the running user (pgadmin).
  # We'll copy it into the container after start and chown it to pgadmin:pgadmin.
  PGPASS_FILE="$(mktemp -p "${TMPDIR:-/tmp}" pgpass.XXXXXX)"
  printf "%s:%s:*:%s:%s\n" \
    "${PGADMIN_DB_HOST}" "${PGADMIN_DB_PORT}" "${POSTGRES_USER_VAL}" "${POSTGRES_PASSWORD_VAL}" > "${PGPASS_FILE}"
  chmod 600 "${PGPASS_FILE}"

  # Mount servers.json for first-run import. (.pgpass will be copied post-start)
  EXTRA_MOUNTS+=( -v "${SERVERS_JSON}:/pgadmin4/servers.json:ro" )

  info "Auto-config files prepared:"
  info "  servers.json: ${SERVERS_JSON}"
  info "  .pgpass:      ${PGPASS_FILE}"
  info "Note: If the pgAdmin volume already has data, servers.json import may be skipped."
fi

# ---------------------------
# Stop/remove any stale container
# ---------------------------
if [ -n "$(${DOCKER} ps -q -f name="^${PGADMIN_CONTAINER_NAME}$")" ]; then
  step "Stopping ${PGADMIN_CONTAINER_NAME}"
  ${DOCKER} stop "${PGADMIN_CONTAINER_NAME}" >/dev/null
fi
if [ -n "$(${DOCKER} ps -aq -f name="^${PGADMIN_CONTAINER_NAME}$")" ]; then
  step "Removing ${PGADMIN_CONTAINER_NAME}"
  ${DOCKER} rm "${PGADMIN_CONTAINER_NAME}" >/dev/null
fi

# ---------------------------
# Run pgAdmin (password = Postgres password)
# ---------------------------
step "Starting ${PGADMIN_CONTAINER_NAME}"

${DOCKER} run -d \
  --name "${PGADMIN_CONTAINER_NAME}" \
  --network "${NETWORK_NAME}" \
  -p "${PGADMIN_PORT}:80" \
  -e TZ="${TZ_VAL}" \
  -e PGADMIN_DEFAULT_EMAIL="${PGADMIN_EMAIL}" \
  -e PGADMIN_DEFAULT_PASSWORD="${POSTGRES_PASSWORD_VAL}" \
  -e PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED=False \
  -e PGADMIN_CONFIG_ENHANCED_COOKIE_PROTECTION=True \
  -e PGADMIN_CONFIG_CONSOLE_LOG_LEVEL=20 \
  "${EXTRA_MOUNTS[@]}" \
  -v "${PGADMIN_VOLUME_NAME}:/var/lib/pgadmin" \
  --restart unless-stopped \
  "${PGADMIN_FULL_IMAGE}"

# If we prepared a .pgpass, copy it *into* the container and fix ownership & perms.
if [[ "${PGADMIN_AUTOCONFIG}" == "1" && -n "${PGPASS_FILE}" && -f "${PGPASS_FILE}" ]]; then
  step "Installing .pgpass inside the container with correct ownership/permissions"
  ${DOCKER} cp "${PGPASS_FILE}" "${PGADMIN_CONTAINER_NAME}:/var/lib/pgadmin/.pgpass"
  ${DOCKER} exec "${PGADMIN_CONTAINER_NAME}" bash -lc \
    "chown pgadmin:pgadmin /var/lib/pgadmin/.pgpass && chmod 600 /var/lib/pgadmin/.pgpass" || \
    warn "Could not chown/chmod .pgpass inside container (continuing)."
fi

# ---------------------------
# Best-effort: open OS firewall (Oracle Linux / firewalld)
# ---------------------------
maybe_open_firewall() {
  # Use helper if present
  if [[ -x "${ROOT_DIR}/scripts/open_firewall_ol9.sh" ]]; then
    info "Opening firewall port ${PGADMIN_PORT}/tcp via helper script (idempotent)"
    sudo "${ROOT_DIR}/scripts/open_firewall_ol9.sh" "${PGADMIN_PORT}" || true
    return
  fi
  # Otherwise, try firewalld directly
  if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
    info "Opening firewall port ${PGADMIN_PORT}/tcp via firewalld (idempotent)"
    sudo firewall-cmd --permanent --add-port="${PGADMIN_PORT}"/tcp >/dev/null 2>&1 || true
    sudo firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}
maybe_open_firewall || true

# ---------------------------
# Health wait: ensure pgAdmin responds (HTTP 200/302)
# ---------------------------
step "Waiting for pgAdmin to become ready on http://127.0.0.1:${PGADMIN_PORT}/ ..."
READY=0
for i in {1..60}; do
  code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PGADMIN_PORT}/" || true)"
  if [[ "${code}" == "200" || "${code}" == "302" ]]; then
    READY=1
    break
  fi
  sleep 2
done
if [[ "${READY}" -eq 1 ]]; then
  info "pgAdmin is ready (HTTP ${code})."
else
  warn "pgAdmin did not become ready in time. Check logs: ${DOCKER} logs -f ${PGADMIN_CONTAINER_NAME}"
fi

echo
step "pgAdmin is starting."
info "Local URL:  http://localhost:${PGADMIN_PORT}"
info "Remote URL: http://<server-public-ip>:${PGADMIN_PORT}"
info "Login:      ${PGADMIN_EMAIL}  /  (same as your Postgres password)"
info "Preloaded server:"
info "  Name:            MatrixHub DB"
info "  Host:            ${PGADMIN_DB_HOST}   (container network)"
info "  Port:            ${PGADMIN_DB_PORT}"
info "  Maintenance DB:  ${POSTGRES_DB_VAL}"
info "  Username:        ${POSTGRES_USER_VAL}"
if [[ "${PGADMIN_AUTOCONFIG}" == "1" ]]; then
  info "Auto-config enabled: server is preloaded via servers.json; password supplied via .pgpass (owned by pgadmin)."
  info "If you don't see the server, the pgAdmin volume had existing data. Re-run with PGADMIN_RESET=1."
fi

# Helpful tip (non-fatal): how to avoid sudo for future runs
if [[ "${DOCKER}" == "sudo docker" ]]; then
  warn "Tip: add your user to the 'docker' group to avoid sudo:"
  warn "  sudo usermod -aG docker $(whoami) && newgrp docker"
fi
