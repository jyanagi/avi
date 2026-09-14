#!/usr/bin/env node
/*
 * Per-node front proxy for the Avi WAF Log4Shell demo.
 *
 * Sits on the pool-member port (8080) in front of the vulnerable Log4j
 * container (127.0.0.1:8081). It forwards every request verbatim, headers
 * included, so the X-Api-Version header still reaches the vulnerable Java
 * logger. Its only additions are:
 *   - an X-Served-By response header so the console can show which pool
 *     member Avi selected for a given request, and
 *   - a /healthz endpoint that reflects whether the upstream container is
 *     actually reachable, so stopping a container shows the node as down.
 *
 * Node itself is not vulnerable to Log4Shell; it is only a transparent hop.
 * Pure Node core, no npm dependencies.
 */

const http = require("http");
const net = require("net");
const os = require("os");

const PORT = parseInt(process.env.PORT || "8080", 10);
const UPSTREAM_HOST = process.env.UPSTREAM_HOST || "127.0.0.1";
const UPSTREAM_PORT = parseInt(process.env.UPSTREAM_PORT || "8081", 10);
const SERVED_BY = process.env.SERVED_BY || os.hostname();

function upstreamAlive() {
  return new Promise((resolve) => {
    const sock = net.connect(UPSTREAM_PORT, UPSTREAM_HOST);
    let done = false;
    const finish = (ok) => {
      if (done) return;
      done = true;
      sock.destroy();
      resolve(ok);
    };
    sock.setTimeout(1500);
    sock.once("connect", () => finish(true));
    sock.once("timeout", () => finish(false));
    sock.once("error", () => finish(false));
  });
}

const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    upstreamAlive().then((ok) => {
      res.writeHead(ok ? 200 : 503, {
        "Content-Type": "application/json",
        "X-Served-By": SERVED_BY,
      });
      res.end(JSON.stringify({ node: SERVED_BY, upstream: ok ? "up" : "down" }));
    });
    return;
  }

  const proxyReq = http.request(
    {
      host: UPSTREAM_HOST,
      port: UPSTREAM_PORT,
      method: req.method,
      path: req.url,
      headers: req.headers,
    },
    (proxyRes) => {
      const headers = Object.assign({}, proxyRes.headers, {
        "X-Served-By": SERVED_BY,
      });
      res.writeHead(proxyRes.statusCode || 502, headers);
      proxyRes.pipe(res);
    }
  );

  proxyReq.on("error", () => {
    res.writeHead(502, {
      "Content-Type": "application/json",
      "X-Served-By": SERVED_BY,
    });
    res.end(JSON.stringify({ error: "upstream unreachable", node: SERVED_BY }));
  });

  req.pipe(proxyReq);
});

server.listen(PORT, () => {
  console.log(
    `[proxy] ${SERVED_BY} :${PORT} -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}`
  );
});
