#!/bin/bash
# ===============================
# All-in-One Network Mapping Deployment
# Phases 0 → 8
# ===============================

set -euo pipefail

BASE_DIR="/opt/nautobot-docker"
echo "Creating base directory at $BASE_DIR..."
mkdir -p "$BASE_DIR"

# -------------------------------
# Phase 0: Define Truth & Tags
# -------------------------------
mkdir -p "$BASE_DIR/phase0"
cat > "$BASE_DIR/phase0/tags.env" <<'EOF'
# Global Tags for Devices/Interfaces
NETBOX_TAGS="observed-only,enriched,validated,manual,no-auto-update"
EOF

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
# NetBox environment variables
ALLOWED_HOSTS=*
DB_NAME=netbox
DB_USER=netbox
DB_PASSWORD=netbox123
DB_HOST=netbox-db
DB_PORT=5432
EOF

# -------------------------------
# Phase 2 & 3: Discovery Stacks
# -------------------------------
DISCOVERY_SERVICES=("librenms" "netdisco" "nmap")

for svc in "${DISCOVERY_SERVICES[@]}"; do
    mkdir -p "$BASE_DIR/$svc"
    cat > "$BASE_DIR/$svc/docker-compose.yml" <<EOF
version: '3.8'
services:
  $svc:
    image: ${svc}:latest
    container_name: $svc
    env_file:
      - $svc.env
    volumes:
      - ./data:/data
    restart: unless-stopped
EOF
    cat > "$BASE_DIR/$svc/$svc.env" <<EOF
# $svc environment variables
EOF
done

# -------------------------------
# Phase 4: Ingestion Engine
# -------------------------------
mkdir -p "$BASE_DIR/ingestion/{collect,normalize,reconcile,commit,logs,config}"
cat > "$BASE_DIR/ingestion/docker-compose.yml" <<'EOF'
version: '3.8'
services:
  ingestion:
    image: ingestion:latest
    container_name: ingestion
    env_file:
      - ingestion.env
    volumes:
      - ./config:/app/config
      - ./logs:/app/logs
    restart: unless-stopped
EOF

cat > "$BASE_DIR/ingestion/ingestion.env" <<EOF
# Ingestion engine environment
MODE=dry-run
NETBOX_URL=http://netbox:8080
NETBOX_TOKEN=changeme
EOF

# -------------------------------
# Phase 5: Promotion & Controlled Writes
# -------------------------------
mkdir -p "$BASE_DIR/promotion"

# Placeholder scripts
touch "$BASE_DIR/promotion/promote.sh"
chmod +x "$BASE_DIR/promotion/promote.sh"

# -------------------------------
# Phase 6: Compute & Hypervisors
# -------------------------------
COMPUTE_SERVICES=("proxmox" "hyperv" "kvm" "esxi")
for svc in "${COMPUTE_SERVICES[@]}"; do
    mkdir -p "$BASE_DIR/compute/$svc"
    cat > "$BASE_DIR/compute/$svc/collector.sh" <<'EOF'
#!/bin/bash
# Collector stub for $svc
echo "Collecting data from $svc..."
EOF
    chmod +x "$BASE_DIR/compute/$svc/collector.sh"
done

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
done

# -------------------------------
# Phase 8: Completeness & Trust Scoring
# -------------------------------
mkdir -p "$BASE_DIR/completeness"
cat > "$BASE_DIR/completeness/score.sh" <<'EOF'
#!/bin/bash
# Placeholder for trust score calculation
echo "Calculating device and network trust scores..."
EOF
chmod +x "$BASE_DIR/completeness/score.sh"

# -------------------------------
# Summary
# -------------------------------
echo "Deployment skeleton created at $BASE_DIR"
echo "Phase directories:"
ls -1 "$BASE_DIR"

echo "Next steps:"
echo "1) Populate each env file with proper credentials"
echo "2) Implement collectors, ingestion, promotion, and scoring scripts"
echo "3) Start Docker Compose stacks per phase as needed"
echo "4) Run dry-run ingestion before committing anything to NetBox"
