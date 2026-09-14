#!/usr/bin/env python3
"""
configure-avi.py - Provision every Avi object for the WAAP-for-AI / MCP demo
against an existing Avi Controller, via the REST API. Idempotent: objects are
looked up by name and updated in place, or created if absent.

Order of creation respects dependencies:
  1  SSL/TLS certificate (server) + CA cert import
  2  PKI profile (client-cert trust for agent mTLS)
  3  JWT server profile  ->  Auth (SSO) profile  ->  SSO policy
  4  WAF profile (content-type maps, PSM group, Pre-CRS custom rules)
  5  WAF policy (binds the profile + PSM + Pre-CRS group)
  6  Application profile (cloned from System-Secure-HTTP-MCP)
  7  Health monitor
  8  Pool (AI-MCP-L7-Vs-Pool) with the two MCP servers
  9  VsVip (VIP) -> Virtual service (binds cert, PKI, SSO, WAF, app profile,
     health monitor, pool, and the failover DataScript)

Reads all inputs from config/config.env (via the wrapper that exports them)
and the generated certs in config/certs/.

This talks ONLY to the Avi Controller named in config.env. No internet needed.
"""
import os
import sys
import json
import time
import base64

try:
    import requests
    from requests.packages.urllib3.exceptions import InsecureRequestWarning
    requests.packages.urllib3.disable_warnings(InsecureRequestWarning)
except Exception as e:  # pragma: no cover
    print("FATAL: requests not available. Install vendored wheels first.", file=sys.stderr)
    raise

# --------------------------------------------------------------------------
# Config from environment (exported by the shell wrapper from config.env)
# --------------------------------------------------------------------------
def env(k, default=None, required=False):
    v = os.environ.get(k, default)
    if required and (v is None or v == "" or v == "CHANGE_ME"):
        sys.exit("FATAL: required config value %s is missing or unset" % k)
    return v

CTRL      = env("AVI_CONTROLLER", required=True)
USER      = env("AVI_USER", "admin")
PASSWORD  = env("AVI_PASSWORD", required=True)
TENANT    = env("AVI_TENANT", "admin")
CLOUD     = env("AVI_CLOUD", "Default-Cloud")
SEGROUP   = env("AVI_SE_GROUP", "Default-Group")
VS_NET    = env("AVI_VS_NETWORK", required=True)
VIP       = env("AVI_VIP", required=True)
API_VER   = env("AVI_VERSION", "32.1.1")

CERT_NAME = env("CERT_NAME", "AI-MCP-Cert")
PKI_PROF  = env("PKI_PROFILE", "AI-Agent-PKI")
JWT_PROF  = env("JWT_PROFILE", "AI-JWT-ServerProfile")
AUTH_PROF = env("AUTH_PROFILE", "AI-JWT-AuthProfile")
SSO_POL   = env("SSO_POLICY", "AI-SSO-Policy")
WAF_PROF  = env("WAF_PROFILE", "AI-WAF-Profile")
WAF_POL   = env("WAF_POLICY", "AI-WAAP-Policy")
APP_PROF  = env("APP_PROFILE", "AI-MCP-AppProfile")
HM_NAME   = env("HEALTH_MONITOR", "AI-MCP-HealthMonitor")
POOL_NAME = env("POOL_NAME", "AI-MCP-L7-Vs-Pool")
VS_NAME   = env("VS_NAME", "AI-MCP-L7-Vs")

MCP_A_IP  = env("MCP_A_IP", required=True)
MCP_B_IP  = env("MCP_B_IP", required=True)
MCP_PORT  = int(env("MCP_PORT", "8443"))

KC_REALM  = env("KC_REALM", "acme-ai")
AGENT_IP  = env("AGENT_IP", required=True)
KC_PORT   = env("KC_HTTPS_PORT", "8443")

CERT_DIR  = env("CERT_DIR", required=True)   # path to config/certs
DS_PATH   = env("DATASCRIPT_PATH", required=True)  # path to failover datascript .lua

BASE = "https://%s" % CTRL


