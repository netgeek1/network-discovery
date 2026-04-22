#################
# Phase 7 still not working
#################

#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Network Mapping Orchestrator — Version 5.8
#  Base: /opt/orchestrator
#  NetBox (8080) | LibreNMS (8000) | Oxidized (8888)
#  Passive Traffic | Compute Discovery | Ingestion Pipeline
# ============================================================
#  20260421-2211 - v5.8 - Phase 7 fixes
#  20260421-2211 - v5.7 - Phase 7 fixes
#  20260421-2127 - v5.6 - Phase 7 fixes
#  20260421-2113 - v5.5 - Phase 7 fixes
#  20260421-2000 - v5.4 - Phase 7 fixes
#  20260421-1940 - v5.3 - YAML fixes and yq reinstall
#  20260421-1856 - v5.2 - Fixes
#  20260421-1737 - v5.1 - Flags for re-running specific phases
#  20260421-1210 - v5.0 - Functionalized
#  20260421-xxxx - v4.0 - Phase 7 added
#  20260421-xxxx - v3.0 - Phase 6 added
# ============================================================
SCRIPT_VERSION="5.8"

echo
echo "============================================================"
echo "[*] Network Mapping Orchestrator — Version $SCRIPT_VERSION"
echo "============================================================"
echo

# ------------------------------------------------------------
#  User + Logging Helpers
# ------------------------------------------------------------
REAL_USER="${SUDO_USER:-${LOGNAME:-$(whoami)}}"

log()   { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

phase_summary() {
  echo
  echo "===================================================="
  echo "[*] Phase $1 completed"
  echo "===================================================="
  echo
}

# ------------------------------------------------------------
# Flag + sudo handling (single, clean mechanism)
# ------------------------------------------------------------
FLAG_FILE="${FLAG_FILE:-/tmp/fullstack-flags}"

if [[ -z "${FLAGS_LOADED:-}" ]]; then
  # First invocation (non-root or root): parse CLI args once
  RESET=false
  RERUN_PHASE=""
  FROM_PHASE=""
  STATUS=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reset)  RESET=true ;;
      --rerun)  RERUN_PHASE="$2"; shift ;;
      --from)   FROM_PHASE="$2"; shift ;;
      --status) STATUS=true ;;
      *)        ;;  # ignore unknown
    esac
    shift
  done

  # Persist flags so sudo pass can read them
  {
    echo "RESET=$RESET"
    echo "RERUN_PHASE=$RERUN_PHASE"
    echo "FROM_PHASE=$FROM_PHASE"
    echo "STATUS=$STATUS"
  } > "$FLAG_FILE"

  export FLAG_FILE FLAGS_LOADED=1

  # Elevate if needed, preserving only FLAG_FILE + FLAGS_LOADED
  if [[ $EUID -ne 0 ]]; then
    echo "[INFO] Elevation required — re-running with sudo..."
    exec sudo -E FLAG_FILE="$FLAG_FILE" FLAGS_LOADED=1 bash "$0"
  fi
else
  # Second invocation (after sudo): just reload flags
  source "$FLAG_FILE"
fi

# ------------------------------------------------------------
#  Docker install + group
# ------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed."
    return
  fi

  log "Installing Docker Engine..."

  if ! command -v apt-get >/dev/null 2>&1; then
    error "This installer currently expects a Debian/Ubuntu base (apt-get)."
    exit 1
  fi

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

install_docker
ensure_docker_group

# ------------------------------------------------------------
#  Determine compose command
# ------------------------------------------------------------
determine_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    apt-get install -y docker-compose-plugin || true
    if docker compose version >/dev/null 2>&1; then
      COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_CMD="docker-compose"
    else
      error "Docker Compose not available"
      exit 1
    fi
  fi
}

determine_docker_compose

# ------------------------------------------------------------
#  Interactive configuration
# ------------------------------------------------------------
prompt() {
  local message="$1"
  local default="$2"
  read -rp "$message [$default]: " input
  echo "${input:-$default}"
}

interactive_configuration() {
  BASE_ROOT="/opt/orchestrator"
  BASE_ROOT=$(prompt "Enter base directory for orchestrator" "$BASE_ROOT")
  
  TZ_VALUE=$(prompt "Enter your timezone" "America/New_York")
  
  echo "Generating random MySQL password for LibreNMS..."
  LIBRENMS_DB_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
  
  echo
  echo "SMTP configuration for LibreNMS:"
  SMTP_HOST=$(prompt "SMTP host" "smtp.gmail.com")
  SMTP_PORT=$(prompt "SMTP port" "587")
  SMTP_USER=$(prompt "SMTP username" "user@example.com")
  SMTP_PASS=$(prompt "SMTP password" "changeme")
  SMTP_FROM=$(prompt "SMTP from address" "$SMTP_USER")
  
  mkdir -p "$BASE_ROOT"
  
  NETBOX_DIR="$BASE_ROOT/netbox"
  LIBRENMS_DIR="$BASE_ROOT/librenms"
  OXIDIZED_DIR="$BASE_ROOT/oxidized"
  PASSIVE_DIR="$BASE_ROOT/passive"
  COMPUTE_DIR="$BASE_ROOT/compute"
  INGEST_DIR="$BASE_ROOT/ingestion"
  
  mkdir -p "$NETBOX_DIR" "$LIBRENMS_DIR" "$OXIDIZED_DIR" "$PASSIVE_DIR" "$COMPUTE_DIR" "$INGEST_DIR"
}

interactive_configuration

# ------------------------------------------------------------
# Phase Gate + Functionalization Layer
# ------------------------------------------------------------
STATE_DIR="$BASE_ROOT/state"
mkdir -p "$STATE_DIR"

phase_run() {
    local num="$1"
    local func="$2"

    if [[ -f "$STATE_DIR/phase${num}.done" ]]; then
        log "Phase $num already completed — skipping."
        return
    fi

    log "Running Phase $num..."
    $func
    touch "$STATE_DIR/phase${num}.done"
    log "Phase $num complete."
}

# ------------------------------------------------------------
# Apply flags now that STATE_DIR is valid
# ------------------------------------------------------------

if $RESET; then
    echo "[INFO] Resetting orchestrator state..."
    rm -f "$STATE_DIR"/phase*.done 2>/dev/null || true
