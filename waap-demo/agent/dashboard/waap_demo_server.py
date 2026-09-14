#!/usr/bin/env python3
"""
WAAP-for-AI demo dashboard server.

A thin presentation layer over the existing agent.py / attack.py demo drivers.
It runs each scene as a subprocess on this host (api.acme.com), streams the
output to the browser over Server-Sent Events, and derives a pass/fail verdict
per scene. Secrets stay server-side in this process's environment; the browser
never sees them.

  * Nothing here re-implements the demo. It shells out to your real scripts so
    what the dashboard runs is exactly what you'd run by hand.
  * Runs on its own port (default 8700), separate from Nessus on 8834.
  * Serves over HTTPS using your api.acme.com certificate.

Run:
    pip install --user fastapi uvicorn        # one-time, stdlib-only otherwise
    export AVI_MCP=https://mcp.us-east.demo.lab
    export AVI_LLM=https://llm.us-east.demo.lab
    export KC=https://keycloak.demo.lab:8443
    export KC_REALM=acme-ai
    export SECRET_CATALOG=... SECRET_OPS=... SECRET_FINANCE=...
    export INSECURE=1                          # if DemoRootCA not in trust store
    python3 waap_demo_server.py

Then browse to  https://api.acme.com:8700/
"""

import asyncio
import json
import os
import shlex
import time
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
import uvicorn

# --------------------------------------------------------------------------
# Configuration - edit these to match this host.
# --------------------------------------------------------------------------
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8700                       # separate socket from Nessus (8834)

# TLS: point these at your api.acme.com cert/key. If either is missing the
# server falls back to HTTP with a loud warning (fine for a quick local test,
# not for a demo).
TLS_CERT = os.environ.get("DEMO_TLS_CERT", "/opt/acme-ai/api.acme.com.crt")
TLS_KEY = os.environ.get("DEMO_TLS_KEY", "/opt/acme-ai/api.acme.com.key")

# Where agent.py / attack.py live on this host.
TOOLS_DIR = Path(os.environ.get("DEMO_TOOLS_DIR", "/home/jyanagi/acme-ai"))
PYTHON = os.environ.get("DEMO_PYTHON", "python3") + " -u"

# Environment passed through to the demo scripts. We copy the current process
# environment so AVI_*, KC*, SECRET_*, INSECURE all flow through untouched.
SCRIPT_ENV = dict(os.environ)

