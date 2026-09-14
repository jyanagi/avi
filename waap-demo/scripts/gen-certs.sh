#!/usr/bin/env bash
# ============================================================================
# gen-certs.sh - generate the demo PKI entirely offline with openssl.
# Produces: a self-signed root CA, a server cert (with SANs for mcp/waap/agent),
# and a client cert (for agent mTLS). No external CA is contacted.
# Output goes to config/certs/ and is consumed by the Avi and backend steps.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/config/config.env"
OUT="$HERE/config/certs"
mkdir -p "$OUT"
cd "$OUT"

log(){ printf '[certs] %s\n' "$*"; }

if [[ -f ca.crt && -f server.crt && -f client.crt ]]; then
  log "Certs already exist in $OUT (delete them to regenerate). Skipping."
  exit 0
fi

# --- Root CA ---------------------------------------------------------------
log "Generating root CA: ${CA_CN}"
openssl genrsa -out ca.key 4096 2>/dev/null
openssl req -x509 -new -nodes -key ca.key -sha256 -days "$CERT_DAYS" \
  -subj "/CN=${CA_CN}/O=ACME Demo/C=US" -out ca.crt 2>/dev/null

# --- Server cert (mTLS server side + VS cert) ------------------------------
log "Generating server cert: ${SERVER_CN} (+ SANs)"
cat > server.cnf <<EOF
[req]
distinguished_name = dn
req_extensions = ext
prompt = no
[dn]
CN = ${SERVER_CN}
O = ACME Demo
C = US
[ext]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
[alt]
DNS.1 = ${SERVER_CN}
DNS.2 = waap.${NET_DOMAIN}
DNS.3 = agent.${NET_DOMAIN}
IP.1  = ${AVI_VIP}
EOF
openssl genrsa -out server.key 2048 2>/dev/null
openssl req -new -key server.key -out server.csr -config server.cnf 2>/dev/null
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days "$CERT_DAYS" -sha256 \
  -extensions ext -extfile server.cnf 2>/dev/null

# --- Client cert (agent mTLS) ----------------------------------------------
log "Generating client cert: ${CLIENT_CN}"
cat > client.cnf <<EOF
[req]
distinguished_name = dn
req_extensions = ext
prompt = no
[dn]
CN = ${CLIENT_CN}
O = ACME Demo
C = US
[ext]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
subjectAltName = @alt
[alt]
DNS.1 = ${CLIENT_CN}
DNS.2 = api.${NET_DOMAIN}
EOF
openssl genrsa -out client.key 2048 2>/dev/null
openssl req -new -key client.key -out client.csr -config client.cnf 2>/dev/null
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days "$CERT_DAYS" -sha256 \
  -extensions ext -extfile client.cnf 2>/dev/null

# full chain for convenience
cat server.crt ca.crt > server-fullchain.crt
rm -f server.csr client.csr server.cnf client.cnf

log "PKI generated in $OUT:"
ls -1 "$OUT"
