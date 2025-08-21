#!/usr/bin/env bash
set -Eeuo pipefail
SERVICE_FILE="systemd/matrixhub-db.service"
DEST="/etc/systemd/system/matrixhub-db.service"
[ -f "${SERVICE_FILE}" ] || { echo "✖ Missing ${SERVICE_FILE}"; exit 1; }

echo "▶ Installing systemd unit"
sudo cp "${SERVICE_FILE}" "${DEST}"
sudo systemctl daemon-reload
sudo systemctl enable --now matrixhub-db.service
echo "✅ systemd unit installed and enabled"
