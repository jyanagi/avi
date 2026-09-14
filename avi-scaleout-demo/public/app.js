const $ = (id) => document.getElementById(id),
  names = [
    "Baseline",
    "Load ramp",
    "Threshold crossed",
    "SE scale-out",
    "Stabilization",
    "Scale-in / reset",
  ];
let catalog = [],
  selected,
  runId,
  pollTimer,
  loadTimer,
  seconds = 0,
  previousSE = 0,
  baselineSE = 0,
  initialGroupSE = 0,
  currentPhase = 0,
  scaleAt = 0,
  stableAt = 0,
  pollBusy = false,
  autoReset = 30,
  autoStopping = false,
  scaleInLogged = false,
  lastLog = 0,
  targetLogged = false;
const announced = new Set();
const knownSeIds = new Set(),
  createdSeIds = new Set();
let SCALEIN_QUIET_MS = 90000,
  scaleInPending = false,
  scaleInQuietSince = 0,
  scaleInSent = false,
  baselinePolls = 0,
  demoStartedAt = Date.now();
function rail(n = 0) {
  $("phases").innerHTML = names
    .map(
      (x, i) =>
        `<button class="${i === n ? "active" : ""} ${i < n ? "done" : ""}"><small>PHASE 0${i + 1}</small><span>${x}</span></button>`,
    )
    .join("");
}
const stamp = () =>
  new Date(Date.now() - demoStartedAt).toISOString().slice(11, 19);