# --------------------------------------------------------------------------
# Scene definitions.
#
# Each scene maps to one or more subprocess commands. A scene "passes" when
# every command's exit code and, where relevant, the presence of expected
# markers in the output line up with what that scene is meant to prove.
#
# verdict_markers: substrings that, if present in combined stdout, mean the
# security control did its job. These mirror the PASS/FAIL text your scripts
# already print, so we lean on your own scripts' judgement rather than
# re-deriving it.
# --------------------------------------------------------------------------
SCENES = {
    "mtls": {
        "title": "1 - Mutual TLS at the edge",
        "owasp": ["API2:2023 Broken Authentication", "API8:2023 Security Misconfiguration"],
        "mcp": ["MCP07:2025 Insufficient Authentication & Authorization"],
        "controls": ["PKI Profile", "SSL/TLS Certificate", "Application Profile (client-cert mode)"],
        "outcome": "Only a client holding a trusted certificate can even open a connection to Avi.",
        "explain": (
            "Before any token or tool call, the agent must present a client certificate. Avi "
            "validates it against its PKI profile at the TLS handshake. A connection with no "
            "certificate is rejected outright; a connection with the agent's certificate is "
            "accepted and proceeds to the JWT layer. Machine identity is proven at the edge, "
            "before authorization, WAF, or the unauthenticated backend are ever reached."
        ),
        "action": "Agent establishing mutual TLS connection to Avi",
        "commands": ["{py} {tools}/agent.py scene-mtls"],
        "kind": "flow",
        "pass_markers": ["PASS"],
        "fail_markers": ["FAIL"],
        "caveat": (
            "This proves machine identity (the certificate), which is distinct from the agent's "
            "tier identity (the JWT, shown in later stages). Both are enforced at Avi: the "
            "certificate at the TLS handshake, the token just after. The backend has neither."
        ),
        "paths": [["agent", "avi"]],
        "verdict_node": "avi",
    },
    "discover": {
        "title": "2 - Agent self-onboarding (RFC 9728)",
        "owasp": ["API8:2023 Security Misconfiguration"],
        "mcp": ["MCP07:2025 Insufficient Authentication & Authorization"],
        "controls": ["Application Profile (MCP)", "Virtual Service"],
        "outcome": "A third-party agent discovers where to authenticate with zero backend configuration.",
        "explain": (
            "The agent calls the MCP endpoint with no token. Avi answers 401 with a "
            "WWW-Authenticate header pointing at the protected-resource metadata. The agent "
            "fetches that metadata, learns the authorization server and scopes, and now knows "
            "exactly how to authenticate - all without touching the unauthenticated backend."
        ),
        "action": "Agent discovering how to authenticate (RFC 9728)",
        "commands": ["{py} {tools}/agent.py discover"],
        "kind": "flow",          # informational scene, success = clean run
        "pass_markers": ["HTTP 200"],
        "fail_markers": [],
        # paths: which links animate, in sequence. verdict_node: where the
        # outcome lands (avi = enforced at edge). See topology in the UI.
        "paths": [["agent", "avi"], ["avi", "keycloak"]],
        "verdict_node": "avi",
    },
    "authz": {
        "title": "3 - Least-privilege tool authorization",
        "owasp": ["API5:2023 Broken Function Level Authorization", "API1:2023 Broken Object Level Authorization"],
        "mcp": ["MCP02:2025 Privilege Escalation via Scope Creep", "MCP07:2025 Insufficient Authentication & Authorization"],
        "controls": ["SSO Policy (authorization rules)", "Auth Profile", "JWT Server Profile"],
        "outcome": "Each agent tier is confined to its own tools; only finance can move money.",
        "explain": (
            "Three agent identities authenticate through Keycloak, each with a different "
            "mcp_tier claim: catalog, ops, and finance. Avi's SSO authorization policy validates "
            "the JWT on every request and routes each tier only to its own namespace. Catalog reads "
            "inventory, ops creates orders, finance handles invoices - and any attempt to cross "
            "lanes (a catalog or ops token calling payment.release) is rejected with 403 on the "
            "claim, at the edge, before the unauthenticated backend is ever reached."
        ),
        "action": "Exercising all three tiers against Avi authorization policy",
        "commands": ["{py} {tools}/agent.py scene-authz"],
        "kind": "authz",
        "pass_markers": ["PASS"],
        "fail_markers": ["FAIL", "leak", "unexpected"],
        "caveat": (
            "Discovery (stage 2) is tier-agnostic - the agent has no identity until it "
            "authenticates. The catalog, ops, and finance tiers only come into play here, once a "
            "JWT with an mcp_tier claim exists for Avi to enforce on."
        ),
        "paths": [["agent", "avi"], ["avi", "keycloak"], ["avi", "mcp"]],
        "verdict_node": "avi",
    },
    "token": {
        "title": "4a - Forged and invalid tokens",
        "owasp": ["API2:2023 Broken Authentication"],
        "mcp": ["MCP01:2025 Token Mismanagement & Secret Exposure", "MCP07:2025 Insufficient Authentication & Authorization"],
        "controls": ["JWT Server Profile (signature/issuer/audience/expiry)", "Auth Profile", "SSO Policy"],
        "outcome": "Every malformed, expired, or forged token is rejected.",
        "explain": (
            "The attacker throws a battery of bad tokens at Avi: alg:none, expired, wrong "
            "audience, and a forged tier claim. Avi validates the signature, issuer, audience, "
            "and expiry on every request and rejects each one. No valid token, no access."
        ),
        "action": "Attacker submitting forged and invalid tokens to Avi",
        "commands": ["{py} {tools}/attack.py token"],
        "kind": "attack",
        "pass_markers": ["PASS", "rejected", "401", "403"],
        "fail_markers": ["accepted", "200 unexpected"],
        "paths": [["agent", "avi"]],
        "verdict_node": "avi",
    },
    "inject": {
        "title": "4b - Prompt-injection guardrails",
        "owasp": ["API8:2023 Security Misconfiguration (input validation)"],
        "mcp": ["MCP06:2025 Prompt Injection via Contextual Payloads"],
        "controls": ["WAF Policy", "WAF Profile", "Pre-CRS Custom Rules (AI-GUARDRAILS)"],
        "outcome": "Prompt-injection strings are blocked by the WAF before reaching the model or tools.",
        "explain": (
            "The attacker sends classic prompt-injection payloads through both MCP tool arguments "
            "and chat messages. Avi's custom WAF guardrail rules (AI-GUARDRAILS) match the "
            "injection patterns and block with 403. These are virtual patches you author and tune."
        ),
        "action": "Attacker attempting prompt injection through Avi",
        "commands": ["{py} {tools}/attack.py inject"],
        "kind": "attack",
        "pass_markers": ["PASS", "403", "blocked"],
        "fail_markers": ["got through", "200 unexpected"],
        "paths": [["agent", "avi"]],
        "verdict_node": "avi",
    },
    "psm": {
        "title": "4c - Positive security model",
        "owasp": ["API9:2023 Improper Inventory Management", "API8:2023 Security Misconfiguration"],
        "mcp": ["MCP06:2025 Prompt Injection via Contextual Payloads"],
        "controls": ["WAF Policy - Positive Security Model group", "WAF Profile"],
        "outcome": "A well-formed tool call passes; a malformed argument is rejected.",
        "explain": (
            "Avi's positive security model describes the exact shape of every MCP tool argument. "
            "A legitimate inventory.lookup with a valid SKU passes. The same call with a malformed "
            "SKU is rejected because the value fails the described pattern - anything not "
            "explicitly allowed is denied."
        ),
        "action": "Sending a well-formed query, then a malformed one, through Avi",
        "commands": [
            "{py} {tools}/agent.py call --tier catalog --tool inventory.lookup --args {good}",
            "{py} {tools}/agent.py call --tier catalog --tool inventory.lookup --args {bad}",
        ],
        "kind": "psm",
        "pass_markers": ["200", "403"],
        "fail_markers": [],
        "verdict": "both_200_403",
        "args": {
            "good": shlex.quote('{"sku":"SKU-4410"}'),
            "bad": shlex.quote('{"sku":"bad"}'),
        },
        "paths": [["agent", "avi"], ["avi", "mcp"]],
        "verdict_node": "avi",
    },
    "session": {
        "title": "5 - Session resilience under failover",
        "owasp": ["API4:2023 Unrestricted Resource Consumption (availability)"],
        "mcp": [],
        "controls": ["Health Monitor", "Pool", "DataScript (MCP-Failover)", "Virtual Service"],
        "outcome": "An MCP session survives a backend node failure with no interruption.",
        "explain": (
            "The agent establishes a session pinned to one backend. When that node is stopped, "
            "the session persists in Avi's Service Engine persistence table, not on the backend, "
            "so Avi re-pins to the surviving node and the conversation continues. The X-Served-By "
            "header shows the served node changing after failover while the session holds."
        ),
        "action": "Establishing a session, then failing the pinned MCP node",
        "commands": ["{py} {tools}/agent.py scene-session --stop-node"],
        "kind": "flow",
        "pass_markers": ["PASS"],
        "fail_markers": ["FAIL"],
        "note": "Runs automatically: it stops the served backend over SSH, proves the session survives, then restarts it. No terminal needed.",
        "caveat": (
            "Avi re-homes the session to a healthy node instantly; the backend then resumes it. "
            "Here the demo tools are stateless per call, so adoption is seamless. In production, "
            "full conversation-context continuity would be backed by shared session state (e.g. Redis) "
            "across nodes. Avi provides the connection-level resilience that makes either possible."
        ),
        "paths": [["agent", "avi"], ["avi", "mcp"], ["avi", "mcp2"]],
        "verdict_node": "avi",
    },
}


