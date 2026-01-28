#!/usr/bin/env bash
set -euo pipefail

# This is a basic working Oxidized docker script

# ------------------------------------------------------------
# Root handling
# ------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[INFO] Elevation required — re-running with sudo..."
        sudo -E bash "$0" "$@"
        exit $?
    fi
}

# ------------------------------------------------------------
# Docker install
# ------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed."
    return
  fi

  log "Installing Docker Engine..."

  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release openssl git

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  log "Docker installed."
}

ensure_docker_group() {
  getent group docker >/dev/null || groupadd docker
  if ! id "$REAL_USER" | grep -q docker; then
    log "Adding user '$REAL_USER' to docker group"
    usermod -aG docker "$REAL_USER"
    warn "You may need to log out/in for group changes to apply."
  fi
}

# ============================
#   CONFIGURATION
# ============================
OXI_BASE="/opt/oxidized"
OXI_CFG="${OXI_BASE}/config"
OXI_LOG="${OXI_BASE}/logs"
OXI_COMPOSE="${OXI_BASE}/docker-compose.yml"
CONTAINER="oxidized"

# ============================
#   ROOT CHECK
# ============================
if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root or with sudo."
  exit 1
fi

# ============================
#   DOCKER INSTALL (Ubuntu/Debian)
# ============================
install_docker() {
  echo "[INFO] Installing Docker..."

  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable docker
  systemctl restart docker
}

# ============================
#   ENSURE DOCKER
# ============================
if ! command -v docker >/dev/null 2>&1; then
  install_docker
else
  echo "[INFO] Docker already installed."
fi

if ! docker info >/dev/null 2>&1; then
  echo "[ERROR] Docker daemon not running."
  exit 1
fi

# ============================
#   CREATE DIRECTORIES
# ============================
echo "[INFO] Creating directories..."
mkdir -p "$OXI_CFG" "$OXI_LOG"

# ============================
#   WRITE SAMPLE router.db
# ============================
echo "[INFO] Writing sample router.db..."
cat > "${OXI_CFG}/router.db" <<EOF
10.0.0.1:ios
10.0.0.2:ios
10.0.0.3:junos
EOF

# ============================
#   WRITE SAMPLE config
# ============================
echo "[INFO] Writing sample config..."
cat > "${OXI_CFG}/config" <<'EOF'
---
username: oxidized
password: password
model: ios
interval: 3600
use_syslog: false
debug: false
threads: 30
timeout: 20
retries: 3
prompt: !ruby/regexp /^([\w.@-]+[#>]\s?)$/
rest: 0.0.0.0:8888

vars:
  enable: enable

input:
  default: ssh
  ssh:
    secure: false

output:
  default: git
  git:
    repo: "/home/oxidized/.config/oxidized/repo"

source:
  default: csv
  csv:
    file: "/home/oxidized/.config/oxidized/router.db"
    delimiter: !ruby/regexp /:/
    map:
      name: 0
      model: 1
      group: 2
    vars_map:
      ssh_port: 3
      telnet_port: 4
EOF

# ============================
#   WRITE docker-compose.yml
# ============================
echo "[INFO] Writing docker-compose.yml..."
cat > "$OXI_COMPOSE" <<EOF
version: "3.8"

services:
  oxidized:
    image: oxidized/oxidized:latest
    container_name: oxidized
    restart: unless-stopped
    ports:
      - "8888:8888"
    environment:
      CONFIG_RELOAD: "600"
    volumes:
      - "${OXI_CFG}:/home/oxidized/.config/oxidized"
      - "${OXI_LOG}:/home/oxidized/.config/oxidized/logs"
EOF

# ============================
#   FIX PERMISSIONS
# ============================
echo "[INFO] Fixing permissions..."
chown -R 1000:1000 "$OXI_BASE"
chmod -R 755 "$OXI_BASE"

# ============================
#   START / RESTART CONTAINER
# ============================
echo "[INFO] Starting Oxidized..."
cd "$OXI_BASE"
docker compose pull
docker compose up -d

echo
echo "======================================="
echo " Oxidized Deployment Complete"
echo "======================================="
echo "Config directory: $OXI_CFG"
echo "router.db:        $OXI_CFG/router.db"
echo "Web UI:           http://<host>:8888/"
echo
echo "Oxidized should now show: Loaded 3 nodes"
echo
