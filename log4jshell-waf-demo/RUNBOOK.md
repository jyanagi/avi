# Avi WAF Log4Shell Range — Runbook

A self-contained, closed-loop Log4Shell (CVE-2021-44228) demonstration on two
Ubuntu 22.04 servers, load balanced by an Avi virtual service with WAF policy.
The operator drives everything from a browser console. No payload class is ever
served or executed; the demo proves detection and blocking via an observe-only
JNDI canary.

## Topology

```
                              +-----------------------------+
  browser (SE)  ───────────►  |  web-a-03a  10.15.148.84     |
   http://10.15.148.84:9090   |  - operator console  :9090   |
                              |  - JNDI canary       :1389   |
                              |  - vuln node (proxy) :8080   |
                              +--------------┬--------------+
                                             │  pool member
   Avi Virtual Service                       │
   log4j.us-east.demo.lab (WAF) ──────── pool ─────────┤
                                             │  pool member
                              +--------------┴--------------+
                              |  web-a-03b  10.15.148.85     |
                              |  - vuln node (proxy) :8080   |
                              +-----------------------------+
```

- Both nodes run the vulnerable Log4j app in Docker on `127.0.0.1:8081`, fronted
  by a zero-dependency Node proxy on `:8080` (the pool-member port) that stamps
  `X-Served-By` so the console can show which member Avi selected.
- Every payload embeds `${jndi:ldap://10.15.148.84:1389/<token>}`. The canary on
  03a records any callback with its correlation token, so the console can tie a
  specific request to a specific callback.
- The console fires at a node directly (WAF out of path) or at the VS (WAF in
  path). Direct-vs-VS is functionally your WAF-off / WAF-on switch.

## Build order

1. Provision both VMs from `install/cloud-init-03a.yaml` and `-03b.yaml`
   (adjust the interface name if not `ens160`).
2. Copy this package to `/root/log4shell-waf-demo` on each box.
3. On BOTH nodes: `sudo ./install/install-vuln-node.sh`
4. On 03a only: `sudo ./install/install-control-plane.sh`
5. Open `http://10.15.148.84:9090`. The two node dots at the bottom should go
   green once health checks pass.

Edit `/etc/log4shell-demo.env` to change any lab address, then
`sudo systemctl restart 'log4shell-*'`.

## Containment

- The installer applies DOCKER-USER rules so each vulnerable container can reach
  only `10.15.148.0/24` (enough for the canary) and nothing on the internet.
- Put the primary control on the VyOS router: deny internet-bound traffic
  sourced from `.84` and `.85`. Docker rewrites host iptables, so the router is
  the durable enforcement point; the DOCKER-USER rules are defense in depth.
- Payloads only ever reference the RFC1918 canary. Nothing leaves the segment.
- Idle the targets between demos with `docker stop vuln-app` on each node; the
  console will show that node as down.

## Avi configuration

1. **Pool** `log4shell-pool` with members `10.15.148.84:8080` and
   `10.15.148.85:8080`. Health monitor: HTTP GET `/healthz` expecting 200.
2. **Virtual service** `log4j.us-east.demo.lab` fronting that pool, SSL terminated with the
   internal DemoRootCA SAN cert (covered by the `*.us-east.demo.lab` SAN entry).
3. **WAF policy** attached to the VS. Confirm application signatures / CRS ruleset
   are updated so Log4Shell rules are present. Start in detection mode to show the
   breach, then flip to enforcement to show the block.
4. Optional realism: path-based routing so a branded landing page serves `/` and
   only the API path routes to the pool. Keep whatever path the console fires at
   routed to the pool so the header still reaches the logger.

## The demo (click-path)

1. **Baseline — WAF out of path.** Target = *Direct to web-a-03a*, variant =
   *Plain JNDI*, Fire. Result: HTTP 200, canary MATCH, verdict **breach**. The
   causation path animates the callback returning to the canary. This proves the
   backend is genuinely vulnerable.
2. **Enforcement — WAF in path.** Target = *Through Avi VS*, same variant, Fire.
   Result: HTTP 403, canary silent, verdict **blocked**. The request never
   reached the pool. Show the matching entry in the Avi WAF logs.
3. **Obfuscation depth.** Cycle the three obfuscated variants through the VS.
   Use them to talk through paranoia level and signature quality: the nested and
   dash-escape variants are what separate a real WAF from a naive regex.
4. **Load balancing.** Fire several times through the VS with the WAF in
   detection mode and watch `X-Served-By` alternate between 03a and 03b — the WAF
   protects the whole pool regardless of which member is selected.
5. **Failover.** `docker stop vuln-app` on 03a. The console marks 03a down and
   subsequent VS fires are served by 03b, uninterrupted.

## Virtual-patching close (the sales moment)

Neither backend is ever patched. The Log4j version stays 2.14.1 on both nodes the
entire demo, and the WAF is the sole mitigating control. Frame it plainly: you
cannot instantly patch every app in the fleet, but the WAF closes the exposure at
the edge the moment the signature ships, across every pool member at once. To make
it concrete, add a custom WAF rule that matches the JNDI pattern and show it
holding even with the built-in Log4Shell signatures disabled.

## Reset / teardown

- Clear the event history: `: > /var/lib/log4shell-demo/callbacks.jsonl`
- Stop everything: `sudo systemctl stop 'log4shell-*'` and
  `docker stop vuln-app` on each node.
- Full removal: `docker rm -f vuln-app`, delete the systemd units and
  `/opt/log4shell-demo`.

## Extending to other CVEs

The console's payload table (`VARIANTS` in `console-server.js`) and the canary
are the only Log4Shell-specific parts. Spring4Shell, Text4Shell, and the
Confluence OGNL injection all have recognizable request signatures and can be
added as new variants against an appropriate vulnerable container, reusing the
same fire/verdict machinery.