app = FastAPI(title="WAAP-for-AI demo")


def build_command(template: str, scene: dict) -> str:
    return template.format(
        py=PYTHON,
        tools=str(TOOLS_DIR),
        **scene.get("args", {}),
    )


async def stream_scene(scene_id: str):
    """Run a scene's commands, yielding SSE events as output arrives."""
    scene = SCENES[scene_id]

    def sse(event: str, data: dict) -> bytes:
        return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()

    yield sse("start", {"scene": scene_id, "title": scene["title"], "ts": time.time()})

    combined = []
    overall_rc = 0

    for template in scene["commands"]:
        cmd = build_command(template, scene)
        # Emit a friendly action label for the console, not the raw shell command,
        # so the demo reads as a live workflow rather than a script being run.
        yield sse("cmd", {"label": scene.get("action", "Running " + scene["title"])})

        try:
            proc = await asyncio.create_subprocess_shell(
                cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=str(TOOLS_DIR),
                env=SCRIPT_ENV,
            )
        except Exception as exc:  # pragma: no cover - defensive
            yield sse("line", {"text": f"[error] could not start: {exc}", "stream": "err"})
            overall_rc = 1
            continue

        assert proc.stdout is not None
        while True:
            raw = await proc.stdout.readline()
            if not raw:
                break
            text = raw.decode(errors="replace").rstrip("\n")
            combined.append(text)
            yield sse("line", {"text": text, "stream": "out"})

        rc = await proc.wait()
        overall_rc = overall_rc or rc
        yield sse("cmd_done", {"cmd": cmd, "rc": rc})

    # Derive verdict from the scripts' own output plus exit codes.
    text_all = "\n".join(combined)
    if scene.get("verdict") == "both_200_403":
        # PSM: the good call must pass (200) AND the bad call must be blocked (403).
        passed = ("200" in text_all) and ("403" in text_all)
    else:
        passed = any(m in text_all for m in scene["pass_markers"]) if scene["pass_markers"] else (overall_rc == 0)
    if any(m in text_all for m in scene.get("fail_markers", [])):
        passed = False

    yield sse("verdict", {
        "scene": scene_id,
        "passed": bool(passed),
        "rc": overall_rc,
        "outcome": scene["outcome"],
    })
    yield sse("end", {"scene": scene_id, "ts": time.time()})