fi

if [[ -n "$RERUN_PHASE" ]]; then
    echo "[INFO] Re-running phase $RERUN_PHASE..."
    rm -f "$STATE_DIR/phase${RERUN_PHASE}.done" 2>/dev/null || true
fi

if [[ -n "$FROM_PHASE" ]]; then
    echo "[INFO] Running from phase $FROM_PHASE onward..."
    for f in "$STATE_DIR"/phase*.done; do
        num=$(basename "$f" | sed 's/phase//' | sed 's/.done//')
        if (( num >= FROM_PHASE )); then
            rm -f "$f"
        fi
    done
fi

if $STATUS; then
    echo ""
    echo "------------------------------------------------------------"
    echo " Orchestrator Phase Status"
    echo "------------------------------------------------------------"
    for i in {0..8}; do
        if [[ -f "$STATE_DIR/phase${i}.done" ]]; then
            echo "Phase $i: COMPLETE"
        else
            echo "Phase $i: PENDING"
        fi
    done
    echo "------------------------------------------------------------"
    exit 0
fi

# ------------------------------------------------------------
# Additional Helpers
# ------------------------------------------------------------
get_host_ip() {
    # Finds the LAN‑reachable IP, not 127.0.0.1
    ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'
}


# ------------------------------------------------------------
#  Phase 0: Tags / Network
# ------------------------------------------------------------
run_phase0() {
PHASE0_DIR="$BASE_ROOT/phase0"
mkdir -p "$PHASE0_DIR"

cat > "$PHASE0_DIR/tags.env" <<'EOF'
NETBOX_TAGS="observed-only,enriched,validated,manual,no-auto-update"
EOF

docker network create orchestrator_net 2>/dev/null || true

phase_summary 0
}

# ------------------------------------------------------------
#  Phase 1: NetBox (8080)
# ------------------------------------------------------------
run_phase1() {
NETBOX_ENV="$NETBOX_DIR/netbox.env"

NETBOX_SECRET=$(openssl rand -base64 64 | tr -d '\n')

cat > "$NETBOX_ENV" <<EOF
ALLOWED_HOSTS=*
DB_NAME=netbox
DB_USER=netbox
DB_PASSWORD=netbox123
DB_HOST=netbox-db
DB_PORT=5432
SECRET_KEY=${NETBOX_SECRET}
REDIS_HOST=netbox-redis
REDIS_PORT=6379
EOF

cat > "$NETBOX_DIR/docker-compose.yml" <<EOF
services:
  netbox-redis:
    image: redis:7
    container_name: netbox-redis
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
      - "8080:8080"
    environment:
      - "SUPERUSER_EMAIL=admin@example.com"
      - "SUPERUSER_PASSWORD=admin"
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

$COMPOSE_CMD -f "$NETBOX_DIR/docker-compose.yml" pull
$COMPOSE_CMD -f "$NETBOX_DIR/docker-compose.yml" up -d netbox-redis netbox-db

echo "[*] Waiting for NetBox PostgreSQL..."
MAX_RETRIES=30
COUNT=0
until docker exec netbox-db pg_isready -U netbox &>/dev/null; do
  COUNT=$((COUNT+1))
  if [ $COUNT -ge $MAX_RETRIES ]; then
    error "NetBox PostgreSQL not ready. Exiting."
    exit 1
  fi
  echo "[*] DB not ready, retry $COUNT/$MAX_RETRIES..."
  sleep 2
done
echo "[*] NetBox PostgreSQL ready"

echo "[*] Waiting for NetBox Redis..."
COUNT=0
until docker exec netbox-redis redis-cli ping &>/dev/null; do
  COUNT=$((COUNT+1))
  if [ $COUNT -ge $MAX_RETRIES ]; then
    error "NetBox Redis not ready. Exiting."
    exit 1
  fi
  echo "[*] Redis not ready, retry $COUNT/$MAX_RETRIES..."
  sleep 2
done
echo "[*] NetBox Redis ready"

$COMPOSE_CMD -f "$NETBOX_DIR/docker-compose.yml" up -d netbox

echo "[*] Waiting for NetBox web UI on http://localhost:8080..."
for i in {1..60}; do
  if curl -fs http://localhost:8080 >/dev/null 2>&1; then
    echo "[*] NetBox is ready at: http://localhost:8080"
    break
  fi
  sleep 2
done

phase_summary 1
}

# ------------------------------------------------------------
#  Phase 2 & 3: LibreNMS (full multi-container, 8000)
# ------------------------------------------------------------
run_phase2() {
LIBRENMS_ENV="$LIBRENMS_DIR/librenms.env"
LIBRENMS_DOTENV="$LIBRENMS_DIR/.env"
MSMTPD_ENV="$LIBRENMS_DIR/msmtpd.env"
LIBRENMS_COMPOSE="$LIBRENMS_DIR/docker-compose.yml"

cat > "$LIBRENMS_DOTENV" <<EOF
TZ=${TZ_VALUE}
PUID=1000
PGID=1000

MYSQL_DATABASE=librenms
MYSQL_USER=librenms
MYSQL_PASSWORD=${LIBRENMS_DB_PASSWORD}
EOF

cat > "$LIBRENMS_ENV" <<EOF
MEMORY_LIMIT=256M
MAX_INPUT_VARS=1000
UPLOAD_MAX_SIZE=16M
OPCACHE_MEM_SIZE=128
REAL_IP_FROM=0.0.0.0/32
REAL_IP_HEADER=X-Forwarded-For
LOG_IP_VAR=remote_addr

CACHE_DRIVER=redis
SESSION_DRIVER=redis
REDIS_HOST=redis

LIBRENMS_SNMP_COMMUNITY=librenmsdocker

LIBRENMS_WEATHERMAP=false
LIBRENMS_WEATHERMAP_SCHEDULE="*/5 * * * *"
EOF

cat > "$MSMTPD_ENV" <<EOF
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_TLS=on
SMTP_STARTTLS=on
SMTP_TLS_CHECKCERT=on
SMTP_AUTH=on
SMTP_USER=${SMTP_USER}
SMTP_PASSWORD=${SMTP_PASS}
SMTP_FROM=${SMTP_FROM}
EOF

cat > "$LIBRENMS_COMPOSE" <<'EOF'
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
    networks:
      - orchestrator_net

  redis:
    image: redis:7.2-alpine
    container_name: librenms_redis
    env_file:
      - "./.env"
    restart: always
    networks:
      - orchestrator_net

  msmtpd:
    image: crazymax/msmtpd:latest
    container_name: librenms_msmtpd
    env_file:
      - "./msmtpd.env"
    restart: always
    networks:
      - orchestrator_net

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
    networks:
      - orchestrator_net

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
    networks:
      - orchestrator_net

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
    networks:
      - orchestrator_net

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
    networks:
      - orchestrator_net

networks:
  orchestrator_net:
    external: true
EOF

cd "$LIBRENMS_DIR"
$COMPOSE_CMD -f "$LIBRENMS_COMPOSE" pull
$COMPOSE_CMD -f "$LIBRENMS_COMPOSE" up -d

echo "[*] Waiting for LibreNMS web UI on http://localhost:8000..."
for i in {1..90}; do
  if curl -fs http://localhost:8000 >/dev/null 2>&1; then
    echo "[*] LibreNMS is ready at: http://localhost:8000"
    break
  fi
  sleep 2
done

phase_summary "2 & 3 (LibreNMS)"
}

