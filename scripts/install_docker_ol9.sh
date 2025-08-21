#!/usr/bin/env bash
#
# Installs Docker CE on Oracle Linux 9.
# This script is designed to be idempotent (it can be run multiple times safely).

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error.
set -Eeuo pipefail

echo "▶ Step 1/6: Install Docker"

# --- Install prerequisites ---
echo "▶ Ensuring dnf-plugins-core is installed..."
sudo dnf -y install dnf-plugins-core

# --- Add Docker CE official repository ---
# This is the corrected line. Docker uses the CentOS repo for Oracle Linux.
echo "▶ Installing Docker CE repo (Oracle Linux 9 using CentOS repo)..."
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# --- Install Docker Engine ---
echo "▶ Installing Docker packages..."
# The --nobest option is a safeguard against potential dependency issues on OL9.
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --nobest

# --- Start and enable Docker service ---
echo "▶ Starting and enabling the Docker service..."
sudo systemctl start docker
sudo systemctl enable docker

# --- Add current user to the 'docker' group ---
# This allows running Docker commands without sudo.
# Note: You will need to log out and log back in for this change to take effect.
echo "▶ Adding current user '$USER' to the 'docker' group..."
sudo usermod -aG docker $USER

echo "✅ Docker installed successfully."
echo "❗ IMPORTANT: You must log out and log back in for group changes to apply."