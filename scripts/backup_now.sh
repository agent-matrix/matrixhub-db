#!/usr/bin/env bash
set -Eeuo pipefail
BACKUP_DIR="${BACKUP_DIR:-$(pwd)/backups}"
CONTAINER_NAME="${CONTAINER_NAME:-matrixhub-db}"
POSTGRES_USER="${POSTGRES_USER:-matrix}"
POSTGRES_DB="${POSTGRES_DB:-matrixhub}"
FILE="$BACKUP_DIR/matrixhub-$(date +%F-%H%M%S).dump"
mkdir -p "$BACKUP_DIR"
echo "▶ Creating backup $FILE"
docker exec "$CONTAINER_NAME" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$FILE"
echo "✅ Backup complete"
