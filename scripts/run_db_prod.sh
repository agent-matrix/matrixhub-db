#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-matrixhub-db}"
IMAGE_NAME="${IMAGE_NAME:-matrixhub-postgres}"
IMAGE_TAG="${IMAGE_TAG:-16-matrixhub}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

HOST_PORT="${PG_HOST_PORT:-5432}"
NETWORK_NAME="${NETWORK_NAME:-matrixhub-net}"
NETWORK_ALIAS="${NETWORK_ALIAS:-db}"
VOLUME_NAME="${VOLUME_NAME:-matrixhub-pgdata}"

# Tuning (safe for tiny VM; raise on bigger shapes)
SHARED_BUFFERS="${SHARED_BUFFERS:-128MB}"
WORK_MEM="${WORK_MEM:-4MB}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-200}"
MAX_WAL_SIZE="${MAX_WAL_SIZE:-1GB}"
CHECKPOINT_TIMEOUT="${CHECKPOINT_TIMEOUT:-15min}"

# TLS (optional): set TLS_ENABLE=1 and mount certs to /certs (server.crt/key)
TLS_ENABLE="${TLS_ENABLE:-0}"
TLS_ARGS=()
if [[ "${TLS_ENABLE}" == "1" ]]; then
  TLS_ARGS+=( -v "${TLS_CERTS_DIR:-$PWD/certs}:/certs:ro" )
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env.db}"

step(){ printf "▶ %s\n" "$*"; }
info(){ printf "ℹ %s\n" "$*"; }
die(){ printf "✖ %s\n" "$*" >&2; exit 1; }

[[ -f "${ENV_FILE}" ]] || die "Missing env file: ${ENV_FILE}"
command -v docker >/dev/null 2>&1 || die "Docker not found"

# Network
if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  step "Creating network ${NETWORK_NAME}"
  docker network create "${NETWORK_NAME}" >/dev/null
fi

# Volume
if ! docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1; then
  step "Creating volume ${VOLUME_NAME}"
  docker volume create "${VOLUME_NAME}" >/dev/null
fi

# Stop/remove stale container
if [ -n "$(docker ps -q -f name="^${CONTAINER_NAME}$")" ]; then
  step "Stopping ${CONTAINER_NAME}"
  docker stop "${CONTAINER_NAME}" >/dev/null
fi
if [ -n "$(docker ps -aq -f name="^${CONTAINER_NAME}$")" ]; then
  step "Removing ${CONTAINER_NAME}"
  docker rm "${CONTAINER_NAME}" >/dev/null
fi

# Pull or fail if missing
if ! docker image inspect "${FULL_IMAGE}" >/dev/null 2>&1; then
  info "Image ${FULL_IMAGE} not local, attempting pull"
  docker pull "${FULL_IMAGE}" 2>/dev/null || die "Image ${FULL_IMAGE} not available. Build with ./scripts/build_db_image.sh"
fi

# Run DB
step "Starting ${CONTAINER_NAME}"

docker run -d \
  --name "${CONTAINER_NAME}" \
  --network "${NETWORK_NAME}" \
  --network-alias "${NETWORK_ALIAS}" \
  -p "${HOST_PORT}:5432" \
  --env-file "${ENV_FILE}" \
  -v "${VOLUME_NAME}:/var/lib/postgresql/data" \
  "${TLS_ARGS[@]}" \
  --restart unless-stopped \
  --health-cmd='pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -h 127.0.0.1' \
  --health-interval=10s --health-timeout=5s --health-retries=5 \
  "${FULL_IMAGE}" \
  -c "shared_buffers=${SHARED_BUFFERS}" \
  -c "work_mem=${WORK_MEM}" \
  -c "max_connections=${MAX_CONNECTIONS}" \
  -c "max_wal_size=${MAX_WAL_SIZE}" \
  -c "checkpoint_timeout=${CHECKPOINT_TIMEOUT}" \
  $( [[ "${TLS_ENABLE}" == "1" ]] && echo -c "ssl=on" -c "ssl_cert_file=/certs/server.crt" -c "ssl_key_file=/certs/server.key" )


echo
step "DB is starting."
info "Health: docker inspect -f '{{.State.Health.Status}}' ${CONTAINER_NAME}"
info "Logs:   docker logs -f ${CONTAINER_NAME}"
info "Conn:   postgres://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@<server-ip>:${HOST_PORT}/\${POSTGRES_DB}"
