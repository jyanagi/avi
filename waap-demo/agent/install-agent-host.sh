#!/usr/bin/env bash
# ============================================================================
# install-agent-host.sh - executed ON the agent/demo host by deploy.sh over SSH.
# Installs: vendored JRE + Keycloak (systemd), Python venv from vendored wheels,
# the demo tools (agent.py/attack.py), the dashboard service, TLS material, and
# the agent's private failover SSH key. Fully offline.
#
# Expects in the current directory when run:
#   openjdk.tar.gz keycloak-*.zip node.tar.xz
#   wheels/ (dir of .whl)  tools/ dashboard/  certs (server.* client.* ca.crt)
#   failover (private key)  keycloak-configure.sh  demo.env
# Environment is sourced from demo.env (written by deploy.sh from config.env).
# ============================================================================
set -euo pipefail
source ./demo.env
log(){ printf '[agent-host] %s\n' "$*"; }

DEMO_DIR="${DEMO_DIR:-/opt/waap-demo}"
KC_HOME="/opt/keycloak"
JRE_HOME="/opt/keycloak-jre"

# --- JRE -------------------------------------------------------------------
log "Installing JRE for Keycloak"
sudo mkdir -p "$JRE_HOME"
sudo tar -xzf openjdk.tar.gz -C "$JRE_HOME" --strip-components=1
export JAVA_HOME="$JRE_HOME"; export PATH="$JAVA_HOME/bin:$PATH"

# --- Node (agent may run local helpers) + Python venv from wheels ----------
log "Installing Node runtime"
sudo mkdir -p /opt/node && sudo tar -xJf node.tar.xz -C /opt/node --strip-components=1
echo 'export PATH=/opt/node/bin:/opt/keycloak-jre/bin:$PATH' | sudo tee /etc/profile.d/demo.sh >/dev/null

log "Creating Python venv from vendored wheels (offline)"
python3 -m venv "$DEMO_DIR/venv" 2>/dev/null || { sudo mkdir -p "$DEMO_DIR"; sudo chown "$(id -u):$(id -g)" "$DEMO_DIR"; python3 -m venv "$DEMO_DIR/venv"; }
"$DEMO_DIR/venv/bin/pip" install --no-index --find-links ./wheels \
  fastapi uvicorn requests PyJWT cryptography python-multipart >/dev/null
log "Python deps installed offline"

# --- Keycloak --------------------------------------------------------------
log "Installing Keycloak"
sudo rm -rf "$KC_HOME"; sudo mkdir -p "$KC_HOME"
sudo unzip -q keycloak-*.zip -d /opt
sudo bash -c "mv /opt/keycloak-*/* $KC_HOME/ 2>/dev/null || true"
sudo bash -c "shopt -s nullglob; rmdir /opt/keycloak-* 2>/dev/null || true"

# TLS for Keycloak (reuse demo server cert)
sudo mkdir -p "$KC_HOME/conf"
sudo cp certs/server.crt "$KC_HOME/conf/server.crt.pem"
sudo cp certs/server.key "$KC_HOME/conf/server.key.pem"

sudo tee "$KC_HOME/conf/keycloak.conf" >/dev/null <<CONF
https-certificate-file=${KC_HOME}/conf/server.crt.pem
https-certificate-key-file=${KC_HOME}/conf/server.key.pem
https-port=${KC_HTTPS_PORT}
hostname-strict=false
health-enabled=true
CONF

# systemd unit for Keycloak (dev mode is fine for a demo; start with --optimized off)
sudo tee /etc/systemd/system/keycloak.service >/dev/null <<UNIT
[Unit]
Description=Keycloak (demo)
After=network-online.target
Wants=network-online.target
[Service]
Environment=JAVA_HOME=${JRE_HOME}
Environment=KEYCLOAK_ADMIN=${KC_ADMIN_USER}
Environment=KEYCLOAK_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD}
Environment=KC_BOOTSTRAP_ADMIN_USERNAME=${KC_ADMIN_USER}
Environment=KC_BOOTSTRAP_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD}
WorkingDirectory=${KC_HOME}
ExecStart=${KC_HOME}/bin/kc.sh start-dev --https-port=${KC_HTTPS_PORT} --https-certificate-file=${KC_HOME}/conf/server.crt.pem --https-certificate-key-file=${KC_HOME}/conf/server.key.pem --hostname-strict=false
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now keycloak.service
log "Keycloak starting; configuring realm ..."

