#!/usr/bin/env bash
set -Eeuo pipefail
PORT="${PG_HOST_PORT:-5432}"
echo "▶ Closing firewalld port ${PORT}/tcp"
sudo firewall-cmd --permanent --remove-port=${PORT}/tcp || true
sudo firewall-cmd --reload || true
echo "✅ firewalld updated"
