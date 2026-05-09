#!/usr/bin/env bash
set -Eeuo pipefail
CMD="${1:-up}"
NETWORK_NAME="${NETWORK_NAME:-matrixhub-net}"
CONTAINER_NAME="postgres-exporter"
EXPORTER_PORT="${EXPORTER_PORT:-9187}"
METRICS_USER="${METRICS_USER:-metrics}"
METRICS_PASSWORD="${METRICS_PASSWORD:-metrics}"

case "$CMD" in
  up)
    docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "▶ Starting postgres_exporter on port ${EXPORTER_PORT}"
    docker run -d \
      --name "$CONTAINER_NAME" \
      --network "$NETWORK_NAME" \
      -p "${EXPORTER_PORT}:9187" \
      -e DATA_SOURCE_NAME="postgresql://${METRICS_USER}:${METRICS_PASSWORD}@db:5432/postgres?sslmode=disable" \
      --restart unless-stopped \
      quay.io/prometheuscommunity/postgres-exporter:latest
    ;;
  down)
    echo "▶ Stopping postgres_exporter"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    ;;
  *) echo "Usage: $0 [up|down]"; exit 1;;
 esac