# configure realm/clients/mappers (script waits for readiness)
export KC_HOME JAVA_HOME
KC_ADMIN_USER="$KC_ADMIN_USER" KC_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD" \
KC_REALM="$KC_REALM" KC_HTTPS_PORT="$KC_HTTPS_PORT" \
KC_CID_CATALOG="$KC_CID_CATALOG" KC_SECRET_CATALOG="$KC_SECRET_CATALOG" \
KC_CID_OPS="$KC_CID_OPS" KC_SECRET_OPS="$KC_SECRET_OPS" \
KC_CID_FINANCE="$KC_CID_FINANCE" KC_SECRET_FINANCE="$KC_SECRET_FINANCE" \
  bash ./keycloak-configure.sh

# --- demo tools + dashboard ------------------------------------------------
log "Installing demo tools and dashboard"
sudo mkdir -p "$DEMO_DIR/tools" "$DEMO_DIR/dashboard" "$DEMO_DIR/certs" "$DEMO_DIR/.ssh"
sudo cp tools/agent.py tools/attack.py "$DEMO_DIR/tools/"
sudo cp dashboard/waap_demo_server.py dashboard/dashboard.html dashboard/clr-ui.min.css "$DEMO_DIR/dashboard/"
sudo cp certs/client.crt certs/client.key certs/ca.crt certs/server.crt certs/server.key "$DEMO_DIR/certs/"
sudo cp failover "$DEMO_DIR/.ssh/waap-demo"
sudo chmod 600 "$DEMO_DIR/.ssh/waap-demo" "$DEMO_DIR/certs/client.key" "$DEMO_DIR/certs/server.key"

# dashboard service (bound to its own cert, direct uvicorn, not behind Avi)
sudo tee /etc/systemd/system/waap-demo.service >/dev/null <<UNIT
[Unit]
Description=WAAP demo dashboard
After=network-online.target keycloak.service
Wants=network-online.target
[Service]
WorkingDirectory=${DEMO_DIR}/dashboard
Environment=DEMO_TOOLS_DIR=${DEMO_DIR}/tools
Environment=AVI_MCP=https://${AVI_VIP}
Environment=KC=https://${AGENT_IP}:${KC_HTTPS_PORT}
Environment=KC_REALM=${KC_REALM}
Environment=SECRET_CATALOG=${KC_SECRET_CATALOG}
Environment=SECRET_OPS=${KC_SECRET_OPS}
Environment=SECRET_FINANCE=${KC_SECRET_FINANCE}
Environment=CID_CATALOG=${KC_CID_CATALOG}
Environment=CID_OPS=${KC_CID_OPS}
Environment=CID_FINANCE=${KC_CID_FINANCE}
Environment=CLIENT_CERT=${DEMO_DIR}/certs/client.crt
Environment=CLIENT_KEY=${DEMO_DIR}/certs/client.key
Environment=MCP_A_IP=${MCP_A_IP}
Environment=MCP_B_IP=${MCP_B_IP}
Environment=FAILOVER_WAIT=${FAILOVER_WAIT}
Environment=DEMO_TLS_CERT=${DEMO_DIR}/certs/server.crt
Environment=DEMO_TLS_KEY=${DEMO_DIR}/certs/server.key
ExecStart=${DEMO_DIR}/venv/bin/python ${DEMO_DIR}/dashboard/waap_demo_server.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT

sudo chown -R root:root "$DEMO_DIR"
sudo systemctl daemon-reload
sudo systemctl enable --now waap-demo.service
sleep 2
sudo systemctl --no-pager --lines=3 status waap-demo.service || true
log "Agent host install complete. Dashboard on port ${DASHBOARD_PORT}."
