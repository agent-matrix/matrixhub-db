#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "▶ Step 1/6: Install Docker"
./scripts/install_docker_ol9.sh

echo "▶ Step 2/6: Open firewall ${PG_HOST_PORT:-5432}"
./scripts/open_firewall_ol9.sh

echo "▶ Step 3/6: Build image"
./scripts/build_db_image.sh

echo "▶ Step 4/6: Run DB"
./scripts/run_db_prod.sh

echo "▶ Step 5/6: Install systemd unit"
./scripts/install_systemd_service.sh

echo "▶ Step 6/6: Wait for healthy"
./scripts/health_wait.sh

echo "✅ Bootstrap complete. Use 'make psql' to connect."
