from flask import Flask, request, abort, jsonify, render_template_string
import ipaddress
import os

app = Flask(__name__)

AVI_ALLOWED_SOURCES = os.getenv(
    "AVI_ALLOWED_SOURCES",
    "127.0.0.1/32,::1/128"
).split(",")


def source_is_allowed(remote_ip: str) -> bool:
    try:
        source = ipaddress.ip_address(remote_ip)
        return any(
            source in ipaddress.ip_network(cidr.strip(), strict=False)
            for cidr in AVI_ALLOWED_SOURCES
        )
    except ValueError:
        return False


def get_display_name(remote_user: str) -> str:
    if not remote_user or "@" not in remote_user:
        return "Authenticated User"

    username = remote_user.split("@")[0]
    return username.replace(".", " ").replace("_", " ").title()


def extract_dn_value(subject: str, key: str) -> str:
    if not subject:
        return ""

    parts = [p.strip() for p in subject.split(",")]
    prefix = f"{key}="

    for part in parts:
        if part.upper().startswith(prefix.upper()):
            return part[len(prefix):].strip()

    return ""


@app.before_request
def enforce_avi_and_cac_headers():
    if request.path == "/health":
        return

    remote_ip = request.remote_addr

    if not source_is_allowed(remote_ip):
        abort(403, description=f"Direct access denied. Source {remote_ip} is not trusted.")

    auth_status = request.headers.get("X-Avi-Client-Cert-Auth", "")
    remote_user = request.headers.get("X-Remote-User", "")

    if auth_status != "SUCCESS":
        abort(403, description="CAC/client certificate authentication was not successful.")

    if remote_user == "":
        abort(403, description="No authenticated remote user was supplied by Avi.")