function log(t, c = "") {
  let p = document.createElement("span"),
    box = $("console");
  p.className = c;
  p.textContent = `${stamp()}  ${t}\n`;
  box.insertBefore(p, box.querySelector(".cursor"));
  box.scrollTop = box.scrollHeight;
}
function phase(i, t, o) {
  currentPhase = i;
  rail(i);
  $("kicker").textContent = `PHASE 0${i + 1}`;
  $("phaseTitle").textContent = t;
  $("outcome").textContent = o;
  $("state").textContent = i ? "Running" : "Monitoring";
  $("state").className = "running";
}
function drawLinks() {
  let root = document.querySelector(".topology"),
    svg = $("links"),
    a = document.querySelector(".node.client"),
    v = $("vipNode"),
    ses = [...document.querySelectorAll("#seNodes .se-dynamic")],
    p = $("poolNode"),
    servers = [...document.querySelectorAll("#serverNodes .server-dynamic")];
  if (!root || !a || !v) return;
  let rr = root.getBoundingClientRect(),
    pt = (e, s) => {
      let r = e.getBoundingClientRect();
      return {
        x: (s === "right" ? r.right : r.left) - rr.left,
        y: r.top - rr.top + r.height / 2,
      };
    },
    ln = (a, b) =>
      `<line class="link active" x1="${a.x}" y1="${a.y}" x2="${b.x}" y2="${b.y}"/>`;
  svg.setAttribute("viewBox", `0 0 ${rr.width} ${rr.height}`);
  let h =
    ln(pt(a, "right"), pt(v, "left")) +
    ses.map((e) => ln(pt(v, "right"), pt(e, "left"))).join("");
  if (p && !p.classList.contains("off"))
    h +=
      ses.map((e) => ln(pt(e, "right"), pt(p, "left"))).join("") +
      servers.map((e) => ln(pt(p, "right"), pt(e, "left"))).join("");
  svg.innerHTML = h;
}
function renderBackend(s) {
  let p = (s.pools || [])[0];
  if (!p) {
    $("poolNode").classList.add("off");
    $("serverNodes").innerHTML = "";
    return drawLinks();
  }
  $("poolNode").classList.remove("off");
  $("poolLabel").textContent = p.name;
  $("poolSub").textContent = `Backend pool · ${p.servers.length} servers`;
  let n = p.servers.length;
  $("serverNodes").innerHTML = p.servers
    .map((x, i) => {
      let d = `Server: ${x.name}\nIP: ${x.ip || "Not configured"}\nService port: ${x.port}`,
        top = n < 2 ? 50 : 18 + (i * 64) / (n - 1);
      return `<div class="node server-dynamic" style="top:${top}%" tabindex="0" data-tooltip="${d}">▤ <strong>${x.name}</strong><small>${x.enabled ? "enabled" : "disabled"} · port ${x.port}</small></div>`;
    })
    .join("");
  requestAnimationFrame(drawLinks);
}
function renderSE(es, n) {
  n = Math.max(0, Math.round(n || es.length));
  if (!runId && !currentPhase && n && !baselineSE) {
    baselineSE = n;
    log(`VIP baseline: ${n} Service Engines supporting the VIP`);
  }
  if (n === previousSE && $("seNodes").children.length) {
    [...$("seNodes").children].forEach((node, i) => {
      const e = es[i] || {},
        name = e.name || `Service Engine ${i + 1}`,
        status = e.status || "active",
        details = `Service Engine: ${name}\nStatus: ${status}\nRole: supporting VIP`;
      node.dataset.tooltip = details;
      node.setAttribute("aria-label", details.replaceAll("\n", ", "));
      node.classList.toggle("new", !!e.uuid && createdSeIds.has(e.uuid));
    });
    return drawLinks();
  }
  let old = previousSE;
  previousSE = n;
  $("seNodes").innerHTML = Array.from({ length: n }, (_, i) => {
    let e = es[i] || {},
      top = n < 2 ? 50 : 18 + (i * 64) / (n - 1),
      name = e.name || `Service Engine ${i + 1}`,
      status = e.status || "active",
      details = `Service Engine: ${name}\nStatus: ${status}\nRole: supporting VIP`,
      isNew = !!e.uuid && createdSeIds.has(e.uuid);
    return `<div class="node se-dynamic ${isNew ? "new" : ""}" style="top:${top}%" tabindex="0" aria-label="${details.replaceAll("\n", ", ")}" data-tooltip="${details.replaceAll('"', "&quot;")}">▣ <strong>Service Engine ${i + 1}</strong><small>${status} · supporting VIP</small></div>`;
  }).join("");
  requestAnimationFrame(drawLinks);
  if (old && n > old && currentPhase < 5) {
    scaleAt = Date.now();
    phase(
      3,
      "Avi is scaling out",
      `${n - old} additional Service Engine joined the selected VIP.`,
    );
    log(`SCALE-OUT DETECTED: ${old} → ${n} SEs supporting the VIP`, "success");
  } else if (old && n < old && currentPhase === 5) {
    log(`SCALE-IN DETECTED: ${old} → ${n} SEs supporting the VIP`, "success");
  }
}
async function stop(auto = false) {
  let scaleIn = baselineSE && previousSE > baselineSE;
  if (runId) {
    await json("/api/load/stop/" + runId, { method: "POST" }).catch(() => {});
    log(
      auto
        ? "Automatic reset: stabilization complete; connections released"
        : "Load stopped; connections closed",
      auto ? "success" : "",
    );
    runId = null;
  }
  clearInterval(loadTimer);
  $("start").disabled = !selected;
  $("loadNode").textContent = "idle";
  scaleInPending = !!scaleIn;
  scaleInQuietSince = 0;
  scaleInSent = false;
  baselinePolls = 0;
  phase(
    5,
    "Scale-in / reset in progress",
    scaleIn
      ? "Connections are closed. Waiting for connection pressure to clear before scale-in."
      : "Connections are closed. Confirming baseline placement.",
  );
}
function metrics(m) {
  $("connections").textContent = Math.round(m.connections).toLocaleString();
  $("cpu").textContent = Number.isFinite(m.cpu) ? m.cpu.toFixed(1) + "%" : "—";
  $("throughput").textContent = m.bandwidth
    ? (m.bandwidth / 1e6).toFixed(1) + " Mbps"
    : "0 Mbps";
  $("pps").textContent = Math.round(m.pps || m.cps || 0).toLocaleString();
  $("headroom").textContent = `${m.seCount || 0} active Service Engines`;
  if (runId && currentPhase >= 2 && (m.groupSeCount || 0) > initialGroupSE)
    for (let e of m.provisioningEngines || [])
      if (!announced.has(e.uuid)) {
        announced.add(e.uuid);
        phase(
          2,
          "Additional Service Engine provisioning",
          `${e.name} is preparing to support the selected VIP.`,
        );
        log(
          `PROVISIONING DETECTED: ${e.name} (${e.status}) created in Scaleout-SEG`,
          "warn",
        );
      }
  renderSE(m.engines || [], m.seCount);
  if (currentPhase === 5) {
    if (!scaleInLogged && baselineSE && previousSE <= baselineSE) {
      scaleInLogged = true;
      $("phaseTitle").textContent = "Reset complete";
      $("outcome").textContent =
        `VIP placement returned to ${baselineSE} Service Engines.`;
      log("RESET COMPLETE: baseline VIP placement restored", "success");
    }
    return;
  }
  if (previousSE >= 3) {
    if (currentPhase === 3 && Date.now() - scaleAt >= 30000) {
      stableAt = Date.now();
      phase(
        4,
        "Scale-out stabilized",
        `Three Service Engines are active. Load resets in ${autoReset} seconds.`,
      );
      log("Stabilization complete", "success");
    } else if (
      currentPhase === 4 &&
      runId &&
      autoReset > 0 &&
      !autoStopping &&
      Date.now() - stableAt >= autoReset * 1000
    ) {
      autoStopping = true;
      stop(true);
    }
    return;
  }
  if (runId && m.connections > 0) {
    let t = +$("max").value;
    if (m.connections >= t * 0.7 && currentPhase < 3)
      phase(
        2,
        "Scale threshold pressure reached",
        "Avi is evaluating capacity from live connection metrics.",
      );
    else if (currentPhase < 2)
      phase(
        1,
        "Generating sustained connections",
        `${$("cps").value} new connections per second target the VIP.`,
      );
  }
}
async function phase6ScaleIn(m) {
  if (currentPhase !== 5) return;
  baselinePolls =
    baselineSE && previousSE <= baselineSE ? baselinePolls + 1 : 0;
  if ((m.connections || 0) > 5) {
    scaleInQuietSince = 0;
    $("outcome").textContent =
      "Waiting for Avi connection pressure to clear before scale-in.";
    return;
  }
  if (!scaleInQuietSince) {
    scaleInQuietSince = Date.now();
    $("outcome").textContent =
      "Connection pressure is clear. Observing a quiet period before scale-in.";
    return;
  }
  const remaining = Math.ceil(
    (SCALEIN_QUIET_MS - (Date.now() - scaleInQuietSince)) / 1000,
  );
  if (remaining > 0) {
    $("outcome").textContent =
      `Connection pressure is clear. Scale-in safety period: ${remaining} seconds remaining.`;
    return;
  }
  if (baselinePolls >= 3) {
    scaleInPending = false;
    $("phaseTitle").textContent = "Reset complete";
    $("outcome").textContent =
      `VIP placement is stable on ${baselineSE} Service Engines.`;
    $("state").textContent = "Ready";
    if (!scaleInLogged) {
      scaleInLogged = true;
      log("RESET COMPLETE: baseline VIP placement stable", "success");
    }
    return;
  }
  if (!scaleInPending || scaleInSent) return;
  scaleInSent = true;
  try {
    await json("/api/avi/scalein", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ uuid: selected.uuid }),
    });
    $("outcome").textContent =
      "Waiting for Avi to return to baseline placement.";
  } catch (e) {
    scaleInSent = false;
    scaleInPending = false;
    log(`Scale-in request failed: ${e.message}`, "warn");
    $("outcome").textContent =
      "Accelerated reset failed. Automatic rebalance remains active.";
  }
}
const renderMetrics = metrics;
metrics = function (m) {
  const observed = [
    ...(m.engines || []),
    ...(m.provisioningEngines || []),
  ].filter((e) => e.uuid);
  if (!runId) {
    knownSeIds.clear();
    observed.forEach((e) => knownSeIds.add(e.uuid));
  } else {
    for (const e of observed) {
      if (!knownSeIds.has(e.uuid)) {
        knownSeIds.add(e.uuid);
        createdSeIds.add(e.uuid);
        announced.add(e.uuid);
        phase(
          2,
          "Additional Service Engine provisioning",
          `${e.name} is preparing to support the selected VIP.`,
        );
        log(
          `PROVISIONING DETECTED: ${e.name} (${e.status || "provisioning"}) created in Scaleout-SEG`,
          "warn",
        );
      }
    }
  }
  initialGroupSE = Math.max(initialGroupSE, m.groupSeCount || 0);
  const phaseBefore = currentPhase;
  renderMetrics(m);
  if (phaseBefore === 5 && currentPhase !== 5)
    phase(
      5,
      "Scale-in / reset in progress",
      "Confirming stable baseline placement.",
    );
  phase6ScaleIn(m);
};
async function json(u, o = {}) {
  let r = await fetch(u, {
      cache: "no-store",
      credentials: "same-origin",
      ...o,
      headers: { Accept: "application/json", ...(o.headers || {}) },
    }),
    body = await r.text(),
    d;
  try {
    d = body ? JSON.parse(body) : {};
  } catch {
    let kind = /^\s*</.test(body) ? "HTML" : "non-JSON";
    throw Error(`${kind} response from demo endpoint (HTTP ${r.status})`);
  }
  if (!r.ok) throw Error(d.error || `HTTP ${r.status}`);
  if (u === "/api/avi/discover" && d.demo?.scaleInQuietSeconds)
    SCALEIN_QUIET_MS = d.demo.scaleInQuietSeconds * 1000;
  return d;
}
async function discover() {
  try {
    let d = await json("/api/avi/discover");
    catalog = d.virtualServices;
    initialGroupSE = d.seg.current || 0;
    autoReset = d.demo?.autoResetSeconds ?? 30;
    $("segLabel").textContent =
      `${d.seg.name} · ${d.seg.min}–${d.seg.max} SEs · ${d.seg.vcpus} vCPU · ${Math.round(d.seg.memoryMb / 1024)} GB`;
    $("vs").innerHTML = catalog
      .map(
        (v, i) =>
          `<option value="${i}">${v.name} · ${v.fqdn || v.vip}</option>`,
      )
      .join("");
    $("controllerState").textContent = "● Avi connected";
    $("console").innerHTML = '<span class="cursor"> </span>';
    log(`Connected to Avi ${d.apiVersion} at ${d.controller}`, "success");
    log(`SEG inventory: ${initialGroupSE} Service Engines available`);
    $("start").disabled = !catalog.length;
    selectVS(0);
  } catch (e) {
    $("controllerState").textContent = "● Connection failed";
    $("console").innerHTML = '<span class="cursor"> </span>';
    log(e.message, "warn");
  }
}
function selectVS(i) {
  selected = catalog[i];
  if (!selected) return;
  $("vipLabel").textContent = selected.name;
  $("vipSub").textContent = [selected.fqdn, selected.vip]
    .filter(Boolean)
    .join(" · ");
  let d = `Virtual Service: ${selected.name}\nVIP: ${selected.vip || "Not configured"}\nDNS: ${selected.fqdn || "Not configured"}\nPort: ${selected.port}`;
  $("vipNode").dataset.tooltip = d;
  renderBackend(selected);
  previousSE = baselineSE = 0;
  poll();
  clearInterval(pollTimer);
  pollTimer = setInterval(poll, 10000);
}
async function poll() {
  if (!selected || pollBusy) return;
  pollBusy = true;
  try {
    let data,
      url = "/api/avi/live/" + selected.uuid;
    try {
      data = await json(url);
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      data = await json(url);
    }
    metrics(data);
    $("controllerState").textContent = "● Avi connected";
  } catch (e) {
    $("controllerState").textContent = "● Telemetry delayed";
    log("Telemetry delayed: " + e.message, "warn");
  } finally {
    pollBusy = false;
  }
}
async function start() {
  if (!selected || runId) return;
  if (!knownSeIds.size) {
    await poll();
    if (!knownSeIds.size)
      throw new Error(
        "Waiting for the initial Service Engine inventory; try again after the next telemetry update.",
      );
  }
  let host = selected.fqdn || selected.vip,
    d = await json("/api/load/start", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        host,
        port: selected.port,
        tls: selected.tls,
        protocol: "tcp",
        cps: +$("cps").value,
        maxConnections: +$("max").value,
      }),
    });
  runId = d.id;
  seconds = lastLog = 0;
  targetLogged = autoStopping = scaleInLogged = false;
  announced.clear();
  createdSeIds.clear();
  initialGroupSE = Math.max(initialGroupSE, previousSE);
  loadTimer = setInterval(status, 1000);
  $("start").disabled = true;
  phase(
    1,
    "Generating sustained connections",
    `Connections are opening against ${host}:${selected.port}.`,
  );
  log(`Load started → ${host}:${selected.port}`);
}
async function status() {
  seconds++;
  if (!runId) return;
  let s = await json("/api/load/status/" + runId);
  $("loadNode").textContent =
    `${s.active.toLocaleString()} held · ${s.pending || 0} pending · ${s.failed} failed`;
  if (seconds - lastLog >= 5) {
    lastLog = seconds;
    log(
      `Load progress: ${s.active} active · ${s.pending || 0} pending · ${s.failed} failed`,
    );
  }
  if (s.active >= s.max && !targetLogged) {
    targetLogged = true;
    log(`Target reached: ${s.active} active connections held`, "success");
  }
}
$("vs").onchange = (e) => selectVS(+e.target.value);
$("start").onclick = () => start().catch((e) => log(e.message, "warn"));
$("reset").onclick = () => stop(false);
$("theme").onclick = () => {
  document.body.classList.toggle("dark");
  requestAnimationFrame(drawLinks);
};
new ResizeObserver(drawLinks).observe(document.querySelector(".topology"));
rail();
discover();
