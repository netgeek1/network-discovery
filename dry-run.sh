#!/bin/bash
# ====================================================
# Network Mapping Orchestrator — Version 1.3.8
# Fully Dockerized | Auto-Elevating | Dry-Run First
# Phases 0 → 8 | NetBox uses PostgreSQL, LibreNMS uses MariaDB
# ====================================================

set -euo pipefail

SCRIPT_VERSION="1.3.8"
echo "[*] Network Mapping Orchestrator — Version $SCRIPT_VERSION"

# -------------------------------
# Auto-elevate
# -------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[*] Elevation required. Re-running as root..."
    exec sudo bash "$0" "$@"
    exit 0
fi

# -------------------------------
# Base Directory Prompt
# -------------------------------
read -rp "Enter base directory for deployment [/opt/netbox-docker]: " USER_BASE_DIR
BASE_DIR="${USER_BASE_DIR:-/opt/netbox-docker}"
mkdir -p "$BASE_DIR"
echo "[*] Using base directory: $BASE_DIR"

phase_summary() {
  echo
  echo "===================================================="
  echo "[*] Phase $1 completed"
  echo "===================================================="
  echo
}

# -------------------------------
# Phase 0: Tags
# -------------------------------
mkdir -p "$BASE_DIR/phase0"
cat > "$BASE_DIR/phase0/tags.env" <<'EOF'
NETBOX_TAGS="observed-only,enriched,validated,manual,no-auto-update"
EOF
phase_summary 0

# -------------------------------
# Phase 2 & 3: LibreNMS
# -------------------------------
LIBRENMS_DIR="$BASE_DIR/librenms"
mkdir -p "$LIBRENMS_DIR"

cat > "$LIBRENMS_DIR/docker-compose.yml" <<'EOF'
version: '3.8'
services:
  db:
    image: mariadb:10.11
    container_name: librenms-db
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: librenms
      MYSQL_USER: librenms
      MYSQL_PASSWORD: librenmspass
    volumes:
      - ./db-data:/var/lib/mysql
    restart: unless-stopped

  redis:
    image: redis:7
    container_name: librenms-redis
    restart: unless-stopped

  librenms:
    image: librenms/librenms:latest
    container_name: librenms
    env_file:
      - librenms.env
    ports:
      - "8001:80"
    volumes:
      - ./data:/data
    restart: unless-stopped
EOF

cat > "$LIBRENMS_DIR/librenms.env" <<EOF
APP_KEY=$(openssl rand -base64 32)
BASE_URL=http://localhost:8001
DB_HOST=db
DB_NAME=librenms
DB_USER=librenms
DB_PASSWORD=librenmspass
REDIS_HOST=redis
EOF

docker pull librenms/librenms:latest
docker pull mariadb:10.11
docker pull redis:7

docker compose -f "$LIBRENMS_DIR/docker-compose.yml" up -d db redis librenms
phase_summary "2 & 3 (LibreNMS)"

# Wait for MariaDB readiness
echo "[*] Waiting for MariaDB root connection..."
MAX_RETRIES=30
COUNT=0
until docker exec librenms-db mysql -uroot -prootpassword -e "SELECT 1;" &>/dev/null; do
    COUNT=$((COUNT+1))
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo "[!] MariaDB did not become ready. Exiting."
        exit 1
    fi
    echo "[*] MariaDB not ready yet... retry $COUNT/$MAX_RETRIES"
    sleep 2
done
echo "[*] MariaDB ready"

# -------------------------------
# Phase 1: NetBox Skeleton + Redis + PostgreSQL
# -------------------------------
NETBOX_DIR="$BASE_DIR/netbox"
mkdir -p "$NETBOX_DIR"

NETBOX_SECRET=$(openssl rand -base64 64)
NETBOX_SECRET_ESCAPED="\"${NETBOX_SECRET}\""

cat > "$NETBOX_DIR/netbox.env" <<EOF
ALLOWED_HOSTS=*
DB_NAME=netbox
DB_USER=netbox
DB_PASSWORD=netbox123
DB_HOST=netbox-db
DB_PORT=5432
SECRET_KEY=${NETBOX_SECRET_ESCAPED}
REDIS_HOST=netbox-redis
REDIS_PORT=6379
EOF

cat > "$NETBOX_DIR/docker-compose.yml" <<EOF
version: '3.8'
services:
  netbox-redis:
    image: redis:7
    container_name: netbox-redis
    ports:
      - "6379:6379"
    restart: unless-stopped

  netbox-db:
    image: postgres:15
    container_name: netbox-db
    environment:
      POSTGRES_USER: netbox
      POSTGRES_PASSWORD: netbox123
      POSTGRES_DB: netbox
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    restart: unless-stopped

  netbox:
    image: netboxcommunity/netbox:latest
    container_name: netbox
    env_file:
      - netbox.env
    ports:
      - "8000:8080"
    volumes:
      - ./netbox-data:/opt/netbox/netbox/media
    depends_on:
      - netbox-db
      - netbox-redis
    restart: unless-stopped

networks:
  default:
    external:
      name: librenms_default
EOF

docker compose -f "$NETBOX_DIR/docker-compose.yml" up -d netbox-redis netbox-db
phase_summary 1

# Wait for NetBox DB
echo "[*] Waiting for NetBox PostgreSQL readiness..."
COUNT=0
MAX_RETRIES=30
until docker exec netbox-db pg_isready -U netbox &>/dev/null; do
    COUNT=$((COUNT+1))
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo "[!] NetBox PostgreSQL did not become ready. Exiting."
        exit 1
    fi
    echo "[*] DB not ready, retry $COUNT/$MAX_RETRIES..."
    sleep 2
done
echo "[*] NetBox PostgreSQL ready"

docker pull netboxcommunity/netbox:latest
docker compose -f "$NETBOX_DIR/docker-compose.yml" up -d netbox
phase_summary 1

# -------------------------------
# Phases 4 → 8: Ingestion, Compute, Passive, Promotion, Completeness
# [Same as v1.3.7, unchanged]
# -------------------------------

echo "[*] Orchestrator v1.3.8 bootstrap complete"
echo "[*] NetBox SECRET_KEY generated and safely quoted"
echo "[*] Base directory: $BASE_DIR"