run_phase3() {
phase_summary "3"
}

# ------------------------------------------------------------
#  Phase 4: Oxidized (8888)
# ------------------------------------------------------------
run_phase4() {
OXI_CFG="$OXIDIZED_DIR/config"
OXI_LOG="$OXIDIZED_DIR/logs"
OXI_COMPOSE="$OXIDIZED_DIR/docker-compose.yml"

mkdir -p "$OXI_CFG" "$OXI_LOG"

if [[ ! -f "$OXI_CFG/router.db" ]]; then
cat > "$OXI_CFG/router.db" <<'EOF'
# hostname:model
# example:
# 10.0.0.1:ios
10.0.0.1:ios
10.0.0.2:ios
10.0.0.3:junos
EOF
fi

cat > "$OXI_CFG/config" <<'EOF'
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

cat > "$OXI_COMPOSE" <<EOF
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
    networks:
      - orchestrator_net

networks:
  orchestrator_net:
    external: true
EOF

chown -R 1000:1000 "$OXIDIZED_DIR"
chmod -R 755 "$OXIDIZED_DIR"

cd "$OXIDIZED_DIR"
$COMPOSE_CMD -f "$OXI_COMPOSE" pull
$COMPOSE_CMD -f "$OXI_COMPOSE" up -d

echo "[*] Waiting for Oxidized web UI on http://localhost:8888..."
for i in {1..60}; do
  if curl -fs http://localhost:8888 >/dev/null 2>&1; then
    echo "[*] Oxidized is ready at: http://localhost:8888"
    break
  fi
  sleep 2
done

phase_summary 4
}

# ------------------------------------------------------------
#  Phase 5: Passive Traffic (Zeek, Suricata, Ntopng)
# ------------------------------------------------------------
run_phase5() {
mkdir -p "$PASSIVE_DIR"

read -rp "[*] Enter interface for passive monitoring (e.g., eth0) [eth0]: " MONITOR_IFACE
MONITOR_IFACE="${MONITOR_IFACE:-eth0}"

cat > "$PASSIVE_DIR/zeek-compose.yml" <<EOF
services:
  zeek:
    image: zeek/zeek:lts
    container_name: zeek
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    environment:
      ZEEK_LOG_DIR: /zeek/logs
    command: >
      zeek -i ${MONITOR_IFACE}
    volumes:
      - ./logs:/zeek/logs
      - ./scripts:/zeek/scripts
    restart: unless-stopped
EOF

cat > "$PASSIVE_DIR/suricata-compose.yml" <<EOF
services:
  suricata:
    image: jasonish/suricata:latest
    container_name: suricata
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_NICE
    command: >
      -i ${MONITOR_IFACE}
    volumes:
      - ./logs:/var/log/suricata
    restart: unless-stopped
EOF

cat > "$PASSIVE_DIR/ntopng-compose.yml" <<EOF
services:
  ntopng:
    image: ntop/ntopng:latest
    container_name: ntopng
    network_mode: host
    restart: unless-stopped
EOF

echo "[*] Pulling passive traffic images..."
docker pull zeek/zeek:lts || warn "Zeek image pull failed"
docker pull jasonish/suricata:latest || warn "Suricata image pull failed"
docker pull ntop/ntopng:latest || warn "Ntopng image pull failed"

echo "[*] Starting passive traffic containers..."
cd "$PASSIVE_DIR"
$COMPOSE_CMD -f zeek-compose.yml up -d || warn "Zeek start failed"
$COMPOSE_CMD -f suricata-compose.yml up -d || warn "Suricata start failed"
$COMPOSE_CMD -f ntopng-compose.yml up -d || warn "Ntopng start failed"

echo "[*] Passive traffic Phase complete: Zeek, Suricata, Ntopng running on $MONITOR_IFACE"
phase_summary 5
}

