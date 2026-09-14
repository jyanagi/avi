#!/usr/bin/env bash
# ============================================================================
# configure-keycloak.sh - runs ON the agent/demo host AFTER Keycloak is up.
# Creates the acme-ai realm, three tier clients (catalog/ops/finance), and a
# protocol mapper that stamps the mcp_tier claim into the access token.
# Uses the bundled kcadm.sh (no external calls).
# ============================================================================
set -euo pipefail
KC_HOME="${KC_HOME:-/opt/keycloak}"
KCADM="$KC_HOME/bin/kcadm.sh"
export JAVA_HOME="${JAVA_HOME:-/opt/keycloak-jre}"
export PATH="$JAVA_HOME/bin:$PATH"

: "${KC_ADMIN_USER:?}"; : "${KC_ADMIN_PASSWORD:?}"; : "${KC_REALM:?}"
: "${KC_HTTPS_PORT:?}"
: "${KC_CID_CATALOG:?}"; : "${KC_CID_OPS:?}"; : "${KC_CID_FINANCE:?}"
: "${KC_SECRET_CATALOG:?}"; : "${KC_SECRET_OPS:?}"; : "${KC_SECRET_FINANCE:?}"
: "${AUDIENCE_VALUE:?AUDIENCE_VALUE must be set (e.g. https://mcp.demo.lab); it must match the Avi VS JWT Audience field exactly}"

BASE="https://localhost:${KC_HTTPS_PORT}"
log(){ printf '[keycloak] %s\n' "$*"; }

log "Waiting for Keycloak to accept admin logins ..."
for i in $(seq 1 60); do
  if "$KCADM" config credentials --server "$BASE" --realm master \
        --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PASSWORD" \
        --truststore "$KC_HOME/conf/server.truststore" 2>/dev/null; then
    break
  fi
  # fall back to insecure for self-signed lab cert
  if "$KCADM" config truststore --trustpass changeit "$KC_HOME/conf/keycloak.jks" 2>/dev/null; then :; fi
  "$KCADM" config credentials --server "$BASE" --realm master \
        --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PASSWORD" 2>/dev/null && break || true
  sleep 3
  [[ "$i" == "60" ]] && { log "Keycloak did not become ready"; exit 1; }
done

create_realm(){
  if "$KCADM" get "realms/${KC_REALM}" >/dev/null 2>&1; then
    log "Realm ${KC_REALM} exists"
  else
    "$KCADM" create realms -s realm="${KC_REALM}" -s enabled=true \
      -s accessTokenLifespan=600
    log "Realm ${KC_REALM} created"
  fi
}

# create a confidential client with a service account and the mcp_tier claim
create_client(){
  local cid="$1" secret="$2" tier="$3"
  local existing
  existing="$("$KCADM" get clients -r "${KC_REALM}" -q clientId="$cid" --fields id --format csv --noquotes 2>/dev/null | tail -n +1 | head -1 || true)"
  if [[ -n "$existing" ]]; then
    log "Client $cid exists (id $existing)"
  else
    existing="$("$KCADM" create clients -r "${KC_REALM}" \
      -s clientId="$cid" -s enabled=true -s protocol=openid-connect \
      -s publicClient=false -s serviceAccountsEnabled=true \
      -s standardFlowEnabled=false -s directAccessGrantsEnabled=true \
      -s secret="$secret" -i)"
    log "Client $cid created (id $existing)"
  fi
  # add a hardcoded-claim mapper: mcp_tier=<tier> into the access token
  "$KCADM" create clients/"$existing"/protocol-mappers/models -r "${KC_REALM}" \
    -s name="mcp_tier-mapper" \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-hardcoded-claim-mapper \
    -s 'config."claim.name"=mcp_tier' \
    -s "config.\"claim.value\"=$tier" \
    -s 'config."jsonType.label"=String' \
    -s 'config."access.token.claim"=true' \
    -s 'config."id.token.claim"=false' \
    -s 'config."userinfo.token.claim"=false' 2>/dev/null \
    && log "  mapper mcp_tier=$tier added to $cid" \
    || log "  mapper already present on $cid"

  # add an audience mapper so the token 'aud' claim equals AUDIENCE_VALUE.
  # Avi's JWT/SSO Audience field must match this exactly, or every token 401s.
  "$KCADM" create clients/"$existing"/protocol-mappers/models -r "${KC_REALM}" \
    -s name="mcp-audience" \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s "config.\"included.custom.audience\"=${AUDIENCE_VALUE}" \
    -s 'config."access.token.claim"=true' \
    -s 'config."id.token.claim"=false' 2>/dev/null \
    && log "  audience mapper (${AUDIENCE_VALUE}) added to $cid" \
    || log "  audience mapper already present on $cid"
}

create_realm
create_client "$KC_CID_CATALOG" "$KC_SECRET_CATALOG" "catalog"
create_client "$KC_CID_OPS"     "$KC_SECRET_OPS"     "ops"
create_client "$KC_CID_FINANCE" "$KC_SECRET_FINANCE" "finance"

log "Keycloak realm ${KC_REALM} configured with three tier clients."
log "Issuer: ${BASE}/realms/${KC_REALM}"
log "JWKS:   ${BASE}/realms/${KC_REALM}/protocol/openid-connect/certs"
