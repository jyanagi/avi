#!/usr/bin/env bash
#
# install-vuln-node.sh  —  run on BOTH web-a-03a and web-a-03b.
#
# Stands up one vulnerable Log4Shell node:
#   - Docker container with Spring Boot + Log4j 2.14.1, bound to 127.0.0.1:8081
#   - a zero-dependency Node front proxy on :8080 (the Avi pool-member port)
#     that adds X-Served-By and health-checks the container
#   - DOCKER-USER egress rules so the container can reach only the lab subnet
#
# Idempotent: safe to re-run. Must be run as root from the package directory.
#
set -euo pipefail

LAB_SUBNET="${LAB_SUBNET:-10.15.148.0/24}"
VULN_IMAGE="${VULN_IMAGE:-ghcr.io/christophetd/log4shell-vulnerable-app}"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="/opt/log4shell-demo"

if [[ $EUID -ne 0 ]]; then echo "run as root"; exit 1; fi

echo "==> [1/6] base packages (docker, node)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io nodejs
systemctl enable --now docker

echo "==> [2/6] deploy program files to ${APP_DIR}"
mkdir -p "$APP_DIR"
install -m 0644 "$SRC_DIR/node/node-proxy.js" "$APP_DIR/node-proxy.js"
install -m 0644 "$SRC_DIR/install/log4shell-demo.env" /etc/log4shell-demo.env

echo "==> [3/6] run the vulnerable container on 127.0.0.1:8081"
docker rm -f vuln-app >/dev/null 2>&1 || true
docker pull "$VULN_IMAGE"
docker run -d --name vuln-app --restart unless-stopped \
  -p 127.0.0.1:8081:8080 "$VULN_IMAGE"

echo "==> [4/6] install + start the front proxy service on :8080"
install -m 0644 "$SRC_DIR/systemd/log4shell-proxy.service" \
  /etc/systemd/system/log4shell-proxy.service
systemctl daemon-reload
systemctl enable --now log4shell-proxy.service

echo "==> [5/6] egress containment (DOCKER-USER: lab subnet only)"
# Allow return traffic and same-subnet (canary + intra-lab), drop the rest.
iptables -D DOCKER-USER -d "$LAB_SUBNET" -j RETURN 2>/dev/null || true
iptables -D DOCKER-USER -m state --state ESTABLISHED,RELATED -j RETURN 2>/dev/null || true
iptables -D DOCKER-USER -j DROP 2>/dev/null || true
iptables -I DOCKER-USER -d "$LAB_SUBNET" -j RETURN
iptables -I DOCKER-USER -m state --state ESTABLISHED,RELATED -j RETURN
iptables -A DOCKER-USER -j DROP
apt-get install -y iptables-persistent >/dev/null 2>&1 || true
netfilter-persistent save >/dev/null 2>&1 || true

echo "==> [6/6] verify"
sleep 2
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/healthz || true)
echo "    proxy /healthz -> ${code} (200 = container reachable)"
echo "    egress test (should FAIL/hang): "
docker exec vuln-app sh -c 'timeout 3 curl -s -o /dev/null -w "%{http_code}" https://example.com' \
  2>/dev/null && echo "    WARNING: container reached the internet — check DOCKER-USER" \
  || echo "    container internet egress blocked (good)"

echo "==> done on $(hostname). Pool member: http://$(hostname -I | awk '{print $1}'):8080"
