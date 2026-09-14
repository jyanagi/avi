#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh - ONE-TIME stager. Run this on an internet-connected machine.
# It downloads every external artifact into vendor/ so that deploy.sh can run
# later in a fully airgapped environment with no outbound network access.
#
# After this completes, copy the ENTIRE kit directory (including vendor/) to
# your airgapped jump host or removable media.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/vendor"
mkdir -p "$V"

log(){ printf '\n[bootstrap] %s\n' "$*"; }

# Pinned versions. Bump deliberately; airgap reproducibility depends on pins.
GOVC_VERSION="0.37.3"
KEYCLOAK_VERSION="26.0.5"
NODE_VERSION="20.18.1"          # LTS; carries the MCP + inference runtimes
JRE_TARBALL_URL="https://download.java.net/java/GA/jdk21.0.2/f2283984656d49d69e91c558476027ac/13/GPL/openjdk-21.0.2_linux-x64_bin.tar.gz"

# ---------------------------------------------------------------------------
# 1. govc (single static binary for vSphere automation)
# ---------------------------------------------------------------------------
log "Fetching govc ${GOVC_VERSION}"
curl -fsSL -o "$V/govc.tar.gz" \
  "https://github.com/vmware/govmomi/releases/download/v${GOVC_VERSION}/govc_Linux_x86_64.tar.gz"
tar -xzf "$V/govc.tar.gz" -C "$V" govc && chmod +x "$V/govc" && rm -f "$V/govc.tar.gz"

# ---------------------------------------------------------------------------
# 2. Keycloak distribution zip (runs under a JRE as a systemd service)
# ---------------------------------------------------------------------------
log "Fetching Keycloak ${KEYCLOAK_VERSION}"
curl -fsSL -o "$V/keycloak-${KEYCLOAK_VERSION}.zip" \
  "https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.zip"

# ---------------------------------------------------------------------------
# 3. OpenJDK JRE (so no Java dependency is assumed on the demo host)
# ---------------------------------------------------------------------------
log "Fetching OpenJDK runtime for Keycloak"
curl -fsSL -o "$V/openjdk.tar.gz" "$JRE_TARBALL_URL"

# ---------------------------------------------------------------------------
# 4. Node.js runtime (for MCP + inference backends on the MCP nodes)
# ---------------------------------------------------------------------------
log "Fetching Node.js ${NODE_VERSION}"
curl -fsSL -o "$V/node-${NODE_VERSION}.tar.xz" \
  "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"

# ---------------------------------------------------------------------------
# 5. Python wheels for the dashboard + deploy tooling (offline pip install)
# ---------------------------------------------------------------------------
log "Vendoring Python wheels (fastapi, uvicorn, requests, pyjwt, cryptography)"
mkdir -p "$V/wheels"
python3 -m pip download --dest "$V/wheels" \
  "fastapi==0.115.5" "uvicorn[standard]==0.32.1" "requests==2.32.3" \
  "PyJWT==2.10.1" "cryptography==43.0.3" "python-multipart==0.0.17" \
  >/dev/null

# ---------------------------------------------------------------------------
# 6. ffmpeg static build (for the optional screen recorder)
# ---------------------------------------------------------------------------
log "Fetching ffmpeg static build (optional recorder)"
curl -fsSL -o "$V/ffmpeg.tar.xz" \
  "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" || \
  log "WARN: ffmpeg fetch failed; record-demo.sh will require a system ffmpeg."

# ---------------------------------------------------------------------------
# manifest
# ---------------------------------------------------------------------------
cat > "$V/MANIFEST.txt" <<EOF
Vendored $(date -u +%Y-%m-%dT%H:%M:%SZ)
govc              ${GOVC_VERSION}
keycloak          ${KEYCLOAK_VERSION}
openjdk (jre)     21.0.2
node              ${NODE_VERSION}
python wheels     fastapi 0.115.5, uvicorn 0.32.1, requests 2.32.3, PyJWT 2.10.1, cryptography 43.0.3
ffmpeg            release-amd64-static
EOF

log "Done. vendor/ is populated:"
ls -lh "$V"
log "Now copy the ENTIRE kit directory to your airgapped host and run scripts/deploy.sh"
