#!/usr/bin/env bash
set -Eeuo pipefail

# This script builds the Docker image for the database.
# The image name is passed as the first argument from the Makefile.
FULL_IMAGE="${1:-matrixhub-postgres:16-matrixhub}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
DB_DIR="${ROOT_DIR}/db"

step(){ printf "▶ %s\n" "$*"; }
die(){ printf "✖ %s\n" "$*" >&2; exit 1; }

[[ -d "${DB_DIR}" ]] || die "Missing db build context directory: ${DB_DIR}"
[[ -f "${DB_DIR}/Dockerfile" ]] || die "Missing Dockerfile in ${DB_DIR}/Dockerfile"

step "Building ${FULL_IMAGE}"

# Use BuildKit for faster, more efficient builds.
DOCKER_BUILDKIT=1 docker build -t "${FULL_IMAGE}" "${DB_DIR}"

echo "✅ Built ${FULL_IMAGE}"