#!/usr/bin/env bash
# ============================================================================
# install-mcp-node.sh - executed ON an MCP node by deploy.sh over SSH.
# Installs the vendored Node runtime, the MCP + inference services, the acme
# service user, systemd units, TLS material, and the agent failover public key
# with a scoped sudoers rule. Fully offline; all artifacts are pushed in.
#
# Expects, in the current directory when run:
#   node.tar.xz            (vendored Node runtime)
#   mcp-server.js, inference-stub.js
#   server.crt, server.key, ca.crt   (from config/certs)
#   failover.pub           (agent public key)
# Environment: BACKEND_USER BACKEND_DIR MCP_PORT LLM_PORT NODE_NAME
#              RESUME_SESSIONS
# ============================================================================
set -euo pipefail
: "${BACKEND_USER:=acme}"; : "${BACKEND_DIR:=/opt/acme-ai}"
: "${MCP_PORT:=8443}"; : "${LLM_PORT:=9443}"; : "${NODE_NAME:=mcp-node}"
: "${RESUME_SESSIONS:=1}"
log(){ printf '[mcp-node %s] %s\n' "$NODE_NAME" "$*"; }

# --- Node runtime ----------------------------------------------------------
log "Installing Node runtime"
sudo mkdir -p /opt/node
sudo tar -xJf node.tar.xz -C /opt/node --strip-components=1
echo 'export PATH=/opt/node/bin:$PATH' | sudo tee /etc/profile.d/node.sh >/dev/null
export PATH=/opt/node/bin:$PATH

# --- service user + dirs ---------------------------------------------------
if ! id "$BACKEND_USER" >/dev/null 2>&1; then
  sudo useradd --system --home "$BACKEND_DIR" --shell /usr/sbin/nologin "$BACKEND_USER"
  log "created service user $BACKEND_USER"
fi
sudo mkdir -p "$BACKEND_DIR/certs"
sudo cp mcp-server.js inference-stub.js "$BACKEND_DIR/"
sudo cp server.crt server.key ca.crt "$BACKEND_DIR/certs/"
sudo chown -R "$BACKEND_USER:$BACKEND_USER" "$BACKEND_DIR"
sudo chmod 640 "$BACKEND_DIR/certs/server.key"

# --- systemd units ---------------------------------------------------------
log "Writing systemd units"
sudo tee /etc/systemd/system/acme-mcp.service >/dev/null <<UNIT
[Unit]
Description=ACME MCP server (${NODE_NAME})
After=network-online.target
Wants=network-online.target
[Service]
User=${BACKEND_USER}
WorkingDirectory=${BACKEND_DIR}
Environment=NODE_NAME=${NODE_NAME}
Environment=MCP_PORT=${MCP_PORT}
Environment=TLS_CERT=${BACKEND_DIR}/certs/server.crt
Environment=TLS_KEY=${BACKEND_DIR}/certs/server.key
Environment=RESUME_SESSIONS=${RESUME_SESSIONS}
ExecStart=/opt/node/bin/node ${BACKEND_DIR}/mcp-server.js
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT

sudo tee /etc/systemd/system/acme-llm.service >/dev/null <<UNIT
[Unit]
Description=ACME inference stub (${NODE_NAME})
After=network-online.target
Wants=network-online.target
[Service]
User=${BACKEND_USER}
WorkingDirectory=${BACKEND_DIR}
Environment=NODE_NAME=${NODE_NAME}
Environment=LLM_PORT=${LLM_PORT}
Environment=TLS_CERT=${BACKEND_DIR}/certs/server.crt
Environment=TLS_KEY=${BACKEND_DIR}/certs/server.key
ExecStart=/opt/node/bin/node ${BACKEND_DIR}/inference-stub.js
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT

# --- agent failover SSH key + scoped sudoers -------------------------------
log "Installing agent failover public key + scoped sudoers"
sudo mkdir -p /home/ubuntu/.ssh 2>/dev/null || true
if [[ -f failover.pub ]]; then
  # allow the agent to log in as 'ubuntu' with this key only
  sudo bash -c "cat failover.pub >> /home/ubuntu/.ssh/authorized_keys"
  sudo chown -R ubuntu:ubuntu /home/ubuntu/.ssh 2>/dev/null || true
  sudo chmod 700 /home/ubuntu/.ssh; sudo chmod 600 /home/ubuntu/.ssh/authorized_keys
fi
# scoped sudoers: ubuntu may only control the acme-mcp unit, no password
sudo tee /etc/sudoers.d/waap-failover >/dev/null <<SUDO
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl stop acme-mcp, /usr/bin/systemctl start acme-mcp, /usr/bin/systemctl restart acme-mcp
SUDO
sudo chmod 440 /etc/sudoers.d/waap-failover

# --- enable + start --------------------------------------------------------
sudo systemctl daemon-reload
sudo systemctl enable --now acme-mcp.service acme-llm.service
sleep 2
sudo systemctl --no-pager --lines=3 status acme-mcp.service || true
log "MCP node install complete."