# ------------------------------------------------------------
#  Phase 6: Compute Discovery (Patched + Hardened)
# ------------------------------------------------------------
run_phase6() {
  mkdir -p "$COMPUTE_DIR"

  cat > "$COMPUTE_DIR/discovery.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$BASE_ROOT/output"
mkdir -p "$OUT_DIR"

INVENTORY_YAML="$OUT_DIR/compute-inventory.yaml"
INVENTORY_JSON="$OUT_DIR/compute-inventory.json"
NETBOX_JSON="$OUT_DIR/netbox-ready.json"

log()   { printf '[DISCOVERY] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------
ensure_dep() {
  local bin="$1"
  local pkg="$2"

  # ------------------------------------------------------------
  # Special case: yq MUST be Mike Farah yq v4+
  # ------------------------------------------------------------
  if [[ "$bin" == "yq" ]]; then
    # If yq exists, verify it's the correct one
    if command -v yq >/dev/null 2>&1; then
      if yq --version 2>/dev/null | grep -qi "mikefarah"; then
        return 0
      else
        warn "Incorrect yq detected — replacing with Mike Farah yq v4..."
      fi
    else
      warn "yq not found — installing Mike Farah yq v4..."
    fi

    # Install correct yq
    sudo wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
      -O /usr/bin/yq
    sudo chmod +x /usr/bin/yq

    # Verify installation
    if ! yq --version 2>/dev/null | grep -qi "mikefarah"; then
      warn "Failed to install correct yq — YAML validation will be disabled."
      return 1
    fi

    return 0
  fi

  # ------------------------------------------------------------
  # Default dependency handling for all other binaries
  # ------------------------------------------------------------
  if ! command -v "$bin" >/dev/null 2>&1; then
    warn "$bin not found — installing $pkg..."
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y && sudo apt-get install -y "$pkg"
    else
      warn "apt-get not available; install $pkg manually."
    fi
  fi
}



ensure_dep nmap nmap
ensure_dep nc netcat-openbsd
ensure_dep curl curl
ensure_dep snmpget snmp
ensure_dep yq yq

SNMP_COMMUNITY="${SNMP_COMMUNITY:-public}"

# ------------------------------------------------------------
# Usage
# ------------------------------------------------------------
usage() {
  cat <<USAGE
Usage:
  $0 cidr 10.0.0.0/24
  $0 list hosts.txt

Output:
  $INVENTORY_YAML
USAGE
}

[[ $# -lt 2 ]] && usage && exit 1

MODE="$1"
TARGET="$2"

TMP_HOSTS="$OUT_DIR/hosts.tmp"
> "$TMP_HOSTS"

# ------------------------------------------------------------
# Host enumeration
# ------------------------------------------------------------
case "$MODE" in
  cidr)
    log "Enumerating live hosts in CIDR: $TARGET"
    nmap -sn "$TARGET" -oG - 2>/dev/null | awk '/Up$/{print $2}' > "$TMP_HOSTS" || true
    ;;
  list)
    cp "$TARGET" "$TMP_HOSTS"
    ;;
  *)
    usage
    exit 1
    ;;
esac

if [[ ! -s "$TMP_HOSTS" ]]; then
  warn "No hosts discovered."
  exit 0
fi

log "Discovered hosts:"
cat "$TMP_HOSTS"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
probe_port()  { nc -z -w1 "$1" "$2" >/dev/null 2>&1 && echo true || echo false; }
probe_http()  { curl -fs --max-time 2 "http://$1" >/dev/null 2>&1 && echo true || echo false; }
probe_https() { curl -fs --insecure --max-time 2 "https://$1" >/dev/null 2>&1 && echo true || echo false; }

fetch_http()  { curl -ks --max-time 2 "http://$1" 2>/dev/null || true; }
fetch_https() { curl -ks --max-time 2 "https://$1" 2>/dev/null || true; }

# ------------------------------------------------------------
# SNMP Detection
# ------------------------------------------------------------
snmp_query() {
  local host="$1"
  local oid="$2"
  timeout 1 snmpget -v2c -c "$SNMP_COMMUNITY" -Ovq "$host" "$oid" 2>/dev/null || true
}

detect_snmp_vendor() {
  local host="$1"
  local oid
  oid=$(snmp_query "$host" 1.3.6.1.2.1.1.2.0)

  [[ -z "$oid" ]] && echo "none" && return

  case "$oid" in
    .1.3.6.1.4.1.12356.*) echo "fortinet"; return ;;
    .1.3.6.1.4.1.41112.*) echo "ubiquiti"; return ;;
    .1.3.6.1.4.1.4526.*) echo "netgear"; return ;;
    .1.3.6.1.4.1.11.*|.1.3.6.1.4.1.14823.*) echo "hp-aruba"; return ;;
    .1.3.6.1.4.1.8072.*) echo "freebsd"; return ;;
  esac

  echo "unknown"
}

snmp_enrich() {
  local host="$1"

  local descr name loc
  descr=$(snmp_query "$host" 1.3.6.1.2.1.1.1.0)
  name=$(snmp_query "$host" 1.3.6.1.2.1.1.5.0)
  loc=$(snmp_query "$host" 1.3.6.1.2.1.1.6.0)

  echo "$descr|$name|$loc"
}

# ------------------------------------------------------------
# YAML-safe escaping (corrected)
# ------------------------------------------------------------
yaml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"     # escape backslashes
  s="${s//$'\t'/  }"    # tabs → spaces
  s="${s//$'\r'/}"      # remove CR
  s="${s//$'\n'/\\n}"   # newline → literal \n
  echo "$s"
}

# ------------------------------------------------------------
# MAC OUI Detection
# ------------------------------------------------------------
detect_mac_oui() {
  local host="$1"
  local mac

  mac=$(arp -n "$host" 2>/dev/null | awk '/:/{print $3}' || true)

  if [[ -z "$mac" ]]; then
    mac=$(nmap -n -O --osscan-limit "$host" 2>/dev/null | awk '/MAC Address:/{print $3}' || true)
  fi

  [[ -z "$mac" ]] && echo "none" && return

  local prefix=$(echo "$mac" | awk -F: '{print toupper($1$2$3)}')

  case "$prefix" in
    00163E|F4EAB5|18E829) echo "fortinet"; return ;;
    24A43C|F09FC2|ACE215) echo "ubiquiti"; return ;;
    00184D|A0D3C1|B0C559) echo "netgear"; return ;;
    0024A8|F8E079|D8C7C8) echo "hp-aruba"; return ;;
    000C29|005056) echo "vmware"; return ;;
  esac

  echo "unknown"
}

# ------------------------------------------------------------
# HTTP Vendor Detection
# ------------------------------------------------------------
detect_vendor_http() {
  local host="$1"
  local banner="$(fetch_http "$host")$(fetch_https "$host")"

  echo "$banner" | grep -qiE "Ubiquiti|UniFi|EdgeOS|UISP" && echo "ubiquiti" && return
  echo "$banner" | grep -qiE "Fortinet|FortiGate|FortiSwitch" && echo "fortinet" && return
  echo "$banner" | grep -qi "NETGEAR" && echo "netgear" && return
  echo "$banner" | grep -qiE "Aruba|ProCurve|HP" && echo "hp-aruba" && return
  echo "$banner" | grep -qi "OPNsense" && echo "opnsense" && return
  echo "$banner" | grep -qi "pfSense" && echo "pfsense" && return

  echo "unknown"
}

