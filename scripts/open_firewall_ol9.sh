#!/usr/bin/env bash
set -Eeuo pipefail
PORT="${PG_HOST_PORT:-5432}"
echo "▶ Opening firewalld port ${PORT}/tcp"
sudo firewall-cmd --permanent --add-port=${PORT}/tcp
sudo firewall-cmd --reload
echo "✅ firewalld updated"
