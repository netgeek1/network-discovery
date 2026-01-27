#!/bin/bash
# ====================================================
# Network Mapping Orchestrator — Version 1.3.4
# Fully Dockerized | Auto-Elevating | Dry-Run First
# NetBox uses LibreNMS MariaDB
# SECRET_KEY auto-generated
# MariaDB root access robust
# ====================================================

set -euo pipefail

SCRIPT_VERSION="1.3.4"
echo "[*] Network Mapping Orchestrator — Version $SCRIPT_VERSION"

# -------------------------------
# Auto-Elevate
# -------------------------------
auto_elevate() {
  if [[ $EUID -ne 0 ]]; then
    echo "[*] Elevation required. Re-running as root..."
    exec sudo bash "$0" "$@"
    exit 0
  fi
}
auto_elevate "$@"

# -------------------------------
# Prompt for Base Directory
# -------------------------------
read -rp "Enter base directory for deployment [/opt/netbox-docker]: " USER_BASE_DIR
BASE_DIR="${USER_BASE_DIR:-/opt/netbox-docker}"
mkdir -p "$BASE_DIR"
echo "[*] Using base directory: $BASE_DIR"

# -------------------------------
# Function: Phase Summary
# -------------------------------
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
# Phase 2 & 3: LibreNMS DB
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

echo "[*] Pulling LibreNMS, MariaDB, and Redis images..."
docker pull librenms/librenms:latest
docker pull mariadb:10.11
docker pull redis:7

echo "[*] Starting LibreNMS stack..."
docker compose -f "$LIBRENMS_DIR/docker-compose.yml" up -d db redis librenms
phase_summary "2 & 3 (LibreNMS)"

# -------------------------------
# Wait for MariaDB readiness (with retries)
# -------------------------------
echo "[*] Waiting for MariaDB to accept root connections..."
MAX_RETRIES=30
COUNT=0
until docker exec librenms-db mysql -uroot -prootpassword -e "SELECT 1;" &>/dev/null; do
    COUNT=$((COUNT+1))
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo "[!] MariaDB did not become ready in time. Exiting."
        exit 1
    fi
    echo "[*] MariaDB not ready yet... retry $COUNT/$MAX_RETRIES"
    sleep 2
done
echo "[*] MariaDB is ready for root connections"

# -------------------------------
# Phase 1: NetBox Skeleton
# -------------------------------
NETBOX_DIR="$BASE_DIR/netbox"
mkdir -p "$NETBOX_DIR"

# Auto-generate SECRET_KEY
NETBOX_SECRET=$(openssl rand -base64 64)
echo "[*] Generated NetBox SECRET_KEY"

cat > "$NETBOX_DIR/netbox.env" <<EOF
ALLOWED_HOSTS=*
DB_NAME=netbox
DB_USER=netbox
DB_PASSWORD=netbox123
DB_HOST=db
DB_PORT=3306
DB_WAIT_ATTEMPTS=30
DB_WAIT_SLEEP=5
DB_WAIT_DEBUG=1
SECRET_KEY=${NETBOX_SECRET}
EOF

cat > "$NETBOX_DIR/docker-compose.yml" <<'EOF'
services:
  netbox:
    image: netboxcommunity/netbox:latest
    container_name: netbox
    env_file:
      - netbox.env
    ports:
      - "8000:8080"
    volumes:
      - ./netbox-data:/opt/netbox/netbox/media
    restart: unless-stopped
EOF

# -------------------------------
# Create NetBox DB & User inside MariaDB container
# -------------------------------
echo "[*] Creating NetBox database and user inside LibreNMS MariaDB..."
docker exec -i librenms-db sh -c "mysql -uroot -prootpassword <<SQL
CREATE DATABASE IF NOT EXISTS netbox CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'netbox'@'%' IDENTIFIED BY 'netbox123';
GRANT ALL PRIVILEGES ON netbox.* TO 'netbox'@'%';
FLUSH PRIVILEGES;
SQL"

docker pull netboxcommunity/netbox:latest
docker compose -f "$NETBOX_DIR/docker-compose.yml" up -d netbox
phase_summary 1

# -------------------------------
# Phase 4: Ingestion Engine (Dry-Run)
# -------------------------------
INGESTION_DIR="$BASE_DIR/ingestion"
mkdir -p "$INGESTION_DIR"/{collect,normalize,reconcile,commit,logs,config}

