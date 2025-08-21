#!/usr/bin/env bash
set -Eeuo pipefail
# Install Docker CE on Oracle Linux 9

if ! command -v sudo >/dev/null 2>&1; then
  echo "✖ sudo is required"; exit 1
fi

echo "▶ Installing Docker CE repo (Oracle Linux 9)"
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/oracle/docker-ce.repo

echo "▶ Installing Docker"
sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "▶ Enabling and starting docker"
sudo systemctl enable --now docker

# Add current user to docker group (requires re-login)
if ! id -nG "$USER" | grep -qw docker; then
  echo "▶ Adding $USER to docker group"
  sudo usermod -aG docker "$USER"
  echo "ℹ You may need to log out/in (or run 'newgrp docker') to use docker without sudo."
fi

echo "✅ Docker installed"
