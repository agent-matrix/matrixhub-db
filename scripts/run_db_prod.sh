#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------
# Config (overridable via env)
# ---------------------------
# Arguments are now passed from the Makefile 'up' target
CONTAINER_NAME="${1:-${CONTAINER_NAME:-matrixhub-db}}"
VOLUME_NAME="${2:-${VOLUME_NAME:-matrixhub-pgdata}}"
NETWORK_NAME="${3:-${NETWORK_NAME:-matrixhub-net}}"
NETWORK_ALIAS="${4:-${NETWORK_ALIAS:-db}}"
HOST_PORT="${5:-${PG_HOST_PORT:-5432}}"

IMAGE_NAME="${IMAGE_NAME:-matrixhub-postgres}"
IMAGE_TAG="${IMAGE_TAG:-16-matrixhub}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

# Tuning (safe defaults for small VM)
SHARED_BUFFERS="${SHARED_BUFFERS:-128MB}"
WORK_MEM="${WORK_MEM:-4MB}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-200}"

# ---------------------------
# Paths & env-file selection
# ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

# Prefer Makefile-exported DB_ENV_FILE, then local files
ENV_FILE="${DB_ENV_FILE:-}"
if [[ -z "${ENV_FILE}" ]]; then
  if [[ -f "${ROOT_DIR}/.env.db" ]]; then
    ENV_FILE="${ROOT_DIR}/.env.db"
  elif [[ -f "${ROOT_DIR}/.env.db.template" ]]; then
    ENV_FILE="${ROOT_DIR}/.env.db.template"
  fi
fi

step(){ printf "▶ %s\n" "$*"; }
info(){ printf "ℹ %s\n" "$*"; }
die(){ printf "✖ %s\n" "$*" >&2; exit 1; }

[[ -r "${ENV_FILE}" ]] || die "Missing or unreadable env file: ${ENV_FILE}"
command -v docker >/dev/null 2>&1 || die "Docker not found"

# FIXED: Replaced fragile logic with a more robust method to prevent 'unbound variable' errors.
# Source the env file safely to read variables for logging purposes.
if [[ -f "${ENV_FILE}" ]]; then
    set +u # Temporarily disable exit on unbound variable
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set -u # Re-enable it
fi

# Now assign to log variables, using defaults if they were not in the env file.
POSTGRES_USER_LOG="${POSTGRES_USER:-postgres}"
POSTGRES_DB_LOG="${POSTGRES_DB:-postgres}"

# ---------------------------
# Main execution
# ---------------------------
# Ensure network & volume exist
docker network create "${NETWORK_NAME}" >/dev/null 2>&1 || true
docker volume create "${VOLUME_NAME}" >/dev/null 2>&1 || true

# Stop/remove any stale container
if docker ps -q -f name="^${CONTAINER_NAME}$" | grep -q .; then
  step "Stopping existing container ${CONTAINER_NAME}"
  docker stop "${CONTAINER_NAME}" >/dev/null
fi
if docker ps -aq -f name="^${CONTAINER_NAME}$" | grep -q .; then
  step "Removing existing container ${CONTAINER_NAME}"
  docker rm "${CONTAINER_NAME}" >/dev/null
fi

# Run Postgres
step "Starting ${CONTAINER_NAME}"
docker run -d \
  --name "${CONTAINER_NAME}" \
  --network "${NETWORK_NAME}" \
  --network-alias "${NETWORK_ALIAS}" \
  -p "${HOST_PORT}:5432" \
  --env-file "${ENV_FILE}" \
  -v "${VOLUME_NAME}:/var/lib/postgresql/data" \
  --restart unless-stopped \
  --health-cmd='pg_isready -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -h 127.0.0.1' \
  --health-interval=10s --health-timeout=5s --health-retries=5 \
  "${FULL_IMAGE}" \
  -c "shared_buffers=${SHARED_BUFFERS}" \
  -c "work_mem=${WORK_MEM}" \
  -c "max_connections=${MAX_CONNECTIONS}"

echo
step "DB is starting."
info "Health: docker inspect -f '{{.State.Health.Status}}' ${CONTAINER_NAME}"
info "Logs:   docker logs -f ${CONTAINER_NAME}"
info "Conn:   postgres://${POSTGRES_USER_LOG}:***@<server-ip>:${HOST_PORT}/${POSTGRES_DB_LOG}"