cat > "$INGESTION_DIR/Dockerfile" <<'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY collect/ collect/
COPY normalize/ normalize/
COPY reconcile/ reconcile/
COPY commit/ commit/
COPY config/ config/
RUN pip install requests pyyaml
CMD ["bash", "-c", "echo 'Ingestion engine placeholder — implement your logic here' && sleep infinity"]
EOF

cat > "$INGESTION_DIR/docker-compose.yml" <<'EOF'
services:
  ingestion:
    build: .
    container_name: ingestion
    env_file:
      - ingestion.env
    volumes:
      - ./config:/app/config
      - ./logs:/app/logs
    restart: unless-stopped
EOF

cat > "$INGESTION_DIR/ingestion.env" <<EOF
MODE=dry-run
NETBOX_URL=http://netbox:8080
NETBOX_TOKEN=changeme
EOF

docker compose -f "$INGESTION_DIR/docker-compose.yml" build
docker compose -f "$INGESTION_DIR/docker-compose.yml" up -d
phase_summary 4

# -------------------------------
# Phase 5: Promotion & Controlled Writes
# -------------------------------
mkdir -p "$BASE_DIR/promotion"
touch "$BASE_DIR/promotion/promote.sh"
chmod +x "$BASE_DIR/promotion/promote.sh"
phase_summary 5

# -------------------------------
# Phase 6: Compute & Hypervisors
# -------------------------------
COMPUTE_SERVICES=("proxmox" "hyperv" "kvm" "esxi")
for svc in "${COMPUTE_SERVICES[@]}"; do
  mkdir -p "$BASE_DIR/compute/$svc"
  cat > "$BASE_DIR/compute/$svc/collector.sh" <<'EOF'
#!/bin/bash
echo "[*] Collector stub for $svc running..."
EOF
  chmod +x "$BASE_DIR/compute/$svc/collector.sh"
  bash "$BASE_DIR/compute/$svc/collector.sh"
done
phase_summary 6

# -------------------------------
# Phase 7: Passive Traffic Overlay
# -------------------------------
PASSIVE_SERVICES=("zeek" "ntopng" "suricata")
for svc in "${PASSIVE_SERVICES[@]}"; do
  mkdir -p "$BASE_DIR/passive/$svc"
  
  case $svc in
    zeek)
      cat > "$BASE_DIR/passive/zeek/docker-compose.yml" <<'EOF'
services:
  zeek:
    image: zeek/zeek:latest
    container_name: zeek
    network_mode: host
    cap_add:
      - NET_RAW
      - NET_ADMIN
    volumes:
      - ./zeek-scripts:/zeek/scripts
    command: ["zeek", "-i", "eth0"]
    restart: unless-stopped
EOF
      docker pull zeek/zeek:latest
      ;;
    ntopng)
      cat > "$BASE_DIR/passive/ntopng/docker-compose.yml" <<'EOF'
services:
  ntopng:
    image: ntop/ntopng:latest
    container_name: ntopng
    ports:
      - "3000:3000"
    volumes:
      - ./data:/data
    restart: unless-stopped
EOF
      docker pull ntop/ntopng:latest
      ;;
    suricata)
      cat > "$BASE_DIR/passive/suricata/docker-compose.yml" <<'EOF'
services:
  suricata:
    image: jasonish/suricata:latest
    container_name: suricata
    network_mode: host
    cap_add:
      - NET_RAW
      - NET_ADMIN
      - SYS_NICE
    command: ["-i", "eth0"]
    volumes:
      - ./suricata-logs:/var/log/suricata
    restart: unless-stopped
EOF
      docker pull jasonish/suricata:latest
      ;;
  esac

  docker compose -f "$BASE_DIR/passive/$svc/docker-compose.yml" up -d
done
phase_summary 7

# -------------------------------
# Phase 8: Completeness & Trust Scoring
# -------------------------------
mkdir -p "$BASE_DIR/completeness"
cat > "$BASE_DIR/completeness/score.sh" <<'EOF'
#!/bin/bash
echo "[*] Calculating device and network trust scores (dry-run)..."
EOF
chmod +x "$BASE_DIR/completeness/score.sh"
bash "$BASE_DIR/completeness/score.sh"
phase_summary 8

# -------------------------------
# Deployment Complete
# -------------------------------
echo
echo "===================================================="
echo "[*] Full Phase 0 → 8 bootstrap completed (dry-run)"
echo "[*] NetBox SECRET_KEY has been auto-generated"
echo "[*] Next steps:"
echo "  1) Populate ingestion logic, promotion rules, scoring algorithms"
echo "  2) Configure network capture interfaces for passive tools"
echo "  3) Start full monitoring and data ingestion"
echo "===================================================="
echo
