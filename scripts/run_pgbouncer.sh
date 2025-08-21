#!/usr/bin/env bash
set -Eeuo pipefail
CMD="${1:-up}"
NETWORK_NAME="${NETWORK_NAME:-matrixhub-net}"
PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
CONTAINER_NAME="pgbouncer"
CONFIG_DIR="${CONFIG_DIR:-$(pwd)/pgbouncer}"

case "$CMD" in
  up)
    docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "▶ Starting PgBouncer on port ${PGBOUNCER_PORT}"
    docker run -d \
      --name "$CONTAINER_NAME" \
      --network "$NETWORK_NAME" \
      -p "${PGBOUNCER_PORT}:6432" \
      -v "$CONFIG_DIR/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro" \
      -v "$CONFIG_DIR/userlist.txt:/etc/pgbouncer/userlist.txt:ro" \
      --restart unless-stopped \
      edoburu/pgbouncer:latest
    ;;
  down)
    echo "▶ Stopping PgBouncer"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    ;;
  *)
    echo "Usage: $0 [up|down]"; exit 1;;
 esac
