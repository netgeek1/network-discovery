#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Helper: prompt with default
# ------------------------------------------------------------
prompt() {
    local message="$1"
    local default="$2"
    read -rp "$message [$default]: " input
    echo "${input:-$default}"
}

REAL_USER="${SUDO_USER:-${LOGNAME:-$(whoami)}}"

log()   { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

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

require_root
install_docker
ensure_docker_group


# ------------------------------------------------------------
# Ask for configuration
# ------------------------------------------------------------
TZ_VALUE=$(prompt "Enter your timezone" "America/New_York")
BASE_DIR=$(prompt "Enter base directory for LibreNMS stack" "/opt/librenms-stack")

echo "Generating random MySQL password..."
MYSQL_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')

echo
echo "SMTP configuration:"
SMTP_HOST=$(prompt "SMTP host" "smtp.gmail.com")
SMTP_PORT=$(prompt "SMTP port" "587")
SMTP_USER=$(prompt "SMTP username" "user@example.com")
SMTP_PASS=$(prompt "SMTP password" "changeme")
SMTP_FROM=$(prompt "SMTP from address" "$SMTP_USER")

# ------------------------------------------------------------
# Determine compose command
# ------------------------------------------------------------
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    apt-get install -y docker-compose-plugin || true
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    else
        echo "Docker Compose not available"
        exit 1
    fi
fi

# ------------------------------------------------------------
# Prepare directory
# ------------------------------------------------------------
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# ------------------------------------------------------------
# Write .env (YAML-safe)
# ------------------------------------------------------------
cat > .env <<EOF
TZ="${TZ_VALUE}"
PUID="1000"
PGID="1000"

MYSQL_DATABASE="librenms"
MYSQL_USER="librenms"
MYSQL_PASSWORD="${MYSQL_PASSWORD}"
EOF

# ------------------------------------------------------------
# Write librenms.env (YAML-safe)
# ------------------------------------------------------------
cat > librenms.env <<EOF
MEMORY_LIMIT="256M"
MAX_INPUT_VARS="1000"
UPLOAD_MAX_SIZE="16M"
OPCACHE_MEM_SIZE="128"
REAL_IP_FROM="0.0.0.0/32"
REAL_IP_HEADER="X-Forwarded-For"
LOG_IP_VAR="remote_addr"

CACHE_DRIVER="redis"
SESSION_DRIVER="redis"
REDIS_HOST="redis"

LIBRENMS_SNMP_COMMUNITY="librenmsdocker"

LIBRENMS_WEATHERMAP="false"
LIBRENMS_WEATHERMAP_SCHEDULE="*/5 * * * *"
EOF

# ------------------------------------------------------------
# Write msmtpd.env (YAML-safe)
# ------------------------------------------------------------
cat > msmtpd.env <<EOF
SMTP_HOST="${SMTP_HOST}"
SMTP_PORT="${SMTP_PORT}"
SMTP_TLS="on"
SMTP_STARTTLS="on"
SMTP_TLS_CHECKCERT="on"
SMTP_AUTH="on"
SMTP_USER="${SMTP_USER}"
SMTP_PASSWORD="${SMTP_PASS}"
SMTP_FROM="${SMTP_FROM}"
EOF

# ------------------------------------------------------------
# Write compose.yml (YAML-safe)
# ------------------------------------------------------------
cat > compose.yml <<'EOF'
name: librenms

services:
  db:
    image: mariadb:10
    container_name: librenms_db
    command:
      - "mysqld"
      - "--innodb-file-per-table=1"
      - "--lower-case-table-names=0"
      - "--character-set-server=utf8mb4"
      - "--collation-server=utf8mb4_unicode_ci"
    volumes:
      - "./db:/var/lib/mysql"
    env_file:
      - "./.env"
    environment:
      - "MARIADB_RANDOM_ROOT_PASSWORD=yes"
    restart: always

  redis:
    image: redis:7.2-alpine
    container_name: librenms_redis
    env_file:
      - "./.env"
    restart: always

  msmtpd:
    image: crazymax/msmtpd:latest
    container_name: librenms_msmtpd
    env_file:
      - "./msmtpd.env"
    restart: always

  librenms:
    image: librenms/librenms:latest
    container_name: librenms
    hostname: librenms
    cap_add:
      - NET_ADMIN
      - NET_RAW
    ports:
      - "8000:8000"
    depends_on:
      - db
      - redis
      - msmtpd
    volumes:
      - "./librenms:/data"
    env_file:
      - "./librenms.env"
      - "./.env"
    environment:
      - "DB_HOST=db"
      - "DB_NAME=${MYSQL_DATABASE}"
      - "DB_USER=${MYSQL_USER}"
      - "DB_PASSWORD=${MYSQL_PASSWORD}"
      - "DB_TIMEOUT=60"
    restart: always

  dispatcher:
    image: librenms/librenms:latest
    container_name: librenms_dispatcher
    hostname: librenms-dispatcher
    cap_add:
      - NET_ADMIN
      - NET_RAW
    depends_on:
      - librenms
      - redis
    volumes:
      - "./librenms:/data"
    env_file:
      - "./librenms.env"
      - "./.env"
    environment:
      - "DB_HOST=db"
      - "DB_NAME=${MYSQL_DATABASE}"
      - "DB_USER=${MYSQL_USER}"
      - "DB_PASSWORD=${MYSQL_PASSWORD}"
      - "DB_TIMEOUT=60"
      - "DISPATCHER_NODE_ID=dispatcher1"
      - "SIDECAR_DISPATCHER=1"
    restart: always

  syslogng:
    image: librenms/librenms:latest
    container_name: librenms_syslogng
    hostname: librenms-syslogng
    cap_add:
      - NET_ADMIN
      - NET_RAW
    depends_on:
      - librenms
      - redis
    ports:
      - "514:514/tcp"
      - "514:514/udp"
    volumes:
      - "./librenms:/data"
    env_file:
      - "./librenms.env"
      - "./.env"
    environment:
      - "DB_HOST=db"
      - "DB_NAME=${MYSQL_DATABASE}"
      - "DB_USER=${MYSQL_USER}"
      - "DB_PASSWORD=${MYSQL_PASSWORD}"
      - "DB_TIMEOUT=60"
      - "SIDECAR_SYSLOGNG=1"
    restart: always

  snmptrapd:
    image: librenms/librenms:latest
    container_name: librenms_snmptrapd
    hostname: librenms-snmptrapd
    cap_add:
      - NET_ADMIN
      - NET_RAW
    depends_on:
      - librenms
      - redis
    ports:
      - "162:162/tcp"
      - "162:162/udp"
    volumes:
      - "./librenms:/data"
    env_file:
      - "./librenms.env"
      - "./.env"
    environment:
      - "DB_HOST=db"
      - "DB_NAME=${MYSQL_DATABASE}"
      - "DB_USER=${MYSQL_USER}"
      - "DB_PASSWORD=${MYSQL_PASSWORD}"
      - "DB_TIMEOUT=60"
      - "SIDECAR_SNMPTRAPD=1"
    restart: always
EOF

# ------------------------------------------------------------
# Deploy stack
# ------------------------------------------------------------
$COMPOSE_CMD up -d

# ------------------------------------------------------------
# Web UI readiness check
# ------------------------------------------------------------
echo "Waiting for LibreNMS web UI to become available..."

for i in {1..60}; do
    if curl -fs http://localhost:8000 >/dev/null 2>&1; then
        echo "LibreNMS is ready at: http://localhost:8000"
        exit 0
    fi
    sleep 2
done

echo "Warning: LibreNMS did not become ready within expected time."
echo "Check logs with: $COMPOSE_CMD logs -f librenms"
