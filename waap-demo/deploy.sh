#!/usr/bin/env bash
# ============================================================================
# deploy.sh - master orchestrator. Run this on the AIRGAPPED jump host after
# editing config/config.env and after bootstrap.sh has populated vendor/.
#
# Steps, in order:
#   0  preflight: verify vendor/ artifacts and required config
#   1  generate PKI (CA, server, client) and the failover SSH keypair
#   2  fill in any CHANGE_ME Keycloak secrets with random values
#   3  provision the three VMs in vSphere (govc)
#   4  install + start the MCP nodes (A and B)
#   5  install + start the agent host (Keycloak, dashboard, tools)
#   6  configure all Avi objects via REST
#   7  print verification summary
#
# Safe to re-run: each step is idempotent.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config/config.env"
V="$HERE/vendor"
SSHK="$HERE/config/ssh/waap-demo"
SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i $SSHK"

say(){ printf '\n========== %s ==========\n' "$*"; }
die(){ printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------
say "0. Preflight"
for f in govc "keycloak-"*.zip openjdk.tar.gz "node-"*.tar.xz wheels; do
  ls "$V"/$f >/dev/null 2>&1 || die "vendor/$f missing. Run bootstrap.sh on a connected machine first."
done
command -v openssl >/dev/null || die "openssl required on the jump host"
command -v ssh >/dev/null || die "ssh required on the jump host"
[[ "$AVI_PASSWORD" != "CHANGE_ME" ]] || die "Set AVI_PASSWORD in config/config.env"
[[ "$VSPHERE_PASSWORD" != "CHANGE_ME" ]] || die "Set VSPHERE_PASSWORD in config/config.env"
[[ "$KC_ADMIN_PASSWORD" != "CHANGE_ME" ]] || die "Set KC_ADMIN_PASSWORD in config/config.env"
echo "preflight OK"

# ---------------------------------------------------------------------------
# 1. PKI + SSH keypair
# ---------------------------------------------------------------------------
say "1. Generating PKI and SSH keypair"
bash "$HERE/scripts/gen-certs.sh"
bash "$HERE/scripts/gen-ssh.sh"

# ---------------------------------------------------------------------------
# 2. fill Keycloak secrets if left as CHANGE_ME
# ---------------------------------------------------------------------------
say "2. Resolving Keycloak client secrets"
rand(){ openssl rand -hex 16; }
for var in KC_SECRET_CATALOG KC_SECRET_OPS KC_SECRET_FINANCE; do
  if [[ "${!var}" == "CHANGE_ME" ]]; then
    val="$(rand)"; export "$var=$val"
    sed -i "s|^${var}=.*|${var}=\"${val}\"|" "$HERE/config/config.env"
    echo "generated $var"
  fi
done
source "$HERE/config/config.env"

# ---------------------------------------------------------------------------
# 3. provision VMs
# ---------------------------------------------------------------------------
say "3. Provisioning VMs in vSphere (govc)"
bash "$HERE/scripts/provision-vsphere.sh"

# helper: run a script on a remote host with a set of pushed files
push_and_run(){
  local ip="$1" runscript="$2"; shift 2
  local files=("$@")
  local tmp="waap-stage-$$"
  ssh $SSHOPT "${TEMPLATE_SSH_USER}@${ip}" "rm -rf ~/$tmp && mkdir -p ~/$tmp"
  scp $SSHOPT -q "${files[@]}" "${TEMPLATE_SSH_USER}@${ip}:~/$tmp/"
  ssh $SSHOPT "${TEMPLATE_SSH_USER}@${ip}" "cd ~/$tmp && bash $(basename "$runscript")"
}

CERTS="$HERE/config/certs"

# ---------------------------------------------------------------------------
# 4. MCP nodes
# ---------------------------------------------------------------------------
for pair in "$MCP_A_NAME:$MCP_A_IP" "$MCP_B_NAME:$MCP_B_IP"; do
  name="${pair%%:*}"; ip="${pair##*:}"
  say "4. Installing MCP node $name ($ip)"
  # per-node env is passed by writing a small env file into the stage dir
  envfile="$(mktemp)"
  cat > "$envfile" <<EOF
export BACKEND_USER="$BACKEND_USER"
export BACKEND_DIR="$BACKEND_DIR"
export MCP_PORT="$MCP_PORT"
export LLM_PORT="$LLM_PORT"
export NODE_NAME="$name"
export RESUME_SESSIONS="$RESUME_SESSIONS"
EOF
  # wrapper that sources env then runs the installer
  wrapper="$(mktemp)"
  cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
set -e
source ./node.env
bash ./install-mcp-node.sh
EOF
  cp "$envfile" "$HERE/backend/node.env"
  cp "$wrapper" "$HERE/backend/run.sh"
  push_and_run "$ip" "run.sh" \
    "$HERE/backend/run.sh" "$HERE/backend/node.env" \
    "$HERE/backend/install-mcp-node.sh" \
    "$HERE/backend/mcp-server.js" "$HERE/backend/inference-stub.js" \
    "$V"/node-*.tar.xz \
    "$CERTS/server.crt" "$CERTS/server.key" "$CERTS/ca.crt" \
    "$HERE/config/ssh/waap-demo.pub"
  # rename pushed files to the names the installer expects
  ssh $SSHOPT "${TEMPLATE_SSH_USER}@${ip}" \
    "cd ~/waap-stage-$$ 2>/dev/null || true"
  rm -f "$HERE/backend/node.env" "$HERE/backend/run.sh" "$envfile" "$wrapper"
done

# NOTE: the installer expects node.tar.xz and failover.pub names; normalize on host
for ip in "$MCP_A_IP" "$MCP_B_IP"; do
  ssh $SSHOPT "${TEMPLATE_SSH_USER}@${ip}" '
    d=$(ls -d ~/waap-stage-* 2>/dev/null | head -1);
    if [ -n "$d" ]; then cd "$d";
      ln -sf node-*.tar.xz node.tar.xz 2>/dev/null || true;
      ln -sf waap-demo.pub failover.pub 2>/dev/null || true;
    fi'
done

# ---------------------------------------------------------------------------
# 5. agent host (Keycloak + dashboard + tools)
# ---------------------------------------------------------------------------
say "5. Installing agent/demo host ($AGENT_IP)"
# write demo.env for the agent installer
DEMOENV="$HERE/agent/demo.env"
cat > "$DEMOENV" <<EOF
export DEMO_DIR="$DEMO_DIR"
export DASHBOARD_PORT="$DASHBOARD_PORT"
export KC_ADMIN_USER="$KC_ADMIN_USER"
export KC_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD"
export KC_REALM="$KC_REALM"
export KC_HTTPS_PORT="$KC_HTTPS_PORT"
export KC_CID_CATALOG="$KC_CID_CATALOG"
export KC_SECRET_CATALOG="$KC_SECRET_CATALOG"
export KC_CID_OPS="$KC_CID_OPS"
export KC_SECRET_OPS="$KC_SECRET_OPS"
export KC_CID_FINANCE="$KC_CID_FINANCE"
export KC_SECRET_FINANCE="$KC_SECRET_FINANCE"
export AVI_VIP="$AVI_VIP"
export AGENT_IP="$AGENT_IP"
export MCP_A_IP="$MCP_A_IP"
export MCP_B_IP="$MCP_B_IP"
export FAILOVER_WAIT="$FAILOVER_WAIT"
EOF

# stage everything the agent installer needs
AGENT_STAGE="$HERE/agent/_stage"
rm -rf "$AGENT_STAGE"; mkdir -p "$AGENT_STAGE/wheels" "$AGENT_STAGE/tools" "$AGENT_STAGE/dashboard" "$AGENT_STAGE/certs"
cp "$V"/openjdk.tar.gz "$AGENT_STAGE/"
cp "$V"/keycloak-*.zip "$AGENT_STAGE/"
cp "$V"/node-*.tar.xz "$AGENT_STAGE/node.tar.xz"
cp "$V"/wheels/*.whl "$AGENT_STAGE/wheels/"
cp "$HERE/agent/tools/"*.py "$AGENT_STAGE/tools/"
cp "$HERE/agent/dashboard/"* "$AGENT_STAGE/dashboard/"
cp "$CERTS/server.crt" "$CERTS/server.key" "$CERTS/client.crt" "$CERTS/client.key" "$CERTS/ca.crt" "$AGENT_STAGE/certs/"
cp "$HERE/config/ssh/waap-demo" "$AGENT_STAGE/failover"
cp "$HERE/keycloak/configure-keycloak.sh" "$AGENT_STAGE/keycloak-configure.sh"
cp "$HERE/agent/install-agent-host.sh" "$AGENT_STAGE/"
cp "$DEMOENV" "$AGENT_STAGE/demo.env"

ssh $SSHOPT "${TEMPLATE_SSH_USER}@${AGENT_IP}" "rm -rf ~/agent-stage && mkdir -p ~/agent-stage"
scp $SSHOPT -qr "$AGENT_STAGE/." "${TEMPLATE_SSH_USER}@${AGENT_IP}:~/agent-stage/"
ssh $SSHOPT "${TEMPLATE_SSH_USER}@${AGENT_IP}" "cd ~/agent-stage && bash install-agent-host.sh"
rm -rf "$AGENT_STAGE" "$DEMOENV"

# ---------------------------------------------------------------------------
# 6. Avi configuration (from the jump host, talking to the controller)
# ---------------------------------------------------------------------------
say "6. Configuring Avi objects via REST"
# use a local venv on the jump host from vendored wheels for requests
JUMPVENV="$HERE/.jumpvenv"
if [[ ! -d "$JUMPVENV" ]]; then
  python3 -m venv "$JUMPVENV"
  "$JUMPVENV/bin/pip" install --no-index --find-links "$V/wheels" requests cryptography PyJWT >/dev/null
fi
AVI_CONTROLLER="$AVI_CONTROLLER" AVI_USER="$AVI_USER" AVI_PASSWORD="$AVI_PASSWORD" \
AVI_TENANT="$AVI_TENANT" AVI_CLOUD="$AVI_CLOUD" AVI_SE_GROUP="$AVI_SE_GROUP" \
AVI_VS_NETWORK="$AVI_VS_NETWORK" AVI_VIP="$AVI_VIP" AVI_VERSION="$AVI_VERSION" \
CERT_NAME="$CERT_NAME" PKI_PROFILE="$PKI_PROFILE" JWT_PROFILE="$JWT_PROFILE" \
AUTH_PROFILE="$AUTH_PROFILE" SSO_POLICY="$SSO_POLICY" WAF_PROFILE="$WAF_PROFILE" \
WAF_POLICY="$WAF_POLICY" APP_PROFILE="$APP_PROFILE" HEALTH_MONITOR="$HEALTH_MONITOR" \
POOL_NAME="$POOL_NAME" VS_NAME="$VS_NAME" MCP_A_IP="$MCP_A_IP" MCP_B_IP="$MCP_B_IP" \
MCP_PORT="$MCP_PORT" KC_REALM="$KC_REALM" AGENT_IP="$AGENT_IP" KC_HTTPS_PORT="$KC_HTTPS_PORT" \
CERT_DIR="$CERTS" DATASCRIPT_PATH="$HERE/avi/mcp-failover.lua" \
  "$JUMPVENV/bin/python" "$HERE/avi/configure-avi.py"

# ---------------------------------------------------------------------------
# 7. summary
# ---------------------------------------------------------------------------
say "7. Deployment complete"
cat <<EOF

  Dashboard:     https://${AGENT_IP}:${DASHBOARD_PORT}/
  Keycloak:      https://${AGENT_IP}:${KC_HTTPS_PORT}/  (realm ${KC_REALM})
  MCP Virtual Service (Avi VIP):  https://${AVI_VIP}/
  MCP nodes:     ${MCP_A_IP} (A), ${MCP_B_IP} (B)

  Verify:
    curl -k https://${AVI_VIP}/.well-known/oauth-protected-resource
    Open the dashboard and click through stages 1..5.

  Teardown when finished:  ./teardown.sh
EOF
