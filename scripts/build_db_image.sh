#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
IMAGE_NAME="${IMAGE_NAME:-matrixhub-postgres}"
IMAGE_TAG="${IMAGE_TAG:-16-matrixhub}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "▶ Building ${FULL_IMAGE}"
docker build -t "${FULL_IMAGE}" "${ROOT_DIR}/db"
echo "✅ Built ${FULL_IMAGE}"