# ------------------------------------------------------------
# Hypervisor Detection
# ------------------------------------------------------------
detect_hypervisor() {
  local host="$1"

  curl -ks --max-time 2 "https://$host/ui/" | grep -qi "VMware ESXi" && echo "esxi" && return
  curl -ks --max-time 2 "https://$host:8006/" | grep -qi "Proxmox" && echo "proxmox" && return
  nc -z -w1 "$host" 5985 >/dev/null 2>&1 && echo "hyper-v" && return
  nc -z -w1 "$host" 5986 >/dev/null 2>&1 && echo "hyper-v" && return
  curl -ks --max-time 2 "https://$host:443/sdk" | grep -qi "VMware" && echo "vmware-workstation" && return
  nc -z -w1 "$host" 16509 >/dev/null 2>&1 && echo "kvm-libvirt" && return

  echo "none"
}

# ------------------------------------------------------------
# Device Type Classification
# ------------------------------------------------------------
detect_device_type() {
  local vendor="$1"

  case "$vendor" in
    fortinet|ubiquiti) echo "network-appliance"; return ;;
    netgear|hp-aruba) echo "switch"; return ;;
    opnsense|pfsense|freebsd) echo "firewall"; return ;;
    vmware|esxi|proxmox|hyper-v|kvm-libvirt) echo "hypervisor"; return ;;
  esac

  echo "unknown"
}

# ------------------------------------------------------------
# YAML Writer (safe)
# ------------------------------------------------------------
write_yaml_host() {
  cat >> "$INVENTORY_YAML" <<YAML
  - address: "$1"
    vendor: "$2"
    device_type: "$3"
    hypervisor: "$4"
    ssh_open: $5
    rdp_3389_open: $6
    http_open: $7
    https_open: $8
    snmp_sysDescr: "$9"
    snmp_sysName: "${10}"
    snmp_sysLocation: "${11}"
YAML
}

