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
PGADMIN_EMAIL="${PGADMIN_EMAIL:-admin@local}"
PGADMIN_VOLUME_NAME="${PGADMIN_VOLUME_NAME:-matrixhub-pgadmin}"
NETWORK_NAME="${NETWORK_NAME:-matrixhub-net}"

# ---------------------------
# Ensure network & volume
# ---------------------------
if ! ${DOCKER} network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  step "Creating network ${NETWORK_NAME}"
  ${DOCKER} network create "${NETWORK_NAME}" >/dev/null
fi

if ! ${DOCKER} volume inspect "${PGADMIN_VOLUME_NAME}" >/dev/null 2>&1; then
  step "Creating volume ${PGADMIN_VOLUME_NAME}"
  ${DOCKER} volume create "${PGADMIN_VOLUME_NAME}" >/dev/null
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
  -e PGADMIN_DEFAULT_EMAIL="${PGADMIN_EMAIL}" \
  -e PGADMIN_DEFAULT_PASSWORD="${POSTGRES_PASSWORD_VAL}" \
  -e PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED=False \
  -v "${PGADMIN_VOLUME_NAME}:/var/lib/pgadmin" \
  --restart unless-stopped \
  "${PGADMIN_FULL_IMAGE}"

echo
step "pgAdmin is starting."
info "URL:    http://localhost:${PGADMIN_PORT}"
info "Login:  ${PGADMIN_EMAIL}  /  (same as your Postgres password)"
info "Add server in pgAdmin →"
info "  Name:            MatrixHub DB"
info "  Host:            matrixhub-db   (or: db)"
info "  Port:            5432"
info "  Maintenance DB:  ${POSTGRES_DB_VAL}"
info "  Username:        ${POSTGRES_USER_VAL}"
info "  Password:        (same as above)"

# Helpful tip (non-fatal): how to avoid sudo for future runs
if [[ "${DOCKER}" == "sudo docker" ]]; then
  warn "Tip: add your user to the 'docker' group to avoid sudo:"
  warn "  sudo usermod -aG docker $(whoami) && newgrp docker"
fi
