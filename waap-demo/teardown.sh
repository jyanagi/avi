#!/usr/bin/env bash
# ============================================================================
# teardown.sh - remove everything the kit created: Avi objects (in reverse
# dependency order) and the three demo VMs. Leaves the controller, cloud, and
# template untouched. Run on the airgapped jump host.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config/config.env"
V="$HERE/vendor"
GOVC="$V/govc"
say(){ printf '\n========== %s ==========\n' "$*"; }

read -r -p "This will DELETE the demo VMs and all Avi demo objects. Type 'yes' to proceed: " ok
[[ "$ok" == "yes" ]] || { echo "aborted"; exit 0; }

# ---------------------------------------------------------------------------
# Avi objects, reverse order
# ---------------------------------------------------------------------------
say "Removing Avi objects"
JUMPVENV="$HERE/.jumpvenv"
[[ -d "$JUMPVENV" ]] || { python3 -m venv "$JUMPVENV"; "$JUMPVENV/bin/pip" install --no-index --find-links "$V/wheels" requests >/dev/null; }

AVI_CONTROLLER="$AVI_CONTROLLER" AVI_USER="$AVI_USER" AVI_PASSWORD="$AVI_PASSWORD" \
AVI_TENANT="$AVI_TENANT" AVI_VERSION="$AVI_VERSION" \
VS_NAME="$VS_NAME" POOL_NAME="$POOL_NAME" WAF_POLICY="$WAF_POLICY" \
WAF_PROFILE="$WAF_PROFILE" SSO_POLICY="$SSO_POLICY" AUTH_PROFILE="$AUTH_PROFILE" \
JWT_PROFILE="$JWT_PROFILE" PKI_PROFILE="$PKI_PROFILE" CERT_NAME="$CERT_NAME" \
APP_PROFILE="$APP_PROFILE" HEALTH_MONITOR="$HEALTH_MONITOR" \
"$JUMPVENV/bin/python" - <<'PY'
import os, sys, json, requests
requests.packages.urllib3.disable_warnings()
CTRL=os.environ["AVI_CONTROLLER"]; BASE="https://%s"%CTRL
s=requests.Session(); s.verify=False
r=s.post(BASE+"/login", data={"username":os.environ["AVI_USER"],"password":os.environ["AVI_PASSWORD"]}, verify=False)
r.raise_for_status()
hdr={"X-Avi-Version":os.environ.get("AVI_VERSION","32.1.1"),"X-Avi-Tenant":os.environ.get("AVI_TENANT","admin")}
csrf=s.cookies.get("csrftoken")
if csrf: hdr["X-CSRFToken"]=csrf; hdr["Referer"]=BASE
def rm(path, name):
    g=s.get("%s/api/%s"%(BASE,path), params={"name":name}, headers=hdr)
    for o in g.json().get("results",[]):
        d=s.delete(o["url"], headers=hdr)
        print("[avi] deleted %s: %s (%s)"%(path,name,d.status_code))
# reverse dependency order
rm("virtualservice", os.environ["VS_NAME"])
rm("vsvip", os.environ["VS_NAME"]+"-vsvip")
rm("vsdatascriptset","AI-MCP-Failover")
rm("pool", os.environ["POOL_NAME"])
rm("healthmonitor", os.environ["HEALTH_MONITOR"])
rm("wafpolicy", os.environ["WAF_POLICY"])
rm("wafpolicypsmgroup","MCP-ToolsCall-PSM")
rm("wafprofile", os.environ["WAF_PROFILE"])
rm("ssopolicy", os.environ["SSO_POLICY"])
rm("authprofile", os.environ["AUTH_PROFILE"])
rm("jwtserverprofile", os.environ["JWT_PROFILE"])
rm("pkiprofile", os.environ["PKI_PROFILE"])
rm("applicationprofile", os.environ["APP_PROFILE"])
rm("sslkeyandcertificate", os.environ["CERT_NAME"])
rm("sslkeyandcertificate", os.environ["CERT_NAME"]+"-CA")
print("[avi] object removal complete")
PY

# ---------------------------------------------------------------------------
# VMs
# ---------------------------------------------------------------------------
say "Destroying demo VMs"
export GOVC_URL="$VSPHERE_SERVER" GOVC_USERNAME="$VSPHERE_USER" GOVC_PASSWORD="$VSPHERE_PASSWORD"
export GOVC_INSECURE="$VSPHERE_INSECURE" GOVC_DATACENTER="$VSPHERE_DATACENTER"
for name in "$MCP_A_NAME" "$MCP_B_NAME" "$AGENT_NAME"; do
  if "$GOVC" vm.info "$name" >/dev/null 2>&1; then
    "$GOVC" vm.power -off -force "$name" >/dev/null 2>&1 || true
    "$GOVC" vm.destroy "$name" && echo "[vsphere] destroyed $name"
  else
    echo "[vsphere] $name not found, skipping"
  fi
done

say "Teardown complete"
