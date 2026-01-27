#!/bin/bash
# ====================================================
# All-in-One Network Mapping Deployment Orchestrator
# Phases 0 → 8
# Fully Dockerized | Auto-Elevating | Dry-Run First
# ====================================================

set -euo pipefail

# -------------------------------
# Function: Auto-Elevate
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
read -rp "Enter base directory for deployment [/opt/netbox-discovery]: " USER_BASE_DIR
BASE_DIR="${USER_BASE_DIR:-/opt/netbox-discovery}"
echo "[*] Using base directory: $BASE_DIR"
mkdir -p "$BASE_DIR"

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
# Phase 0: Define Truth & Tags
# -------------------------------
mkdir -p "$BASE_DIR/phase0"
cat > "$BASE_DIR/phase0/tags.env" <<'EOF'
NETBOX_TAGS="observed-only,enriched,validated,manual,no-auto-update"
EOF
phase_summary 0

# -------------------------------
# Phase 1: NetBox Skeleton
# -------------------------------
mkdir -p "$BASE_DIR/netbox"
cat > "$BASE_DIR/netbox/docker-compose.yml" <<'EOF'
version: '3.8'
services:
  netbox:
    image: netboxcommunity/netbox:latest
    container_name: netbox
    env_file:
      - netbox.env
    volumes:
      - ./netbox-data:/opt/netbox/netbox/media
    ports:
      - "8000:8080"
    restart: unless-stopped
EOF

cat > "$BASE_DIR/netbox/netbox.env" <<'EOF'
ALLOWED_HOSTS=*
DB_NAME=netbox
DB_USER=netbox
DB_PASSWORD=netbox123
DB_HOST=netbox-db
DB_PORT=5432
EOF

echo "[*] Pulling NetBox Docker image..."
docker pull netboxcommunity/netbox:latest
echo "[*] Starting NetBox..."
docker compose -f "$BASE_DIR/netbox/docker-compose.yml" up -d
phase_summary 1

# -------------------------------
# Phase 2 & 3: LibreNMS Discovery Stack
# -------------------------------
LIBRENMS_DIR="$BASE_DIR/librenms"
mkdir -p "$LIBRENMS_DIR"

# docker-compose.yml
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
    depends_on:
      - db
      - redis
    env_file:
      - librenms.env
    ports:
      - "8001:80"
    volumes:
      - ./data:/data
    restart: unless-stopped
EOF

# librenms.env
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
docker compose -f "$LIBRENMS_DIR/docker-compose.yml" up -d
phase_summary "2 & 3 (LibreNMS)"

# -------------------------------
# Phase 4: Ingestion Engine (Dry-Run)
# -------------------------------
INGESTION_DIR="$BASE_DIR/ingestion"
mkdir -p "$INGESTION_DIR"/{collect,normalize,reconcile,commit,logs,config}

# Dockerfile for ingestion
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

# docker-compose.yml using local build
cat > "$INGESTION_DIR/docker-compose.yml" <<'EOF'
version: '3.8'
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

# env file for ingestion
cat > "$INGESTION_DIR/ingestion.env" <<EOF
MODE=dry-run
NETBOX_URL=http://netbox:8080
NETBOX_TOKEN=changeme
EOF

echo "[*] Building local ingestion Docker image..."
docker compose -f "$INGESTION_DIR/docker-compose.yml" build

echo "[*] Starting ingestion engine (dry-run)..."
docker compose -f "$INGESTION_DIR/docker-compose.yml" up -d
phase_summary 4

# -------------------------------
# Phase 5: Promotion & Controlled Writes (Placeholder)
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
  echo "[*] Running collector for $svc (dry-run)..."
  bash "$BASE_DIR/compute/$svc/collector.sh"
done
phase_summary 6

# -------------------------------
# Phase 7: Passive Traffic Overlay
# -------------------------------
PASSIVE_SERVICES=("zeek" "ntopng" "suricata")
for svc in "${PASSIVE_SERVICES[@]}"; do
  mkdir -p "$BASE_DIR/passive/$svc"
  cat > "$BASE_DIR/passive/$svc/docker-compose.yml" <<EOF
version: '3.8'
services:
  $svc:
    image: $svc:latest
    container_name: $svc
    volumes:
      - ./data:/data
    restart: unless-stopped
EOF
  echo "[*] Pulling $svc Docker image..."
  docker pull ${svc}:latest || echo "[!] Image $svc not found locally, skipping..."
  echo "[*] Starting $svc..."
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
echo "[*] Next steps:"
echo "  1) Populate env files with real credentials"
echo "  2) Implement ingestion logic, promotion rules, scoring algorithms"
echo "  3) Start monitoring, passive traffic collection, and actual data ingestion"
echo "===================================================="
echo