# ------------------------------------------------------------
# Strip SNMP quotes
# ------------------------------------------------------------
strip_snmp_quotes() {
  local s="$1"
  # Remove leading/trailing quotes ONLY if both exist
  if [[ "$s" =~ ^\".*\"$ ]]; then
    s="${s:1:-1}"
  fi
  echo "$s"
}

# ------------------------------------------------------------
# Inventory Generation
# ------------------------------------------------------------
log "Starting Phase 6 unified detection..."

> "$INVENTORY_YAML"
echo "# Phase 6 Inventory" >> "$INVENTORY_YAML"
echo "# Generated: $(date -Iseconds)" >> "$INVENTORY_YAML"
echo "hosts:" >> "$INVENTORY_YAML"

while read -r HOST; do
  [[ -z "$HOST" ]] && continue

  log "Scanning $HOST..."

  SSH_OPEN=$(probe_port "$HOST" 22)
  RDP_OPEN=$(probe_port "$HOST" 3389)
  HTTP_OPEN=$(probe_http "$HOST")
  HTTPS_OPEN=$(probe_https "$HOST")

  EARLY_EXIT=false
  VENDOR="unknown"
  DEVICE_TYPE="unknown"
  HYPERVISOR="none"
  SNMP_DESCR=""
  SNMP_NAME=""
  SNMP_LOC=""

  # 1. Hypervisor
  HYPERVISOR=$(detect_hypervisor "$HOST")
  if [[ "$HYPERVISOR" != "none" ]]; then
    VENDOR="$HYPERVISOR"
    DEVICE_TYPE="hypervisor"
    EARLY_EXIT=true
  fi

  # 2. SNMP
  if [[ "$EARLY_EXIT" != true ]]; then
    SNMP_VENDOR=$(detect_snmp_vendor "$HOST")
    if [[ "$SNMP_VENDOR" != "none" ]]; then
      VENDOR="$SNMP_VENDOR"
      DEVICE_TYPE=$(detect_device_type "$SNMP_VENDOR")
      IFS="|" read -r SNMP_DESCR SNMP_NAME SNMP_LOC <<< "$(snmp_enrich "$HOST")"

      SNMP_DESCR=$(strip_snmp_quotes "$SNMP_DESCR")
      SNMP_NAME=$(strip_snmp_quotes "$SNMP_NAME")
      SNMP_LOC=$(strip_snmp_quotes "$SNMP_LOC")

      SNMP_DESCR_ESCAPED=$(yaml_escape "$SNMP_DESCR")
      SNMP_NAME_ESCAPED=$(yaml_escape "$SNMP_NAME")
      SNMP_LOC_ESCAPED=$(yaml_escape "$SNMP_LOC")

      EARLY_EXIT=true
    fi
  fi

  # 3. MAC OUI
  if [[ "$EARLY_EXIT" != true ]]; then
    OUI_VENDOR=$(detect_mac_oui "$HOST")
    if [[ "$OUI_VENDOR" != "unknown" ]]; then
      VENDOR="$OUI_VENDOR"
      DEVICE_TYPE=$(detect_device_type "$OUI_VENDOR")
      EARLY_EXIT=true
    fi
  fi

  # 4. HTTP fallback
  if [[ "$EARLY_EXIT" != true ]]; then
    VENDOR=$(detect_vendor_http "$HOST")
    DEVICE_TYPE=$(detect_device_type "$VENDOR")
  fi

  # 5. OS fallback
  if [[ "$DEVICE_TYPE" == "unknown" ]]; then
    if [[ "$SSH_OPEN" == "true" && "$RDP_OPEN" == "false" ]]; then
      DEVICE_TYPE="unix-like"
    elif [[ "$RDP_OPEN" == "true" ]]; then
      DEVICE_TYPE="windows-like"
    fi
  fi

  # Escape SNMP fields
  SNMP_DESCR_ESCAPED=$(yaml_escape "$SNMP_DESCR")
  SNMP_NAME_ESCAPED=$(yaml_escape "$SNMP_NAME")
  SNMP_LOC_ESCAPED=$(yaml_escape "$SNMP_LOC")

  write_yaml_host \
    "$HOST" "$VENDOR" "$DEVICE_TYPE" "$HYPERVISOR" \
    "$SSH_OPEN" "$RDP_OPEN" "$HTTP_OPEN" "$HTTPS_OPEN" \
    "$SNMP_DESCR_ESCAPED" "$SNMP_NAME_ESCAPED" "$SNMP_LOC_ESCAPED"

done < "$TMP_HOSTS"

# ------------------------------------------------------------
# YAML Validation (corrected)
# ------------------------------------------------------------
if command -v yq >/dev/null 2>&1; then
  if ! yq eval '.' "$INVENTORY_YAML" >/dev/null 2>&1; then
    warn "Generated YAML is invalid — fix escaping."
    exit 1
  fi
  log "YAML validation passed."
fi

# ------------------------------------------------------------
# JSON Output
# ------------------------------------------------------------
if command -v yq >/dev/null 2>&1; then
  yq eval -o=json "$INVENTORY_YAML" > "$INVENTORY_JSON" || warn "JSON conversion failed."
  log "JSON inventory written to $INVENTORY_JSON"
fi

# ------------------------------------------------------------
# NetBox-ready JSON
# ------------------------------------------------------------
if [[ -f "$INVENTORY_JSON" ]]; then
  jq '{
    devices: [
      .hosts[] | {
        name: (.snmp_sysName // .address),
        primary_ip4: .address,
        device_type: .device_type,
        vendor: .vendor,
        site: (.snmp_sysLocation // "unknown"),
        tags: ["auto-discovered"]
      }
    ]
  }' "$INVENTORY_JSON" > "$NETBOX_JSON" || warn "NetBox conversion failed."

  log "NetBox-ready inventory written to $NETBOX_JSON"
fi

log "Phase 6 complete — inventory written to $INVENTORY_YAML"
log "Next step: Phase 7 ingestion."
EOF

  chmod +x "$COMPUTE_DIR/discovery.sh"
  phase_summary 6
}

# ------------------------------------------------------------
#  Phase 7: Ingestion Engine (DT3 → DT2 → DT1)
# ------------------------------------------------------------
run_phase7() {
PHASE7_DIR="$BASE_ROOT/ingestion"
mkdir -p "$PHASE7_DIR"

cat > "$PHASE7_DIR/ingest.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_FILE="$BASE_ROOT/../compute/output/compute-inventory.yaml"
LOG_FILE="$BASE_ROOT/ingestion.log"

SNMP_COMMUNITY="${SNMP_COMMUNITY:-public}"

log()  { printf '[INGEST] %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
warn() { printf '[WARN] %s\n' "$*" | tee -a "$LOG_FILE" >&2; }

ensure_dep() {
  local bin="$1" pkg="$2"

  if [[ "$bin" == "yq" ]]; then
    if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -qi mikefarah; then
      return 0
    fi
    warn "Installing Mike Farah yq..."
    sudo wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq
    sudo chmod +x /usr/bin/yq
    return 0
  fi

  if ! command -v "$bin" >/dev/null 2>&1; then
    warn "$bin missing — installing $pkg..."
    sudo apt-get update -y && sudo apt-get install -y "$pkg"
  fi
}

ensure_dep curl curl
ensure_dep jq jq
ensure_dep yq yq

[[ ! -f "$INVENTORY_FILE" ]] && { warn "Inventory not found: $INVENTORY_FILE"; exit 1; }

log "Phase 7 ingestion starting, inventory: $INVENTORY_FILE"

if ! yq eval '.' "$INVENTORY_FILE" >/dev/null 2>&1; then
  warn "Inventory YAML invalid."
  exit 1
fi

get_host_ip() { ip route get 1 | awk '{print $7; exit}'; }

NETBOX_URL="http://$(get_host_ip):8080"
LIBRENMS_URL="http://$(get_host_ip):8000"

read -r -s -p "Enter NetBox API token (blank = skip NetBox): " NETBOX_TOKEN < /dev/tty; echo
read -r -s -p "Enter LibreNMS API token (blank = skip LibreNMS): " LIBRENMS_TOKEN < /dev/tty; echo

if [[ -z "$NETBOX_TOKEN" ]]; then warn "Skipping NetBox push."; fi
if [[ -z "$LIBRENMS_TOKEN" ]]; then warn "Skipping LibreNMS push."; fi

nb_get()   { curl -s -H "Authorization: Token $NETBOX_TOKEN" "$NETBOX_URL/api/$1/"; }
nb_post()  { curl -s -X POST  -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" -d "$2" "$NETBOX_URL/api/$1/"; }
nb_patch() { curl -s -X PATCH -H "Authorization: Token $NETBOX_TOKEN" -H "Content-Type: application/json" -d "$2" "$NETBOX_URL/api/$1/"; }
nb_first_id() { nb_get "$1?$2" | jq -r '.results[0].id // empty'; }

slugify() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' /' '--' | tr -cd 'a-z0-9-_'; }
trim()    { echo "$1" | sed 's/^[ \t]*//;s/[ \t]*$//'; }

sanitize() {
  local s="$1"
  s="${s//$'\t'/  }"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  s="${s//\"/\\\"}"
  s="${s//\\/\\\\}"
  echo "$s"
}

select_site() {
  local count
  count=$(nb_get "dcim/sites" | jq '.count')

  if (( count == 0 )); then
    log "No sites exist — creating default site 'Main'"
    nb_post "dcim/sites" '{"name":"Main","slug":"main"}' >/dev/null
    echo "$(nb_first_id dcim/sites slug=main)"
    return
  fi

  if (( count == 1 )); then
    echo "$(nb_get dcim/sites | jq -r '.results[0].id')"
    return
  fi

  log "Multiple sites detected:"
  nb_get dcim/sites | jq -r '.results[] | "\(.id): \(.name)"'

  local sid
  read -r -p "Enter site ID to use: " sid < /dev/tty
  echo "$sid"
}

infer_manufacturer_suggest() {
  local s_lower; s_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

  [[ "$s_lower" =~ netgear ]]   && echo "Netgear"   && return
  [[ "$s_lower" =~ aruba ]]     && echo "HPE Aruba" && return
  [[ "$s_lower" =~ hp\  ]]      && echo "HPE"       && return
  [[ "$s_lower" =~ cisco ]]     && echo "Cisco"     && return
  [[ "$s_lower" =~ ubiquiti ]]  && echo "Ubiquiti"  && return
  [[ "$s_lower" =~ fortigate ]] && echo "Fortinet"  && return
  [[ "$s_lower" =~ pfsense ]]   && echo "pfSense"   && return
  [[ "$s_lower" =~ opnsense ]]  && echo "OPNsense"  && return
  [[ "$s_lower" =~ esxi ]]      && echo "VMware"    && return
  [[ "$s_lower" =~ proxmox ]]   && echo "Proxmox"   && return

  echo ""
}

prompt_manufacturer() {
  local descr="$1"
  local suggestion; suggestion=$(infer_manufacturer_suggest "$descr")

  if [[ -n "$suggestion" ]]; then
    printf "Unknown manufacturer for '%s'. Suggested: %s\n" "$descr" "$suggestion" >&2
    local ans
    read -r -p "Enter manufacturer [$suggestion]: " ans < /dev/tty
    ans=$(trim "$ans")
    [[ -z "$ans" ]] && ans="$suggestion"
    printf "%s" "$ans"
  else
    printf "Unknown manufacturer for '%s'.\n" "$descr" >&2
    local ans
    read -r -p "Enter manufacturer: " ans < /dev/tty
    printf "%s" "$(trim "$ans")"
  fi
}

infer_model_suggest() { echo "$1"; }

prompt_model() {
  local descr="$1"
  local suggestion
  suggestion=$(infer_model_suggest "$descr" 2>/dev/null || echo "$descr")

  printf "Model for '%s'. Suggested: %s\n" "$descr" "$suggestion" >&2
  local ans
  read -r -p "Enter model [$suggestion]: " ans < /dev/tty
  ans=$(trim "$ans")
  [[ -z "$ans" ]] && ans="$suggestion"
  printf "%s" "$ans"
}

infer_platform() {
  local descr="$1"
  local manufacturer="$2"
  local s_lower; s_lower=$(echo "$descr" | tr '[:upper:]' '[:lower:]')

  [[ "$s_lower" =~ ios      ]] && echo "cisco-ios" && return
  [[ "$s_lower" =~ arubaos  ]] && echo "arubaos"   && return
  [[ "$s_lower" =~ edgeos   ]] && echo "edgeos"    && return
  [[ "$s_lower" =~ routeros ]] && echo "routeros"  && return
  [[ "$s_lower" =~ pfsense  ]] && echo "pfsense"   && return
  [[ "$s_lower" =~ opnsense ]] && echo "opnsense"  && return
  [[ "$s_lower" =~ esxi     ]] && echo "esxi"      && return
  [[ "$s_lower" =~ proxmox  ]] && echo "proxmox"   && return

  echo "$manufacturer"
}

infer_role() {
  local vendor="$1" dtype="$2" hyper="$3" descr="$4"

  local v=$(echo "$vendor" | tr '[:upper:]' '[:lower:]')
  local d=$(echo "$dtype"  | tr '[:upper:]' '[:lower:]')
  local h=$(echo "$hyper"  | tr '[:upper:]' '[:lower:]')
  local s=$(echo "$descr"  | tr '[:upper:]' '[:lower:]')

  [[ "$v" =~ fortinet|pfsense|opnsense ]] && echo "Firewall"   && return
  [[ "$v" =~ ubiquiti|netgear|aruba|hp ]] && echo "Switch"     && return
  [[ "$h" != "none" ]]                    && echo "Hypervisor" && return
  [[ "$d" =~ linux|windows|unix ]]        && echo "Server"     && return

  [[ "$s" =~ fortigate ]] && echo "Firewall"    && return
  [[ "$s" =~ firewall  ]] && echo "Firewall"    && return
  [[ "$s" =~ switch    ]] && echo "Switch"      && return
  [[ "$s" =~ router    ]] && echo "Router"      && return
  [[ "$s" =~ ap\  ]]      && echo "Wireless AP" && return
  [[ "$s" =~ esxi      ]] && echo "Hypervisor"  && return
  [[ "$s" =~ hyper-v   ]] && echo "Hypervisor"  && return

  echo "Device"
}

ensure_manufacturer() {
  local name="$1"
  local slug; slug=$(slugify "$name")
  local id; id=$(nb_first_id "dcim/manufacturers" "slug=$slug")
  if [[ -z "$id" ]]; then
    log "Creating manufacturer: $name"
    id=$(nb_post "dcim/manufacturers" "{\"name\":\"$name\",\"slug\":\"$slug\"}" | jq -r '.id')
  fi
  echo "$id"
}

ensure_device_role() {
  local name="$1"
  local slug; slug=$(slugify "$name")
  local id; id=$(nb_first_id "dcim/device-roles" "slug=$slug")
  if [[ -z "$id" ]]; then
    log "Creating device role: $name"
    id=$(nb_post "dcim/device-roles" "{\"name\":\"$name\",\"slug\":\"$slug\"}" | jq -r '.id')
  fi
  echo "$id"
}

ensure_platform() {
  local name="$1"
  local slug; slug=$(slugify "$name")
  local id; id=$(nb_first_id "dcim/platforms" "slug=$slug")
  if [[ -z "$id" ]]; then
    log "Creating platform: $name"
    id=$(nb_post "dcim/platforms" "{\"name\":\"$name\",\"slug\":\"$slug\"}" | jq -r '.id')
  fi
  echo "$id"
}

ensure_device_type() {
  local model="$1" manufacturer_id="$2"
  local slug; slug=$(slugify "$model")
  local id; id=$(nb_first_id "dcim/device-types" "slug=$slug")
  if [[ -z "$id" ]]; then
    log "Creating device type: $model"
    id=$(nb_post "dcim/device-types" "{\"model\":\"$model\",\"slug\":\"$slug\",\"manufacturer\":$manufacturer_id}" | jq -r '.id')
  fi
  echo "$id"
}

ensure_device() {
  local name="$1" dev_type_id="$2" role_id="$3" platform_id="$4" site_id="$5"
  local id; id=$(nb_first_id "dcim/devices" "name=$name")
  if [[ -z "$id" ]]; then
    log "Creating device: $name"
    id=$(nb_post "dcim/devices" \
      "{\"name\":\"$name\",\"device_type\":$dev_type_id,\"device_role\":$role_id,\"platform\":$platform_id,\"site\":$site_id}" \
      | jq -r '.id')
  fi
  echo "$id"
}

ensure_primary_ip() {
  local device_id="$1" ip="$2"
  [[ -z "$ip" || "$ip" == "null" ]] && return

  local ip_id; ip_id=$(nb_first_id "ipam/ip-addresses" "address=$ip")
  if [[ -z "$ip_id" ]]; then
    ip_id=$(nb_post "ipam/ip-addresses" "{\"address\":\"$ip\"}" | jq -r '.id')
  fi

  nb_patch "dcim/devices/$device_id" "{\"primary_ip4\":$ip_id}" >/dev/null
}

ensure_tags() {
  local device_id="$1" vendor="$2" dtype="$3"
  local tags_json; tags_json=$(jq -n --arg v "$vendor" --arg t "$dtype" '[{"name":$v},{"name":$t}]')
  nb_patch "dcim/devices/$device_id" "{\"tags\":$tags_json}" >/dev/null
}

ensure_custom_fields() {
  local device_id="$1" descr="$2" loc="$3"
  local cf_json; cf_json=$(jq -n --arg d "$descr" --arg l "$loc" '{custom_fields:{snmp_descr:$d,snmp_location:$l}}')
  nb_patch "dcim/devices/$device_id" "$cf_json" >/dev/null
}

lnms_add_device() {
  local host="$1"
  [[ -z "$LIBRENMS_TOKEN" ]] && return
  curl -s -X POST -H "X-Auth-Token: $LIBRENMS_TOKEN" -H "Content-Type: application/json" \
    -d "{\"hostname\":\"$host\",\"community\":\"$SNMP_COMMUNITY\",\"version\":\"v2c\"}" \
    "$LIBRENMS_URL/api/v0/devices" >/dev/null 2>&1 || true
}

site_id=""
if [[ -n "$NETBOX_TOKEN" ]]; then
  site_id=$(select_site)
  log "Using site ID: $site_id"
fi

TMP_HOSTS=$(mktemp)
yq eval -o=json '.hosts[]' "$INVENTORY_FILE" | jq -c '.' > "$TMP_HOSTS"

while IFS= read -r item; do
  [[ -z "$item" ]] && continue

  addr=$(echo "$item" | jq -r '.address')
  vendor=$(echo "$item" | jq -r '.vendor')
  dtype=$(echo "$item" | jq -r '.device_type')
  hyper=$(echo "$item" | jq -r '.hypervisor // "none"')
  descr_raw=$(echo "$item" | jq -r '.snmp_sysDescr // ""')
  name_raw=$(echo "$item" | jq -r '.snmp_sysName // ""')
  loc_raw=$(echo "$item" | jq -r '.snmp_sysLocation // ""')

  [[ -z "$addr" || "$addr" == "null" ]] && continue

  descr=$(sanitize "$descr_raw")
  name=$(sanitize "$name_raw")
  loc=$(sanitize "$loc_raw")

  log "Processing $addr ($descr_raw)"

  manufacturer_name=$(prompt_manufacturer "$descr_raw")
  model=$(prompt_model "$descr_raw")
  platform_name=$(infer_platform "$descr_raw" "$manufacturer_name")
  role_name=$(infer_role "$vendor" "$dtype" "$hyper" "$descr_raw")

  if [[ -n "$NETBOX_TOKEN" ]]; then
    mid=$(ensure_manufacturer "$manufacturer_name")
    rid=$(ensure_device_role "$role_name")
    pid=$(ensure_platform "$platform_name")
    dtid=$(ensure_device_type "$model" "$mid")

    dev_name=$(trim "$name_raw")
    [[ -z "$dev_name" || "$dev_name" == "null" ]] && dev_name="$addr"

    did=$(ensure_device "$dev_name" "$dtid" "$rid" "$pid" "$site_id")

    ensure_primary_ip "$did" "$addr"
    ensure_tags "$did" "$vendor" "$dtype"
    ensure_custom_fields "$did" "$descr" "$loc"

    log "✓ NetBox: $addr → device_id=$did model=\"$model\" role=\"$role_name\""
  else
    log "Skipping NetBox for $addr (no token)."
  fi

  if [[ -n "$LIBRENMS_TOKEN" ]]; then
    lnms_add_device "$addr"
    log "✓ LibreNMS: $addr added"
  else
    log "Skipping LibreNMS for $addr (no token)."
  fi

done < "$TMP_HOSTS"

rm -f "$TMP_HOSTS"

log "Phase 7 ingestion complete."
EOF

  chmod +x "$PHASE7_DIR/ingest.sh"
  phase_summary 7
}

# ------------------------------------------------------------
#  Phase 8: Completeness / Promotion
# ------------------------------------------------------------
run_phase8() {
local HIP
HIP=$(get_host_ip)
echo "[*] Phase 8: Validations / Completeness checks"
echo "[*] NetBox:     http://$HIP:8080"
echo "[*] LibreNMS:   http://$HIP:8000"
echo "[*] Oxidized:   http://$HIP:8888"
echo "[*] Passive:    Zeek / Suricata / Ntopng (host mode)"
echo "[*] Compute:    $COMPUTE_DIR/discovery.sh"
echo "[*] Ingestion:  $INGEST_DIR/ingest.sh"

phase_summary 8
}

# ------------------------------------------------------------
#  Main Execution
# ------------------------------------------------------------
phase_run 0 run_phase0
phase_run 1 run_phase1
phase_run 2 run_phase2
phase_run 3 run_phase3
phase_run 4 run_phase4
phase_run 5 run_phase5
phase_run 6 run_phase6
phase_run 7 run_phase7
run_phase8

echo "[*] Orchestrator v$SCRIPT_VERSION"
echo "[*] Base directory: $BASE_ROOT"
echo "[*] You can now run ingestion and compute discovery scripts as needed."
echo "[*] You can also use the following flags:"
echo "[*]                                       --reset         - Deletes all phase state files."
echo "[*]                                       --rerun <phase> - Re-runs only the phase you specify."
echo "[*]                                       --from  <phase> - Runs from a specific phase onward."
