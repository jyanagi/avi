#!/usr/bin/env bash
# ============================================================================
# provision-vsphere.sh - clone the base Ubuntu template into the three demo
# VMs (mcp-a, mcp-b, agent) using the vendored govc binary, and inject static
# network config + SSH access via cloud-init guestinfo. Fully offline.
#
# Requires: vendor/govc, config/config.env, and a base template that has
# cloud-init + open-vm-tools installed.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/config/config.env"
GOVC="$HERE/vendor/govc"
[[ -x "$GOVC" ]] || { echo "FATAL: vendor/govc missing. Run bootstrap.sh first."; exit 1; }

export GOVC_URL="$VSPHERE_SERVER"
export GOVC_USERNAME="$VSPHERE_USER"
export GOVC_PASSWORD="$VSPHERE_PASSWORD"
export GOVC_INSECURE="$VSPHERE_INSECURE"
export GOVC_DATACENTER="$VSPHERE_DATACENTER"
export GOVC_DATASTORE="$VSPHERE_DATASTORE"
export GOVC_NETWORK="$VSPHERE_NETWORK"
export GOVC_RESOURCE_POOL="${VSPHERE_RESOURCE_POOL:-/$VSPHERE_DATACENTER/host/$VSPHERE_CLUSTER/Resources}"

log(){ printf '[vsphere] %s\n' "$*"; }

# read the agent SSH public key we will inject for first-boot access
PUBKEY="$(cat "$HERE/config/ssh/waap-demo.pub")"

# build a cloud-init user-data + metadata per host, base64 for guestinfo
mk_cloudinit(){
  local name="$1" ip="$2"
  local ud md
  ud="$(mktemp)"; md="$(mktemp)"
  cat > "$ud" <<CI
#cloud-config
hostname: ${name}
fqdn: ${name}.${NET_DOMAIN}
users:
  - name: ${TEMPLATE_SSH_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${PUBKEY}
ssh_pwauth: false
CI
  cat > "$md" <<MD
instance-id: ${name}
local-hostname: ${name}
network:
  version: 2
  ethernets:
    ens192:
      dhcp4: false
      addresses: [${ip}/${NET_NETMASK}]
      gateway4: ${NET_GATEWAY}
      nameservers:
        addresses: [${NET_DNS}]
        search: [${NET_DOMAIN}]
MD
  echo "$(base64 -w0 "$ud")|$(base64 -w0 "$md")"
  rm -f "$ud" "$md"
}

clone_vm(){
  local name="$1" ip="$2"
  if "$GOVC" vm.info "$name" >/dev/null 2>&1; then
    log "VM $name already exists, skipping clone"
  else
    log "Cloning $VSPHERE_TEMPLATE -> $name"
    "$GOVC" vm.clone -vm "$VSPHERE_TEMPLATE" -on=false \
      -folder "$VSPHERE_FOLDER" -ds "$VSPHERE_DATASTORE" \
      -net "$VSPHERE_NETWORK" "$name" >/dev/null
  fi
  # inject cloud-init via guestinfo
  local ci; ci="$(mk_cloudinit "$name" "$ip")"
  local ud="${ci%%|*}"; local md="${ci##*|}"
  "$GOVC" vm.change -vm "$name" \
    -e guestinfo.userdata="$ud" \
    -e guestinfo.userdata.encoding="base64" \
    -e guestinfo.metadata="$md" \
    -e guestinfo.metadata.encoding="base64" >/dev/null
  "$GOVC" vm.power -on "$name" >/dev/null 2>&1 || true
  log "$name powered on with static IP $ip"
}

# ensure folder exists
"$GOVC" folder.create "/$VSPHERE_DATACENTER/vm/$VSPHERE_FOLDER" 2>/dev/null || true

clone_vm "$MCP_A_NAME" "$MCP_A_IP"
clone_vm "$MCP_B_NAME" "$MCP_B_IP"
clone_vm "$AGENT_NAME" "$AGENT_IP"

log "Waiting for VMs to obtain their static IPs and SSH to come up ..."
for host in "$MCP_A_IP" "$MCP_B_IP" "$AGENT_IP"; do
  for i in $(seq 1 60); do
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
         -o ConnectTimeout=4 -i "$HERE/config/ssh/waap-demo" \
         "${TEMPLATE_SSH_USER}@${host}" true 2>/dev/null; then
      log "SSH up on $host"; break
    fi
    sleep 5
    [[ "$i" == "60" ]] && log "WARN: SSH not reachable on $host after timeout"
  done
done
log "vSphere provisioning complete."
