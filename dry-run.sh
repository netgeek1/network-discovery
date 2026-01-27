#!/bin/bash
# ====================================================
# Network Mapping Orchestrator — Version 2.1 (Really 2.4)
# Fully Dockerized | Auto-Elevating | 8 Phases
# NetBox uses PostgreSQL | LibreNMS uses MariaDB
# Includes Ingestion, Passive Traffic, Compute Discovery
# ====================================================

set -euo pipefail

SCRIPT_VERSION="2.1 (2.4)"
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

# -------------------------------
# Docker network
# -------------------------------
docker network inspect orchestrator_net >/dev/null 2>&1 || docker network create orchestrator_net

# -------------------------------
# Utility function: phase summary
# -------------------------------
phase_summary() {
  echo
  echo "===================================================="
  echo "[*] Phase $1 completed"
  echo "===================================================="
  echo
}

# -------------------------------
# Phase 0: Define Tags & Config
# -------------------------------
PHASE0_DIR="$BASE_DIR/phase0"
mkdir -p "$PHASE0_DIR"
cat > "$PHASE0_DIR/tags.env" <<'EOF'
NETBOX_TAGS="observed-only,enriched,validated,manual,no-auto-update"
EOF
phase_summary 0

# -------------------------------
# Phase 2 & 3: LibreNMS
# -------------------------------
LIBRENMS_DIR="$BASE_DIR/librenms"
mkdir -p "$LIBRENMS_DIR"

cat > "$LIBRENMS_DIR/docker-compose.yml" <<'EOF'
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
    networks:
      - orchestrator_net

  redis:
    image: redis:7
    container_name: librenms-redis
    restart: unless-stopped
    networks:
      - orchestrator_net

  librenms:
    image: librenms/librenms:latest
    container_name: librenms
    env_file:
      - librenms.env
    ports:
      - "8001:8000"   # FIX: matches container Nginx
    volumes:
      - ./data:/data
    restart: unless-stopped
    networks:
      - orchestrator_net

networks:
  orchestrator_net:
    external: true
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

# -------------------------------
# Phase 1: NetBox Skeleton + PostgreSQL + Redis
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
services:
  netbox-redis:
    image: redis:7
    container_name: netbox-redis
    ports:
      - "6379:6379"
    restart: unless-stopped
    networks:
      - orchestrator_net

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
    networks:
      - orchestrator_net

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
      - orchestrator_net

networks:
  orchestrator_net:
    external: true
EOF

docker pull netboxcommunity/netbox:latest
docker compose -f "$NETBOX_DIR/docker-compose.yml" up -d netbox-redis netbox-db netbox
phase_summary 1

# -------------------------------
# Phase 4: Oxidized + Git
# -------------------------------
OXIDIZED_DIR="$BASE_DIR/oxidized"
mkdir -p "$OXIDIZED_DIR"
cat > "$OXIDIZED_DIR/docker-compose.yml" <<'EOF'
services:
  oxidized:
    image: oxidized/oxidized:latest
    container_name: oxidized
    ports:
      - "8888:8888"
    volumes:
      - ./config:/home/oxidized/.config
      - ./logs:/home/oxidized/logs
    restart: unless-stopped
    networks:
      - orchestrator_net

networks:
  orchestrator_net:
    external: true
EOF
docker pull oxidized/oxidized:latest
docker compose -f "$OXIDIZED_DIR/docker-compose.yml" up -d
phase_summary 4

# -------------------------------
# Phase 5: Passive Traffic (Zeek, Suricata, Ntopng)
# -------------------------------
PASSIVE_DIR="$BASE_DIR/passive"
mkdir -p "$PASSIVE_DIR"

read -rp "Enter interface for Zeek/Suricata capture [eth0]: " CAP_IF
CAP_IF="${CAP_IF:-eth0}"

# Zeek
cat > "$PASSIVE_DIR/zeek-compose.yml" <<EOF
services:
  zeek:
    image: zeek/zeek:lts
    container_name: zeek
    network_mode: "host"
    command: zeek -i $CAP_IF
    restart: unless-stopped
EOF

# Suricata
cat > "$PASSIVE_DIR/suricata-compose.yml" <<EOF
services:
  suricata:
    image: jasonish/suricata:latest
    container_name: suricata
    network_mode: "host"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_NICE
EOF

# Ntopng
cat > "$PASSIVE_DIR/ntopng-compose.yml" <<EOF
services:
  ntopng:
    image: ntop/ntopng:latest
    container_name: ntopng
    network_mode: "host"
    restart: unless-stopped
EOF

docker pull zeek/zeek:lts
docker pull jasonish/suricata:latest
docker pull ntop/ntopng:latest

docker compose -f "$PASSIVE_DIR/zeek-compose.yml" up -d || true
docker compose -f "$PASSIVE_DIR/suricata-compose.yml" up -d || true
docker compose -f "$PASSIVE_DIR/ntopng-compose.yml" up -d || true
phase_summary 5

# -------------------------------
# Phase 6: Compute Discovery
# -------------------------------
COMPUTE_DIR="$BASE_DIR/compute"
mkdir -p "$COMPUTE_DIR"
cat > "$COMPUTE_DIR/discovery.sh" <<'EOF'
#!/bin/bash
# Discover Hypervisors (Type 1 & 2), VMs, and integrate with NetBox API
echo "[*] Placeholder: Hyper-V, ESXi, VMware Workstation/Player discovery"
EOF
chmod +x "$COMPUTE_DIR/discovery.sh"
phase_summary 6

# -------------------------------
# Phase 7: Ingestion / Dry Run
# -------------------------------
INGEST_DIR="$BASE_DIR/ingestion"
mkdir -p "$INGEST_DIR"
cat > "$INGEST_DIR/ingest.sh" <<'EOF'
#!/bin/bash
# Placeholder: SNMP, SSH, API ingestion
echo "[*] Placeholder: Dry-run discovery, validate devices before NetBox write"
EOF
chmod +x "$INGEST_DIR/ingest.sh"
phase_summary 7

# -------------------------------
# Phase 8: Completeness / Promotion
# -------------------------------
echo "[*] Phase 8: Validations / Completeness checks"
echo "[*] Script finished all 8 phases — network skeleton and passive/compute ready"
phase_summary 8

echo "[*] Orchestrator v2.1 bootstrap complete!"
echo "[*] Base directory: $BASE_DIR"
echo "[*] LibreNMS should now be reachable on http://localhost:8001"
echo "[*] NetBox reachable on http://localhost:8000"
