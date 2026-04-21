#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Network Mapping Orchestrator — Version 3.0
#  Base: /opt/orchestrator
#  NetBox (8080) | LibreNMS (8000) | Oxidized (8888)
#  Passive Traffic | Compute Discovery | Ingestion Pipeline
# ============================================================
#  v3.0 - Phase 6 added
# ============================================================

SCRIPT_VERSION="3.0"

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
#  Root handling
# ------------------------------------------------------------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[INFO] Elevation required — re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

require_root

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

# ------------------------------------------------------------
#  Interactive configuration
# ------------------------------------------------------------
prompt() {
  local message="$1"
  local default="$2"
  read -rp "$message [$default]: " input
  echo "${input:-$default}"
}

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

# ------------------------------------------------------------
#  Phase 0: Tags / Network
# ------------------------------------------------------------
PHASE0_DIR="$BASE_ROOT/phase0"
mkdir -p "$PHASE0_DIR"

cat > "$PHASE0_DIR/tags.env" <<'EOF'
NETBOX_TAGS="observed-only,enriched,validated,manual,no-auto-update"
EOF

docker network create orchestrator_net 2>/dev/null || true

phase_summary 0

# ------------------------------------------------------------
#  Phase 1: NetBox (8080)
# ------------------------------------------------------------
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

# ------------------------------------------------------------
#  Phase 2 & 3: LibreNMS (full multi-container, 8000)
# ------------------------------------------------------------
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

# ------------------------------------------------------------
#  Phase 4: Oxidized (8888)
# ------------------------------------------------------------
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

# ------------------------------------------------------------
#  Phase 5: Passive Traffic (Zeek, Suricata, Ntopng)
# ------------------------------------------------------------
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

# ------------------------------------------------------------
#  Phase 6: Compute Discovery
# ------------------------------------------------------------
mkdir -p "$COMPUTE_DIR"

cat > "$COMPUTE_DIR/discovery.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$BASE_DIR/output"
mkdir -p "$OUT_DIR"

INVENTORY_YAML="$OUT_DIR/compute-inventory.yaml"

log()   { printf '[DISCOVERY] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------
ensure_dep() {
  local bin="$1"
  local pkg="$2"

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
# SNMP Detection (sysObjectID + sysDescr + sysName + sysLocation)
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
    .1.3.6.1.4.1.8072.*) echo "freebsd"; return ;; # pfSense/OPNsense base
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
# HTTP Vendor Detection (fallback)
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
    fortinet) echo "network-appliance"; return ;;
    ubiquiti) echo "network-appliance"; return ;;
    netgear) echo "switch"; return ;;
    hp-aruba) echo "switch"; return ;;
    opnsense|pfsense) echo "firewall"; return ;;
    freebsd) echo "firewall"; return ;;
    vmware|esxi|proxmox|hyper-v|kvm-libvirt) echo "hypervisor"; return ;;
  esac

  echo "unknown"
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

  # 1. Hypervisor (fast)
  HYPERVISOR=$(detect_hypervisor "$HOST")
  if [[ "$HYPERVISOR" != "none" ]]; then
    VENDOR="$HYPERVISOR"
    DEVICE_TYPE="hypervisor"
    EARLY_EXIT=true
  fi

  # 2. SNMP (safe)
  if [[ "$EARLY_EXIT" != true ]]; then
    SNMP_VENDOR=$(detect_snmp_vendor "$HOST")
    if [[ "$SNMP_VENDOR" != "none" ]]; then
      VENDOR="$SNMP_VENDOR"
      DEVICE_TYPE=$(detect_device_type "$SNMP_VENDOR")
      IFS="|" read -r SNMP_DESCR SNMP_NAME SNMP_LOC <<< "$(snmp_enrich "$HOST")"
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

  cat >> "$INVENTORY_YAML" <<YAML
  - address: "$HOST"
    vendor: "$VENDOR"
    device_type: "$DEVICE_TYPE"
    hypervisor: "$HYPERVISOR"
    ssh_open: $SSH_OPEN
    rdp_3389_open: $RDP_OPEN
    http_open: $HTTP_OPEN
    https_open: $HTTPS_OPEN
    snmp_sysDescr: "$SNMP_DESCR"
    snmp_sysName: "$SNMP_NAME"
    snmp_sysLocation: "$SNMP_LOC"
YAML

done < "$TMP_HOSTS"

log "Phase 6 complete — inventory written to $INVENTORY_YAML"
log "Next step: map these into NetBox/LibreNMS as devices, VMs, or hypervisors."
EOF

chmod +x "$COMPUTE_DIR/discovery.sh"

phase_summary 6

# ------------------------------------------------------------
#  Phase 7: Ingestion / Dry Run
# ------------------------------------------------------------
mkdir -p "$INGEST_DIR"
cat > "$INGEST_DIR/ingest.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "[*] Placeholder: SNMP, SSH, API ingestion"
echo "[*] Implement dry-run discovery, validate devices before writing to NetBox/LibreNMS."
EOF
chmod +x "$INGEST_DIR/ingest.sh"

phase_summary 7

# ------------------------------------------------------------
#  Phase 8: Completeness / Promotion
# ------------------------------------------------------------
echo "[*] Phase 8: Validations / Completeness checks"
echo "[*] NetBox:     http://localhost:8080"
echo "[*] LibreNMS:   http://localhost:8000"
echo "[*] Oxidized:   http://localhost:8888"
echo "[*] Passive:    Zeek / Suricata / Ntopng (host mode)"
echo "[*] Compute:    $COMPUTE_DIR/discovery.sh"
echo "[*] Ingestion:  $INGEST_DIR/ingest.sh"

phase_summary 8

echo "[*] Orchestrator v2.4 bootstrap complete!"
echo "[*] Base directory: $BASE_ROOT"
echo "[*] You can now run ingestion and compute discovery scripts as needed."