@app.route("/")
def index():
    remote_user = request.headers.get("X-Remote-User", "")
    display_name = get_display_name(remote_user)

    subject = request.headers.get("X-Avi-Client-Cert-Subject", "")
    issuer = request.headers.get("X-Avi-Client-Cert-Issuer", "")
    cn = request.headers.get("X-Avi-Client-Cert-CN", "")
    edipi = request.headers.get("X-Avi-Client-Cert-EDIPI", "")

    organization = extract_dn_value(subject, "O") or "Unknown"
    affiliation = extract_dn_value(subject, "OU") or "Unknown"
    country = extract_dn_value(subject, "C") or "Unknown"

    client_ip = request.headers.get("X-Forwarded-For", request.remote_addr).split(",")[0].strip()
    avi_se_ip = request.headers.get("X-Avi-Service-Engine-IP", "unknown")
    backend_node = request.headers.get("X-Backend-Node", "unknown")
    backend_ip = request.headers.get("X-Backend-Server-IP", "unknown")

    return render_template_string("""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Avi Secure Access Portal</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">

  <style>
    :root {
      --navy: #061923;
      --navy-2: #0b2d3c;
      --blue: #0072a3;
      --blue-2: #0098c9;
      --green: #2f8a3c;
      --gold: #c9962c;
      --bg: #eef3f7;
      --card: #ffffff;
      --border: #d7e2ea;
      --muted: #6b7c86;
      --text: #142832;
      --soft-blue: #e8f6fb;
      --soft-green: #eaf7ed;
      --shadow: 0 8px 28px rgba(10, 35, 50, 0.08);
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      font-family: "Segoe UI", Roboto, Arial, sans-serif;
      background:
        radial-gradient(circle at top left, rgba(0, 114, 163, .16), transparent 30%),
        linear-gradient(180deg, #f6f9fb 0%, var(--bg) 100%);
      color: var(--text);
    }

    .topbar {
      height: 64px;
      background: linear-gradient(90deg, var(--navy), var(--navy-2));
      color: white;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 34px;
      box-shadow: 0 2px 10px rgba(0,0,0,.22);
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
      font-weight: 650;
      letter-spacing: .2px;
      font-size: 18px;
    }

    .brand-mark {
      width: 34px;
      height: 34px;
      border-radius: 8px;
      background: linear-gradient(135deg, var(--blue), var(--blue-2));
      display: grid;
      place-items: center;
      font-weight: 800;
      box-shadow: inset 0 0 0 1px rgba(255,255,255,.25);
    }

    .tenant {
      color: #b8d7e5;
      font-size: 13px;
    }

    .layout {
      max-width: 1240px;
      margin: 30px auto 36px;
      padding: 0 24px;
    }

    .hero {
      background: linear-gradient(135deg, #ffffff 0%, #f7fbfd 100%);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 30px 32px;
      box-shadow: var(--shadow);
      margin-bottom: 22px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 28px;
    }

    .hero h1 {
      margin: 0 0 8px;
      font-size: 32px;
      font-weight: 700;
      letter-spacing: -.4px;
    }

    .hero p {
      margin: 0;
      color: var(--muted);
      font-size: 15px;
      line-height: 1.5;
    }

    .verified-pill {
      display: inline-flex;
      align-items: center;
      gap: 9px;
      background: var(--soft-green);
      color: var(--green);
      border: 1px solid #bfe8c8;
      padding: 11px 14px;
      border-radius: 999px;
      font-weight: 700;
      white-space: nowrap;
    }

    .dot {
      width: 10px;
      height: 10px;
      background: var(--green);
      border-radius: 50%;
      box-shadow: 0 0 0 5px rgba(47,138,60,.12);
    }

    .trust-grid {
      display: grid;
      grid-template-columns: 1.1fr 1.1fr 1.8fr;
      gap: 18px;
      margin-bottom: 18px;
    }

    .path-grid {
      display: grid;
      grid-template-columns: 1fr 1fr 1.5fr;
      gap: 18px;
      margin-bottom: 24px;
    }

    .metric-card {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 18px 18px;
      box-shadow: var(--shadow);
      min-height: 104px;
      display: flex;
      flex-direction: column;
      justify-content: center;
    }

    .metric-label {
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: .7px;
      margin-bottom: 9px;
      font-weight: 700;
    }

    .metric-value {
      font-size: 18px;
      font-weight: 700;
      overflow-wrap: anywhere;
      line-height: 1.3;
    }

    .metric-sub {
      margin-top: 6px;
      color: var(--muted);
      font-size: 13px;
      overflow-wrap: anywhere;
    }

    .success { color: var(--green); }

    .main-grid {
      display: grid;
      grid-template-columns: .95fr 1.45fr;
      gap: 22px;
      align-items: start;
    }

    .panel {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 16px;
      box-shadow: var(--shadow);
      overflow: hidden;
    }

    .panel-header {
      padding: 17px 20px;
      border-bottom: 1px solid var(--border);
      background: #fbfdfe;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      font-weight: 750;
    }

    .panel-kicker {
      font-size: 12px;
      color: var(--muted);
      text-transform: uppercase;
      letter-spacing: .7px;
      font-weight: 700;
    }

    .panel-body { padding: 20px; }

    .identity-card {
      background: linear-gradient(135deg, var(--soft-blue), #f4fbfe);
      border: 1px solid #cce8f3;
      border-left: 5px solid var(--blue);
      padding: 18px;
      border-radius: 12px;
      margin-bottom: 18px;
    }

    .identity-name {
      font-size: 25px;
      font-weight: 750;
      margin-bottom: 5px;
    }

    .identity-upn {
      color: var(--muted);
      font-size: 14px;
    }

    .attribute-grid {
      display: grid;
      grid-template-columns: 1fr;
      gap: 12px;
    }

    .attribute {
      border: 1px solid var(--border);
      border-radius: 11px;
      padding: 13px 14px;
      background: #fff;
    }

    .attribute-label {
      color: var(--muted);
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: .65px;
      margin-bottom: 6px;
      font-weight: 750;
    }

    .attribute-value {
      font-size: 15px;
      font-weight: 600;
      overflow-wrap: anywhere;
    }

    .flow {
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 12px;
      margin-bottom: 18px;
    }

    .flow-step {
      background: #ffffff;
      border: 1px solid var(--border);
      border-radius: 13px;
      padding: 14px;
      position: relative;
      min-height: 112px;
    }

    .flow-step:not(:last-child)::after {
      content: "→";
      position: absolute;
      right: -13px;
      top: 39px;
      color: var(--blue);
      font-weight: 900;
      font-size: 18px;
      z-index: 2;
    }

    .flow-title {
      font-weight: 750;
      margin-bottom: 7px;
      font-size: 14px;
    }

    .flow-sub {
      color: var(--muted);
      font-size: 12px;
      line-height: 1.4;
      overflow-wrap: anywhere;
    }

    .cert-list {
      display: flex;
      flex-direction: column;
      gap: 12px;
    }

    .cert-item {
      border: 1px solid var(--border);
      border-radius: 13px;
      padding: 15px;
      background: #ffffff;
    }

    .cert-title {
      font-weight: 750;
      margin-bottom: 5px;
    }

    .cert-subtitle {
      color: var(--muted);
      font-size: 13px;
      margin-bottom: 10px;
    }

    code {
      background: #eef3f6;
      border: 1px solid #d8e1e8;
      border-radius: 6px;
      padding: 4px 7px;
      font-family: Consolas, Monaco, monospace;
      font-size: 12.5px;
      overflow-wrap: anywhere;
      line-height: 1.8;
    }

    .footer {
      margin-top: 24px;
      color: var(--muted);
      font-size: 12px;
      text-align: center;
    }

    @media (max-width: 1000px) {
      .hero { flex-direction: column; align-items: flex-start; }
      .trust-grid, .path-grid, .main-grid, .flow {
        grid-template-columns: 1fr;
      }
      .flow-step::after { display: none; }
    }
  </style>
</head>

<body>
  <div class="topbar">
    <div class="brand">
      <div class="brand-mark">A</div>
      <div>Avi Secure Access Portal</div>
    </div>
    <div class="tenant">demo.lab · CAC Header Assertion</div>
  </div>

  <main class="layout">
    <section class="hero">
      <div>
        <h1>Certificate-Based Access Granted</h1>
        <p>
          Avi validated the client certificate, asserted identity through trusted headers,
          and forwarded the request through a controlled backend path.
        </p>
      </div>
      <div class="verified-pill">
        <span class="dot"></span>
        Validated by Avi PKI
      </div>
    </section>

    <section class="trust-grid">
      <div class="metric-card">
        <div class="metric-label">Authentication</div>
        <div class="metric-value success">Validated</div>
        <div class="metric-sub">Client certificate accepted</div>
      </div>

      <div class="metric-card">
        <div class="metric-label">Access Model</div>
        <div class="metric-value">CAC Header Assertion</div>
        <div class="metric-sub">Reverse proxy identity trust</div>
      </div>

      <div class="metric-card">
        <div class="metric-label">Authenticated Session</div>
        <div class="metric-value">{{ remote_user }}</div>
        <div class="metric-sub">{{ display_name }}</div>
      </div>
    </section>

    <section class="path-grid">
      <div class="metric-card">
        <div class="metric-label">Client Source</div>
        <div class="metric-value">{{ client_ip }}</div>
        <div class="metric-sub">Browser endpoint</div>
      </div>

      <div class="metric-card">
        <div class="metric-label">Avi Service Engine</div>
        <div class="metric-value">{{ avi_se_ip }}</div>
        <div class="metric-sub">TLS and cert enforcement point</div>
      </div>

      <div class="metric-card">
        <div class="metric-label">Backend Processing Node</div>
        <div class="metric-value">{{ backend_node }}</div>
        <div class="metric-sub">{{ backend_ip }}</div>
      </div>
    </section>

    <section class="main-grid">
      <div class="panel">
        <div class="panel-header">
          <span>Identity Profile</span>
          <span class="panel-kicker">CAC User</span>
        </div>

        <div class="panel-body">
          <div class="identity-card">
            <div class="identity-name">{{ display_name }}</div>
            <div class="identity-upn">{{ remote_user }}</div>
          </div>

          <div class="attribute-grid">
            <div class="attribute">
              <div class="attribute-label">Role</div>
              <div class="attribute-value">Authenticated CAC User</div>
            </div>

            <div class="attribute">
              <div class="attribute-label">Organization</div>
              <div class="attribute-value">{{ organization }}</div>
            </div>

            <div class="attribute">
              <div class="attribute-label">Affiliation</div>
              <div class="attribute-value">{{ affiliation }}</div>
            </div>

            <div class="attribute">
              <div class="attribute-label">Country</div>
              <div class="attribute-value">{{ country }}</div>
            </div>

            <div class="attribute">
              <div class="attribute-label">Certificate CN</div>
              <div class="attribute-value"><code>{{ cn }}</code></div>
            </div>

            <div class="attribute">
              <div class="attribute-label">EDIPI / Identifier</div>
              <div class="attribute-value"><code>{{ edipi }}</code></div>
            </div>
          </div>
        </div>
      </div>

      <div class="panel">
        <div class="panel-header">
          <span>Access Decision and Request Path</span>
          <span class="panel-kicker">Trusted Path</span>
        </div>

        <div class="panel-body">
          <div class="flow">
            <div class="flow-step">
              <div class="flow-title">Client</div>
              <div class="flow-sub">{{ client_ip }}<br>Certificate presented by browser</div>
            </div>

            <div class="flow-step">
              <div class="flow-title">Avi Validation</div>
              <div class="flow-sub">{{ avi_se_ip }}<br>PKI profile validates trust</div>
            </div>

            <div class="flow-step">
              <div class="flow-title">Header Assertion</div>
              <div class="flow-sub">X-Remote-User<br>{{ remote_user }}</div>
            </div>

            <div class="flow-step">
              <div class="flow-title">Backend App</div>
              <div class="flow-sub">{{ backend_node }}<br>{{ backend_ip }}</div>
            </div>
          </div>

          <div class="cert-list">
            <div class="cert-item">
              <div class="cert-title">Certificate Subject</div>
              <div class="cert-subtitle">Identity attributes forwarded by Avi</div>
              <code>{{ subject }}</code>
            </div>

            <div class="cert-item">
              <div class="cert-title">Certificate Issuer</div>
              <div class="cert-subtitle">Trusted CA chain configured in Avi PKI profile</div>
              <code>{{ issuer }}</code>
            </div>

            <div class="cert-item">
              <div class="cert-title">Trusted Headers Received by Application</div>
              <div class="cert-subtitle">Backend consumes identity asserted by Avi</div>
              <code>X-Avi-Client-Cert-Auth: SUCCESS</code><br>
              <code>X-Remote-User: {{ remote_user }}</code><br>
              <code>X-Avi-Client-Cert-CN: {{ cn }}</code><br>
              <code>X-Avi-Client-Cert-EDIPI: {{ edipi }}</code>
            </div>
          </div>
        </div>
      </div>
    </section>

    <div class="footer">
      Backend bypass protection: NGINX accepts only Avi Service Engine traffic, while Flask trusts only local proxy traffic and Avi-authenticated identity headers.
    </div>
  </main>
</body>
</html>
    """,
    remote_user=remote_user,
    display_name=display_name,
    subject=subject,
    issuer=issuer,
    cn=cn,
    edipi=edipi,
    organization=organization,
    affiliation=affiliation,
    country=country,
    client_ip=client_ip,
    avi_se_ip=avi_se_ip,
    backend_node=backend_node,
    backend_ip=backend_ip)


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