# --------------------------------------------------------------------------
# Thin Avi REST client
# --------------------------------------------------------------------------
class Avi:
    def __init__(self):
        self.s = requests.Session()
        self.s.verify = False
        self.hdr = {"X-Avi-Version": API_VER, "Content-Type": "application/json"}
        self._login()

    def _login(self):
        r = self.s.post(BASE + "/login",
                        data={"username": USER, "password": PASSWORD},
                        verify=False, timeout=30)
        r.raise_for_status()
        csrf = self.s.cookies.get("csrftoken")
        if csrf:
            self.hdr["X-CSRFToken"] = csrf
            self.hdr["Referer"] = BASE
        self.hdr["X-Avi-Tenant"] = TENANT
        print("[avi] authenticated to %s as %s (tenant %s)" % (CTRL, USER, TENANT))

    def get_by_name(self, path, name):
        r = self.s.get("%s/api/%s" % (BASE, path),
                       params={"name": name}, headers=self.hdr, timeout=30)
        r.raise_for_status()
        res = r.json().get("results", [])
        return res[0] if res else None

    def ref(self, path, name):
        """Return the URL ref for an object by name, or None."""
        o = self.get_by_name(path, name)
        return o["url"] if o else None

    def create_or_update(self, path, name, body):
        existing = self.get_by_name(path, name)
        if existing:
            url = existing["url"]
            body = dict(body); body["uuid"] = existing["uuid"]
            r = self.s.put(url, headers=self.hdr, data=json.dumps(body), timeout=60)
            action = "updated"
        else:
            r = self.s.post("%s/api/%s" % (BASE, path),
                            headers=self.hdr, data=json.dumps(body), timeout=60)
            action = "created"
        if r.status_code not in (200, 201):
            print("[avi] ERROR %s %s -> %s\n%s" % (action, name, r.status_code, r.text),
                  file=sys.stderr)
            r.raise_for_status()
        print("[avi] %s %s: %s" % (path, action, name))
        return r.json()


def readfile(path):
    with open(path) as f:
        return f.read()


