# Avi WAF Log4Shell Range

A self-contained, closed-loop demonstration that shows a Web Application Firewall
(VMware Avi / NSX Advanced Load Balancer) detecting and blocking the Log4Shell
exploit (CVE-2021-44228) in real time. An operator drives everything from a
browser console: fire a payload at a WAF-protected virtual service or straight at
a backend, and watch, side by side, whether the request was blocked at the edge or
reached the vulnerable logger.

> **Isolated lab use only.** This project intentionally stands up software that is
> vulnerable to a known remote-code-execution bug. Run it only on a segment with no
> inbound exposure and no internet egress from the vulnerable hosts. See
> [Containment and responsible use](#containment-and-responsible-use).

## What it proves

The demo makes one point cleanly: an application can remain unpatched and still be
protected, because the WAF neutralizes the attack at the edge. Fire the same payload
two ways and the outcome flips:

- **Through the Avi virtual service (WAF enforcing):** HTTP 403, the backend never
  sees the request, and the verdict is green (blocked).
- **Straight at a backend (WAF out of the path):** HTTP 200 and the payload reaches
  the vulnerable logger, and the verdict is red (breach).

## How it works

The design is deliberately observe-only. It does **not** execute attacker-controlled
code. Instead of a real malicious LDAP/RCE payload, the range uses a **canary**: a
listener that does nothing but notice when a vulnerable backend performs the outbound
JNDI lookup that Log4Shell triggers.

Every fired payload embeds a unique correlation token in the JNDI string
(`${jndi:ldap://<canary>/<token>}`). When an unpatched backend parses it, it opens an
outbound connection to the canary, which records the token. The console then correlates
the HTTP result with the canary hit to decide the verdict. That outbound lookup is the
exact instant at which real code execution would occur, so "callback received" is a
faithful stand-in for "the exploit landed", without a working exploit ever existing in
the repo.

## Architecture

```
                              +-----------------------------+
  browser (operator) ------>  |  web-a-03c                   |
   https://console-vs         |  - operator console  :9090   |
                              |  - JNDI canary       :1389   |
                              +--------------+--------------+
                                             |  fires at
   Avi Virtual Service (WAF)                 |
   log4j.us-east.demo.lab ----- pool --------+
                                             |
                    +------------------------+------------------------+
                    |  web-a-03a  :8080       |  web-a-03b  :8080       |
                    |  vuln Log4j + proxy     |  vuln Log4j + proxy     |
                    |  (pool member)          |  (pool member)          |
                    +-------------------------+-------------------------+
                                 both call back to the canary on web-a-03c
```

- **web-a-03a / web-a-03b** each run the vulnerable Log4j app in Docker behind a tiny
  zero-dependency Node proxy on `:8080` (the Avi pool-member port). The proxy adds an
  `X-Served-By` header so the console can show which member Avi selected, and a
  `/healthz` endpoint for the Avi health monitor and the failover demo.
- **web-a-03c** runs the operator console, the fire API, and the JNDI canary. It is not
  a pool member, so it can reach the WAF virtual service without the traffic hairpinning
  through a backend.

All addresses above are examples; change them to match your lab in
`install/log4shell-demo.env`.

## Repository layout

```
control-plane/
  console-server.js     Operator console + fire API (zero-dependency Node). Runs on 03c.
  canary-listener.py    Observe-only JNDI canary (Python stdlib). Runs on 03c.
  fonts/                Bundled Metropolis web fonts (Unlicense), served locally.
node/
  node-proxy.js         Per-node front proxy: adds X-Served-By and /healthz. Both backends.
systemd/                Unit files for the proxy, canary, and console.
install/
  install-vuln-node.sh       Run on BOTH backends: vuln container + proxy + egress lockdown.
  install-control-plane.sh   Run on 03c: canary + console + fonts.
  fetch-metropolis.sh        Optional: re-download the fonts on an internet-connected host.
  log4shell-demo.env         Lab addresses and ports (installed to /etc/).
  cloud-init-03a.yaml        Fresh-provision OS layer for a backend.
  cloud-init-03b.yaml        Fresh-provision OS layer for the second backend.
RUNBOOK.md              Build order, Avi config, the demo click-path, containment.
```

## Prerequisites

- Three hosts running Ubuntu 22.04 LTS (two backends, one console). One backend is enough
  if you do not need the load-balancing story.
- A VMware Avi / NSX Advanced Load Balancer deployment where you can create a virtual
  service, a pool, and a WAF policy.
- An isolated lab network segment. The backends must not have internet egress.
- Docker is installed by the backend installer; Node.js and Python 3 by the installers.

## Quick start

Provision the hosts (optionally from the `cloud-init-*.yaml` files), copy this repo to
each, then:

```bash
# on BOTH backends (web-a-03a, web-a-03b)
sudo ./install/install-vuln-node.sh

# on the console host (web-a-03c)
sudo ./install/install-control-plane.sh
```

Edit `install/log4shell-demo.env` (or `/etc/log4shell-demo.env` after install) to match
your lab, then `sudo systemctl restart 'log4shell-*'`. Configure the Avi virtual service,
pool, and WAF policy as described in [RUNBOOK.md](RUNBOOK.md), then open the console at
`http://<console-host>:9090`.

## Using the console

Pick a target (the WAF-protected virtual service, or a backend directly), pick a payload
variant (a plain JNDI string or one of three obfuscated variants), and fire. The console
shows the HTTP result and the canary result together, animates the request path from the
console through the WAF to the pool, and records each fire in an event log. A light/dark
theme toggle and a draggable split between the diagram and the result panel are in the UI.

The obfuscated variants are useful for talking through WAF paranoia levels and signature
quality: the nested and dash-escape variants separate a real WAF from a naive regex. For
the virtual-patching close, keep the backends unpatched the whole time and let the WAF be
the only mitigating control. See [RUNBOOK.md](RUNBOOK.md) for the full click-path.

## Configuration

All runtime settings live in one file, `install/log4shell-demo.env` (installed to
`/etc/log4shell-demo.env`). Notable keys:

- `VS_URL` - the WAF-protected virtual service the console fires at.
- `NODE_A` / `NODE_B` - the backends the direct-fire buttons hit and the health panel polls.
- `CANARY_SINK` - the `host:port` embedded in every payload; must be the console host's
  address, reachable from both backends.
- `CONSOLE_PORT` - the port the console listens on.
- `FONT_DIR` - where the console serves the bundled fonts from (defaults to
  `/opt/log4shell-demo/fonts`).

Every service reads this file at startup, so restart after editing.

## Fonts

The console UI uses the Metropolis typeface, bundled under `control-plane/fonts/` and
served locally by the console over `/fonts/*.woff2`, so it works on an egress-locked host
with no internet or external font dependency. To refresh or re-fetch the fonts on an
internet-connected machine, run `install/fetch-metropolis.sh`.

## Containment and responsible use

This repository stands up software that is deliberately vulnerable to a known
remote-code-execution flaw. Use it responsibly:

- Run it only on an isolated lab segment. Do not expose the backends to the internet or to
  any production-adjacent network.
- Keep internet egress blocked from the backend hosts. The included installer restricts the
  vulnerable containers to the lab subnet; enforce the same at your router as the control
  of record.
- Only demonstrate against systems you own and are authorized to test.
- The vulnerable application is intentionally insecure. Stop or remove it when you are not
  actively running the demo.

By design, this project demonstrates **detection and blocking only**. It does not include,
and is not intended to be extended into, a working code-execution exploit chain. The canary
proves the payload reached the vulnerable logger without running any attacker-controlled
code.

## Credits and third-party components

- **Log4Shell** is CVE-2021-44228 in Apache Log4j.
- The vulnerable application is pulled at install time from
  `ghcr.io/christophetd/log4shell-vulnerable-app` (by Christophe Tafani-Dereeper). It is
  referenced, not redistributed, by this repo.
- The **Metropolis** typeface (by Chris Simpson) is released under the Unlicense (public
  domain) and packaged via Fontsource (https://fontsource.org/). The bundled `.woff2`
  files live in `control-plane/fonts/`.

See [NOTICE.md](NOTICE.md) for details.

## License

The code in this repository is released under the MIT License. See [LICENSE](LICENSE).
Third-party components retain their own licenses; see [NOTICE.md](NOTICE.md).
