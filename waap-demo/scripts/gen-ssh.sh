#!/usr/bin/env bash
# ============================================================================
# gen-ssh.sh - generate the SSH keypair the agent host uses to stop/start the
# MCP service on the MCP nodes during the failover scene. Public key is later
# installed on both MCP nodes with a scoped, no-passphrase authorized_keys entry
# and a narrow sudoers rule (systemctl on acme-mcp only).
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$HERE/config/ssh"
mkdir -p "$OUT"
log(){ printf '[ssh] %s\n' "$*"; }

if [[ -f "$OUT/waap-demo" ]]; then
  log "SSH key already exists in $OUT (delete to regenerate). Skipping."
  exit 0
fi

log "Generating ed25519 keypair for agent -> MCP failover control"
ssh-keygen -t ed25519 -N "" -C "waap-demo-failover" -f "$OUT/waap-demo" >/dev/null
chmod 600 "$OUT/waap-demo"
log "Keypair generated:"
ls -1 "$OUT"
