#!/usr/bin/env bash
set -Eeuo pipefail
DEST="/etc/systemd/system/matrixhub-db.service"
echo "▶ Disabling systemd unit"
sudo systemctl disable --now matrixhub-db.service || true
if [ -f "${DEST}" ]; then
  sudo rm -f "${DEST}"
  sudo systemctl daemon-reload
fi
echo "✅ systemd unit removed"
