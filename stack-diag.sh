#!/usr/bin/env bash
# ====================================================
# Full Stack Diagnostic Script — NetBox / LibreNMS / Passive / Compute
# Safe, Read-Only, for v2.0 deployment
# ====================================================

set -euo pipefail

echo "=============================="
echo " Full Stack Diagnostic"
echo "=============================="
echo

# -------------------------------
# Basic Host Check
# -------------------------------
echo "[*] Host info"
uname -a
echo

echo "[*] Docker status"
systemctl is-active --quiet docker && echo "Docker: running" || echo "Docker: NOT running"
docker version || true
docker info || true
echo

# -------------------------------
# Docker Containers Overview
# -------------------------------
echo "[*] Containers"
docker ps -a
echo

# -------------------------------
# Docker Networks
# -------------------------------
echo "[*] Docker Networks"
docker network ls
echo

# -------------------------------
# LibreNMS Health
# -------------------------------
echo "[*] LibreNMS containers"
docker ps --filter "name=librenms"
echo "[*] LibreNMS DB test"
docker exec librenms-db mysql -uroot -prootpassword -e "SELECT 1;" || echo "❌ LibreNMS MariaDB not reachable"
echo "[*] LibreNMS Redis test"
docker exec librenms-redis redis-cli ping || echo "❌ LibreNMS Redis not reachable"
echo "[*] LibreNMS Web logs (last 20 lines)"
docker logs --tail 20 librenms || echo "No librenms container"
echo

# -------------------------------
# NetBox Health
# -------------------------------
echo "[*] NetBox containers"
docker ps --filter "name=netbox"
NETBOX_CID=$(docker ps --format '{{.ID}} {{.Names}}' | grep -i netbox | awk '{print $1}' || true)
if [[ -n "$NETBOX_CID" ]]; then
  echo "[*] Resolving DB and Redis inside NetBox"
  docker exec "$NETBOX_CID" getent hosts netbox-db || echo "❌ Cannot resolve netbox-db"
  docker exec "$NETBOX_CID" getent hosts netbox-redis || echo "❌ Cannot resolve netbox-redis"

  echo "[*] Test DB connectivity"
  docker exec "$NETBOX_CID" python3 - <<'EOF' || true
from django.db import connections
try:
    connections['default'].cursor()
    print("DB connection: OK")
except Exception as e:
    print("DB connection: FAIL")
    print(e)
EOF

  echo "[*] Test Redis connectivity"
  docker exec "$NETBOX_CID" python3 - <<'EOF' || true
from django.core.cache import cache
try:
    cache.set("diag","ok",5)
    print("Redis cache:", cache.get("diag"))
except Exception as e:
    print("Redis cache: FAIL")
    print(e)
EOF
else
  echo "❌ NetBox container not running"
fi
echo

# -------------------------------
# Passive Traffic Stack
# -------------------------------
for svc in zeek suricata ntopng; do
  echo "[*] Checking $svc container"
  docker ps --filter "name=$svc"
  docker logs --tail 20 "$svc" 2>/dev/null || echo "No $svc container or logs unavailable"
done

# -------------------------------
# Docker Capabilities
# -------------------------------
echo "[*] Zeek/Suricata capabilities"
docker inspect zeek --format '{{.HostConfig.CapAdd}}' 2>/dev/null || echo "Zeek inspect failed"
docker inspect suricata --format '{{.HostConfig.CapAdd}}' 2>/dev/null || echo "Suricata inspect failed"
echo

# -------------------------------
# Interfaces visible to Docker
# -------------------------------
echo "[*] Host Interfaces"
ip link show
echo

# -------------------------------
# Compute Discovery Scripts
# -------------------------------
echo "[*] Compute discovery script status"
[[ -f /opt/netbox-docker/compute/discovery.sh ]] && ls -l /opt/netbox-docker/compute/discovery.sh
echo

# -------------------------------
# Ingestion / Dry-Run Scripts
# -------------------------------
echo "[*] Ingestion script status"
[[ -f /opt/netbox-docker/ingestion/ingest.sh ]] && ls -l /opt/netbox-docker/ingestion/ingest.sh
echo

echo "=============================="
echo " Diagnostic complete"
echo "=============================="
