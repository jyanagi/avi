#!/usr/bin/env bash
#
# install-control-plane.sh  —  run on web-a-03a ONLY (after install-vuln-node.sh).
#
# Adds the demo control plane to 03a:
#   - JNDI canary listener on :1389 (observe-only; serves no payload)
#   - operator console + fire API on :9090
#
# The vulnerable node stays reachable through the Avi VS on :8080; the console
# is reached directly on :9090 and is NOT placed behind the WAF.
#
# Idempotent. Run as root from the package directory.
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="/opt/log4shell-demo"
STATE_DIR="/var/lib/log4shell-demo"

if [[ $EUID -ne 0 ]]; then echo "run as root"; exit 1; fi

echo "==> [1/5] base packages (node, python3, curl)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nodejs python3 curl

echo "==> [2/5] deploy control-plane program files"
mkdir -p "$APP_DIR" "$STATE_DIR"
install -m 0644 "$SRC_DIR/control-plane/console-server.js" "$APP_DIR/console-server.js"
install -m 0644 "$SRC_DIR/control-plane/canary-listener.py" "$APP_DIR/canary-listener.py"
mkdir -p "$APP_DIR/fonts"
if ls "$SRC_DIR/control-plane/fonts/"*.woff2 >/dev/null 2>&1; then
  install -m 0644 "$SRC_DIR/control-plane/fonts/"*.woff2 "$APP_DIR/fonts/"
fi
# Only install the env file if the node installer has not already placed it.
[[ -f /etc/log4shell-demo.env ]] || install -m 0644 \
  "$SRC_DIR/install/log4shell-demo.env" /etc/log4shell-demo.env
: > "$STATE_DIR/callbacks.jsonl" || true

echo "==> [3/5] install systemd units"
install -m 0644 "$SRC_DIR/systemd/log4shell-canary.service" \
  /etc/systemd/system/log4shell-canary.service
install -m 0644 "$SRC_DIR/systemd/log4shell-console.service" \
  /etc/systemd/system/log4shell-console.service
systemctl daemon-reload

echo "==> [4/5] start canary + console"
systemctl enable --now log4shell-canary.service
systemctl enable --now log4shell-console.service

echo "==> [5/5] verify"
sleep 2
ss -ltnp 2>/dev/null | grep -E ':1389|:9090' || true
port=$(grep -E '^CONSOLE_PORT=' /etc/log4shell-demo.env | cut -d= -f2)
ip=$(hostname -I | awk '{print $1}')
echo "==> console up at:  http://${ip}:${port:-9090}"
echo "==> canary sink:    $(grep -E '^CANARY_SINK=' /etc/log4shell-demo.env | cut -d= -f2)"