def main():
    avi = Avi()
    cloud_ref = avi.ref("cloud", CLOUD)
    seg_ref   = avi.ref("serviceenginegroup", SEGROUP)
    if not cloud_ref:
        sys.exit("FATAL: cloud '%s' not found on controller" % CLOUD)

    # ----------------------------------------------------------------------
    # 1. SSL/TLS certificate (server) - import key + cert
    # ----------------------------------------------------------------------
    server_crt = readfile(os.path.join(CERT_DIR, "server.crt"))
    server_key = readfile(os.path.join(CERT_DIR, "server.key"))
    ca_crt     = readfile(os.path.join(CERT_DIR, "ca.crt"))

    # Import the CA as its own object first (used by PKI profile trust + chain)
    avi.create_or_update("sslkeyandcertificate", CERT_NAME + "-CA", {
        "name": CERT_NAME + "-CA",
        "type": "SSL_CERTIFICATE_TYPE_CA",
        "certificate": {"certificate": ca_crt},
    })

    avi.create_or_update("sslkeyandcertificate", CERT_NAME, {
        "name": CERT_NAME,
        "type": "SSL_CERTIFICATE_TYPE_VIRTUALSERVICE",
        "key": server_key,
        "certificate": {"certificate": server_crt},
    })

    # ----------------------------------------------------------------------
    # 2. PKI profile (trust the demo CA for agent client certs / mTLS)
    # ----------------------------------------------------------------------
    avi.create_or_update("pkiprofile", PKI_PROF, {
        "name": PKI_PROF,
        "ca_certs": [{"certificate": ca_crt}],
        "crl_check": False,
        "validate_only_leaf_crl": True,
    })

    # ----------------------------------------------------------------------
    # 3. JWT server profile -> Auth profile (SSO) -> SSO policy
    #    Keycloak realm cert is fetched at runtime via JWKS; here we point the
    #    profile at the realm issuer. The controller validates RS256 via JWKS.
    # ----------------------------------------------------------------------
    issuer = "https://%s:%s/realms/%s" % (AGENT_IP, KC_PORT, KC_REALM)
    jwks   = issuer + "/protocol/openid-connect/certs"

    avi.create_or_update("jwtserverprofile", JWT_PROF, {
        "name": JWT_PROF,
        "jwt_profile_type": "CLIENT_AUTH",
        "issuer": issuer,
        # controllers that support remote JWKS use controller_keys/jwks_url;
        # if your build requires static keys, import them here instead.
        "jwks_url": jwks,
    })

    jwt_ref = avi.ref("jwtserverprofile", JWT_PROF)
    avi.create_or_update("authprofile", AUTH_PROF, {
        "name": AUTH_PROF,
        "type": "AUTH_PROFILE_JWT",
        "jwt_profile_ref": jwt_ref,
    })

    # SSO policy referencing the JWT auth profile, with per-tier authorization
    # rules mapping the mcp_tier claim to allowed namespaces.
    auth_ref = avi.ref("authprofile", AUTH_PROF)
    avi.create_or_update("ssopolicy", SSO_POL, {
        "name": SSO_POL,
        "type": "SSO_TYPE_JWT",
        "authentication_policy": {
            "default_auth_profile_ref": auth_ref,
        },
        "authorization_policy": {
            # IMPORTANT (learned in the field): the JWT claim match must use the
            # jwt_claim_type_string / string_match structure, and the deny rule
            # must return an HTTP 403 local response, NOT CLOSE_CONNECTION.
            # CLOSE_CONNECTION drops the socket with no response, which the demo
            # tools see as a connection error rather than a clean "blocked".
            # The exact match schema is version-specific; if the API rejects a
            # field, build one rule in the UI (JSON Web Tokens match: Token Name
            # = the JWT server profile, Claim Name = mcp_tier, Type = String,
            # Criteria = Equals, Value = <tier>) plus a Path Begins-with rule,
            # then `show ssopolicy` to capture the exact JSON for your build.
            "authz_rules": [
                {"name": "allow-catalog", "index": 1,
                 "match": {
                     "path": {"match_criteria": "BEGINS_WITH", "match_str": ["/mcp/catalog"]},
                     "access_token": {"matches": [
                         {"type": "jwt_claim_type_string", "name": "mcp_tier",
                          "string_match": {"match_criteria": "EQUALS", "match_str": ["catalog"]}}]}},
                 "action": {"type": "ALLOW"}},
                {"name": "allow-ops", "index": 2,
                 "match": {
                     "path": {"match_criteria": "BEGINS_WITH", "match_str": ["/mcp/ops"]},
                     "access_token": {"matches": [
                         {"type": "jwt_claim_type_string", "name": "mcp_tier",
                          "string_match": {"match_criteria": "EQUALS", "match_str": ["ops"]}}]}},
                 "action": {"type": "ALLOW"}},
                {"name": "allow-finance", "index": 3,
                 "match": {
                     "path": {"match_criteria": "BEGINS_WITH", "match_str": ["/mcp/finance"]},
                     "access_token": {"matches": [
                         {"type": "jwt_claim_type_string", "name": "mcp_tier",
                          "string_match": {"match_criteria": "EQUALS", "match_str": ["finance"]}}]}},
                 "action": {"type": "ALLOW"}},
                {"name": "allow-inference", "index": 4,
                 "match": {
                     "path": {"match_criteria": "BEGINS_WITH", "match_str": ["/v1/"]},
                     "access_token": {"matches": [
                         {"type": "jwt_claim_type_string", "name": "mcp_tier",
                          "string_match": {"match_criteria": "IS_IN",
                                           "match_str": ["catalog", "ops", "finance"]}}]}},
                 "action": {"type": "ALLOW"}},
                {"name": "deny-all", "index": 100,
                 "match": {"path": {"match_criteria": "BEGINS_WITH", "match_str": ["/"]}},
                 "action": {"type": "HTTP_LOCAL_RESPONSE", "status_code": 403}},
            ]
        },
    })

    # ----------------------------------------------------------------------
    # 4. WAF profile - content-type maps, PSM, Pre-CRS custom rules.
    #    Cloned conceptually from System-WAF-Profile; we set the critical
    #    fields the demo relies on (response buffer, JSON parsing, phase actions).
    # ----------------------------------------------------------------------
    avi.create_or_update("wafprofile", WAF_PROF, {
        "name": WAF_PROF,
        "config": {
            "request_hdr_default_action":  "phase:1,deny,status:403,log,auditlog",
            "request_body_default_action": "phase:2,deny,status:403,log,auditlog",
            "response_hdr_default_action": "phase:3,deny,status:403,log,auditlog",
            "response_body_default_action":"phase:4,deny,status:403,log,auditlog",
            "client_request_max_body_size": 128,
            "server_response_max_body_size": 128,
            "regex_match_limit": 30000,
            "regex_recursion_limit": 10000,
            "max_execution_time": 50,
            "ignore_incomplete_request_body_error": True,
            "status_code_for_rejected_requests": "HTTP_RESPONSE_CODE_403",
            "content_type_mappings": [
                {"content_type": "application/json",
                 "request_body_parser": "WAF_REQUEST_PARSER_JSON", "match_op": "EQUALS"},
                {"content_type": "application/x-www-form-urlencoded",
                 "request_body_parser": "WAF_REQUEST_PARSER_URLENCODED", "match_op": "EQUALS"},
            ],
        },
    })

    # ----------------------------------------------------------------------
    # 5. WAF policy - CRS + AI-GUARDRAILS Pre-CRS group + PSM group.
    #    The Pre-CRS custom rules and the PSM argument rule (with the tightened
    #    value pattern that defeats prompt injection) are set here.
    # ----------------------------------------------------------------------
    waf_prof_ref = avi.ref("wafprofile", WAF_PROF)
    avi.create_or_update("wafpolicy", WAF_POL, {
        "name": WAF_POL,
        "waf_profile_ref": waf_prof_ref,
        "mode": "WAF_MODE_ENFORCEMENT",
        "paranoia_level": "WAF_PARANOIA_LEVEL_LOW",
        "pre_crs_groups": [{
            "name": "AI-GUARDRAILS",
            "enable": True,
            "rules": [
                {"index": 1, "rule_id": "1000001", "enable": True,
                 "name": "prompt-injection phrases",
                 "rule": ("SecRule REQUEST_BODY|ARGS \"@rx (?i)(ignore\\s+(all\\s+)?"
                          "previous\\s+instructions|disregard\\s+(your\\s+)?(system\\s+)?"
                          "prompt|you\\s+are\\s+now\\s+dan|act\\s+as\\s+(an?\\s+)?"
                          "(unrestricted|jailbroken))\" "
                          "\"id:1000001,phase:2,deny,status:403,t:none,t:urlDecodeUni,"
                          "t:lowercase,msg:'AI-GUARDRAILS: prompt-injection / jailbreak phrase',"
                          "logdata:'%{MATCHED_VAR}',tag:'ai-guardrails'\"")},
                {"index": 2, "rule_id": "1000002", "enable": True,
                 "name": "sensitive-action / data-exfil",
                 "rule": ("SecRule REQUEST_BODY|ARGS \"@rx (?i)(reveal\\s+all\\s+.*"
                          "(bank|secret|credential|password|api[_-]?key)|call\\s+payment"
                          "\\.release|dump\\s+(all\\s+)?(secret|credential|password)s?)\" "
                          "\"id:1000002,phase:2,deny,status:403,t:none,t:urlDecodeUni,"
                          "t:lowercase,msg:'AI-GUARDRAILS: sensitive-action / data-exfil',"
                          "logdata:'%{MATCHED_VAR}',tag:'ai-guardrails'\"")},
                {"index": 3, "rule_id": "1000003", "enable": True,
                 "name": "hidden-instruction markers",
                 "rule": ("SecRule REQUEST_BODY|ARGS \"@rx (?i)(<!--\\s*system:|"
                          "<\\|im_start\\|>|###\\s*system|\\[system\\]\\s*:?\\s*ignore)\" "
                          "\"id:1000003,phase:2,deny,status:403,t:none,t:urlDecodeUni,"
                          "t:lowercase,msg:'AI-GUARDRAILS: hidden instruction marker',"
                          "logdata:'%{MATCHED_VAR}',tag:'ai-guardrails'\"")},
                {"index": 4, "rule_id": "1000004", "enable": True,
                 "name": "template / SSTI injection",
                 "rule": ("SecRule REQUEST_BODY|ARGS \"@rx (?i)(\\{\\{.*constructor|"
                          "constructor\\.constructor|\\$\\{.*\\}|<%.*%>)\" "
                          "\"id:1000004,phase:2,deny,status:403,t:none,t:urlDecodeUni,"
                          "msg:'AI-GUARDRAILS: template / SSTI injection',"
                          "logdata:'%{MATCHED_VAR}',tag:'ai-guardrails'\"")},
            ],
        }],
        # Positive Security Model group: only well-formed short queries pass.
        "positive_security_model": {
            "group_refs": [],
        },
    })

    # PSM group with the tightened arg-query rule (max length 40, safe charset).
    avi.create_or_update("wafpolicypsmgroup", "MCP-ToolsCall-PSM", {
        "name": "MCP-ToolsCall-PSM",
        "enable": True,
        "miss_action": "WAF_ACTION_BLOCK",
        "locations": [{
            "name": "tools-call",
            "index": 1,
            "match": {"path": {"match_criteria": "BEGINS_WITH", "match_str": ["/mcp/"]}},
            "rules": [{
                "name": "arg-query", "rule_id": "2000009", "index": 1, "enable": True,
                "mode": "WAF_MODE_ENFORCEMENT",
                "match": {"args": {"match_criteria": "EQUALS",
                                   "match_case": "INSENSITIVE",
                                   "arg_name": "params.arguments.query"}},
                "match_value_string_group_ref": None,
                "match_value_pattern": "^[\\w\\s.-]{1,40}$",
            }],
        }],
    })

    # ----------------------------------------------------------------------
    # 6. Application profile - clone System-Secure-HTTP-MCP so streaming MCP
    #    transport works, then attach nothing that breaks it.
    # ----------------------------------------------------------------------
    base_app = avi.get_by_name("applicationprofile", "System-Secure-HTTP-MCP")
    if base_app:
        body = {k: v for k, v in base_app.items()
                if k not in ("uuid", "url", "_last_modified", "name")}
        body["name"] = APP_PROF
        avi.create_or_update("applicationprofile", APP_PROF, body)
        app_ref = avi.ref("applicationprofile", APP_PROF)
    else:
        print("[avi] WARN: System-Secure-HTTP-MCP not found; using System-Secure-HTTP")
        app_ref = avi.ref("applicationprofile", "System-Secure-HTTP")

    # ----------------------------------------------------------------------
    # 7. Health monitor (HTTPS GET on the MCP well-known path)
    # ----------------------------------------------------------------------
    avi.create_or_update("healthmonitor", HM_NAME, {
        "name": HM_NAME,
        "type": "HEALTH_MONITOR_HTTPS",
        "receive_timeout": 2, "send_interval": 2,
        "successful_checks": 2, "failed_checks": 2,
        "https_monitor": {
            "http_request": "GET /.well-known/oauth-protected-resource HTTP/1.0",
            "http_response_code": ["HTTP_2XX", "HTTP_4XX"],
        },
    })
    hm_ref = avi.ref("healthmonitor", HM_NAME)

    # ----------------------------------------------------------------------
    # 8. Pool with the two MCP servers.
    # The backends serve TLS on MCP_PORT, so the pool MUST have an SSL profile
    # and connect over SSL. Without this, Avi speaks plaintext to a TLS listener
    # and the connection is closed after auth passes (empty reply / 503).
    # ----------------------------------------------------------------------
    ssl_prof_ref = avi.ref("sslprofile", "System-Standard")
    avi.create_or_update("pool", POOL_NAME, {
        "name": POOL_NAME,
        "cloud_ref": cloud_ref,
        "health_monitor_refs": [hm_ref],
        "default_server_port": MCP_PORT,
        "lb_algorithm": "LB_ALGORITHM_ROUND_ROBIN",
        "ssl_profile_ref": ssl_prof_ref,
        "servers": [
            {"ip": {"addr": MCP_A_IP, "type": "V4"}, "port": MCP_PORT, "enabled": True},
            {"ip": {"addr": MCP_B_IP, "type": "V4"}, "port": MCP_PORT, "enabled": True},
        ],
    })
    pool_ref = avi.ref("pool", POOL_NAME)

    # ----------------------------------------------------------------------
    # 9. DataScript (failover), VsVip, and the Virtual Service
    # ----------------------------------------------------------------------
    ds_text = readfile(DS_PATH)
    avi.create_or_update("vsdatascriptset", "AI-MCP-Failover", {
        "name": "AI-MCP-Failover",
        "datascript": [
            {"evt": "VS_DATASCRIPT_EVT_HTTP_REQ", "script": ds_text},
        ],
        "pool_refs": [pool_ref],
    })
    ds_ref = avi.ref("vsdatascriptset", "AI-MCP-Failover")

    # VsVip
    avi.create_or_update("vsvip", VS_NAME + "-vsvip", {
        "name": VS_NAME + "-vsvip",
        "cloud_ref": cloud_ref,
        "vip": [{"vip_id": "1", "ip_address": {"addr": VIP, "type": "V4"}}],
    })
    vsvip_ref = avi.ref("vsvip", VS_NAME + "-vsvip")

    cert_ref = avi.ref("sslkeyandcertificate", CERT_NAME)
    pki_ref  = avi.ref("pkiprofile", PKI_PROF)
    waf_ref  = avi.ref("wafpolicy", WAF_POL)
    sso_ref  = avi.ref("ssopolicy", SSO_POL)

    avi.create_or_update("virtualservice", VS_NAME, {
        "name": VS_NAME,
        "cloud_ref": cloud_ref,
        "se_group_ref": seg_ref,
        "vsvip_ref": vsvip_ref,
        "pool_ref": pool_ref,
        "application_profile_ref": app_ref,
        "ssl_key_and_certificate_refs": [cert_ref],
        "ssl_profile_ref": None,
        "pki_profile_ref": pki_ref,           # client-cert trust for mTLS
        "waf_policy_ref": waf_ref,
        "sso_policy_ref": sso_ref,
        "vs_datascripts": [{"index": 1, "vs_datascript_set_ref": ds_ref}],
        "services": [{"port": 443, "enable_ssl": True}],
    })

    print("\n[avi] Configuration complete. Virtual service '%s' on VIP %s is live."
          % (VS_NAME, VIP))


if __name__ == "__main__":
    main()