@app.get("/api/scenes")
async def list_scenes():
    """Metadata for the UI to render the scene cards."""
    return JSONResponse({
        sid: {
            "title": s["title"],
            "owasp": s.get("owasp", []),
            "mcp": s.get("mcp", []),
            "controls": s.get("controls", []),
            "outcome": s["outcome"],
            "explain": s["explain"],
            "kind": s["kind"],
            "note": s.get("note"),
            "caveat": s.get("caveat"),
            "paths": s.get("paths", [["agent", "avi"]]),
            "verdict_node": s.get("verdict_node", "avi"),
        }
        for sid, s in SCENES.items()
    })


@app.get("/api/run/{scene_id}")
async def run_scene(scene_id: str, request: Request):
    if scene_id not in SCENES:
        return JSONResponse({"error": "unknown scene"}, status_code=404)
    return StreamingResponse(
        stream_scene(scene_id),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/api/health")
async def health():
    """Pre-flight the UI can call to confirm env + tools are present."""
    tools_ok = (TOOLS_DIR / "agent.py").exists() and (TOOLS_DIR / "attack.py").exists()
    env_ok = all(os.environ.get(k) for k in ("AVI_MCP", "KC", "KC_REALM"))
    secrets_ok = any(os.environ.get(k) for k in ("SECRET_CATALOG", "SECRET_OPS", "SECRET_FINANCE"))
    return JSONResponse({
        "tools_found": tools_ok,
        "tools_dir": str(TOOLS_DIR),
        "env_configured": env_ok,
        "secrets_present": secrets_ok,
        "insecure_tls": os.environ.get("INSECURE") == "1",
    })


@app.get("/favicon.ico")
async def favicon():
    """Avi-blue enforcement-point diamond, served as SVG."""
    from fastapi.responses import Response
    svg = (
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'>"
        "<rect width='32' height='32' rx='6' fill='#0f1e26'/>"
        "<path d='M16 6 L26 16 L16 26 L6 16 Z' fill='none' stroke='#0072a3' stroke-width='3'/>"
        "<path d='M16 11 L21 16 L16 21 L11 16 Z' fill='#0072a3'/>"
        "</svg>"
    )
    return Response(svg, media_type="image/svg+xml")


@app.get("/clr-ui.min.css")
async def clarity_css():
    """Serve the bundled Clarity stylesheet locally (no CDN / internet needed).

    The Metropolis font is embedded in this CSS as a base64 data URI, so this
    single file delivers the complete Clarity look offline.
    """
    css_path = Path(__file__).parent / "clr-ui.min.css"
    if not css_path.exists():
        return JSONResponse({"error": "clr-ui.min.css not found next to server"}, status_code=404)
    from fastapi.responses import Response
    return Response(css_path.read_text(), media_type="text/css")


@app.get("/", response_class=HTMLResponse)
async def index():
    return HTMLResponse((Path(__file__).parent / "dashboard.html").read_text())


def main():
    ssl_args = {}
    if Path(TLS_CERT).exists() and Path(TLS_KEY).exists():
        ssl_args = {"ssl_certfile": TLS_CERT, "ssl_keyfile": TLS_KEY}
        scheme = "https"
    else:
        print("=" * 70)
        print("WARNING: TLS cert/key not found - starting in PLAIN HTTP.")
        print(f"  looked for cert: {TLS_CERT}")
        print(f"  looked for key:  {TLS_KEY}")
        print("  Set DEMO_TLS_CERT / DEMO_TLS_KEY or place the files above.")
        print("=" * 70)
        scheme = "http"

    print(f"WAAP demo dashboard -> {scheme}://{LISTEN_HOST}:{LISTEN_PORT}/")
    print(f"  tools dir: {TOOLS_DIR}")
    print(f"  reachable at {scheme}://api.acme.com:{LISTEN_PORT}/ once firewalld allows {LISTEN_PORT}/tcp")
    uvicorn.run(app, host=LISTEN_HOST, port=LISTEN_PORT, **ssl_args)


if __name__ == "__main__":
    main()
