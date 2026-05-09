#!/usr/bin/env bash
set -Eeuo pipefail
CONTAINER_NAME="${CONTAINER_NAME:-matrixhub-db}"
POSTGRES_USER="${POSTGRES_USER:-matrix}"
POSTGRES_DB="${POSTGRES_DB:-matrixhub}"
docker exec -it "${CONTAINER_NAME}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"
