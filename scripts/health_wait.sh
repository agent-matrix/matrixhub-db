#!/usr/bin/env bash
set -Eeuo pipefail
NAME="${CONTAINER_NAME:-matrixhub-db}"
echo "▶ Waiting for ${NAME} to become healthy..."
for i in {1..120}; do
  STATUS="$(docker inspect -f '{{.State.Health.Status}}' "${NAME}" 2>/dev/null || echo starting)"
  if [ "${STATUS}" = "healthy" ]; then
    echo "✅ ${NAME} is healthy"
    exit 0
  fi
  sleep 1

done
echo "✖ Timed out waiting for health=healthy"
docker logs "${NAME}" | tail -n 200
exit 1
