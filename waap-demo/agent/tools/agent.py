#!/usr/bin/env python3
"""
ACME MCP demo agent / driver.

Python standard library only. Drives the four demo scenes against the Avi VIP.
Talks real MCP streamable-HTTP and real OpenAI-style chat completions, and
performs RFC 9728 discovery + Keycloak token acquisition exactly as a
compliant agent would.

Usage:
  export AVI_MCP=https://mcp.us-east.demo.lab          # the Avi MCP virtual service
  export AVI_LLM=https://llm.us-east.demo.lab          # the Avi inference virtual service
  export KC=https://keycloak.demo.lab:8443          # Keycloak base URL
  export KC_REALM=acme-ai

  ./agent.py discover                          # scene 1: RFC 9728 flow
  ./agent.py token --tier catalog              # get a token for a tier
  ./agent.py call --tier catalog --tool inventory.lookup --args '{"sku":"SKU-4411"}'
  ./agent.py scene-authz                       # scene 3: least privilege
  ./agent.py scene-session                     # scene 4: persistence under failure
  ./agent.py chat "what is the inventory for SKU-4411"
"""

import argparse
import json
import os
import ssl
import sys
import urllib.request
import urllib.error
import urllib.parse

MCP = os.environ.get('AVI_MCP', 'https://mcp.us-east.demo.lab')
LLM = os.environ.get('AVI_LLM', 'https://llm.us-east.demo.lab')
KC = os.environ.get('KC', 'https://keycloak.demo.lab:8443')
REALM = os.environ.get('KC_REALM', 'acme-ai')
INSECURE = os.environ.get('INSECURE', '0') == '1'
# mTLS: when set, the agent presents this client certificate to Avi on every
# connection. CLIENT_KEY defaults to CLIENT_CERT if the key is bundled in the
# same PEM file. CLIENT_KEY_PASSWORD is optional (only if the key is encrypted).
CLIENT_CERT = os.environ.get('CLIENT_CERT', '')
CLIENT_KEY = os.environ.get('CLIENT_KEY', '') or CLIENT_CERT
CLIENT_KEY_PASSWORD = os.environ.get('CLIENT_KEY_PASSWORD') or None

# Client credentials per tier. In a real deployment these are separate service
# accounts; here they map to Keycloak clients whose tokens carry the mcp_tier claim.
CLIENTS = {
    'catalog': (os.environ.get('CID_CATALOG', 'agent-catalog'),
                os.environ.get('SECRET_CATALOG', 'catalog-secret')),
    'ops':     (os.environ.get('CID_OPS', 'agent-ops'),
                os.environ.get('SECRET_OPS', 'ops-secret')),
    'finance': (os.environ.get('CID_FINANCE', 'agent-finance'),
                os.environ.get('SECRET_FINANCE', 'finance-secret')),
}

NS = {'catalog': '/mcp/catalog', 'ops': '/mcp/ops', 'finance': '/mcp/finance'}

# tool -> namespace it legitimately belongs to
TOOL_NS = {
    'inventory.lookup': 'catalog', 'catalog.search': 'catalog', 'vendor.notes': 'catalog',
    'order.create': 'ops', 'shipment.reroute': 'ops',
    'invoice.list': 'finance', 'payment.release': 'finance', 'vendor.bank.update': 'finance',
}

_ctx = ssl.create_default_context()
if INSECURE:
    _ctx.check_hostname = False
    _ctx.verify_mode = ssl.CERT_NONE

# Present the agent's client certificate for mTLS, if configured. This is what
# Avi validates against its PKI profile when the VS requires a client cert.
if CLIENT_CERT:
    try:
        _ctx.load_cert_chain(certfile=CLIENT_CERT, keyfile=CLIENT_KEY,
                             password=CLIENT_KEY_PASSWORD)
    except (FileNotFoundError, ssl.SSLError, OSError) as exc:
        sys.stderr.write(
            'ERROR: could not load client certificate for mTLS.\n'
            '  CLIENT_CERT=%s\n  CLIENT_KEY=%s\n  %s\n'
            % (CLIENT_CERT, CLIENT_KEY, exc))
        sys.exit(2)


def _truncate_token(val):
    """Show a real JWT as head...tail so it is visibly genuine without flooding
    the console with 800 characters."""
    # val looks like 'Bearer eyJhbGciOi....<long>....Xr9pQ'
    parts = val.split(' ', 1)
    if len(parts) == 2 and len(parts[1]) > 40:
        t = parts[1]
        return parts[0] + ' ' + t[:22] + '...' + t[-6:]
    return val


# Toggle the request echo (default on). Set SHOW_REQUESTS=0 to silence it.
SHOW_REQUESTS = os.environ.get('SHOW_REQUESTS', '1') != '0'


def _mask_secrets(body):
    """Replace secret values in a request body with *** for display only.
    Masks client_secret and password in both urlencoded (key=value&...) and
    JSON ("key":"value") bodies. The real value still goes on the wire; only
    the echoed copy is masked."""
    SECRET_KEYS = ('client_secret', 'password')
    out = body
    for key in SECRET_KEYS:
        # urlencoded form: key=value  (value ends at & or end-of-string)
        marker = key + '='
        i = out.find(marker)
        while i != -1:
            start = i + len(marker)
            end = out.find('&', start)
            if end == -1:
                end = len(out)
            out = out[:start] + '***' + out[end:]
            i = out.find(marker, start + 3)
        # JSON form: "key":"value" or "key": "value"
        jmarker = '"' + key + '"'
        j = out.find(jmarker)
        while j != -1:
            colon = out.find(':', j + len(jmarker))
            q1 = out.find('"', colon + 1) if colon != -1 else -1
            q2 = out.find('"', q1 + 1) if q1 != -1 else -1
            if q1 != -1 and q2 != -1:
                out = out[:q1 + 1] + '***' + out[q2:]
            j = out.find(jmarker, j + len(jmarker))
    return out


def _echo_request(url, method, headers, data):
    """Print the real HTTP request as a clean curl-equivalent, so the audience
    sees an actual request going to Avi rather than opaque script output. What
    is printed is exactly what _req sends on the wire."""
    if not SHOW_REQUESTS:
        return
    parts = ['curl']
    if CLIENT_CERT:
        # show the cert basenames, not the full path (keeps it clean)
        parts.append('--cert %s' % os.path.basename(CLIENT_CERT))
        parts.append('--key %s' % os.path.basename(CLIENT_KEY))
    if method and method != 'GET':
        parts.append('-X %s' % method)
    for k, v in (headers or {}).items():
        shown = _truncate_token(v) if k.lower() == 'authorization' else v
        parts.append("-H '%s: %s'" % (k, shown))
    if data:
        body = data if isinstance(data, str) else data.decode('utf-8', 'replace')
        body = _mask_secrets(body)
        if len(body) > 160:
            body = body[:157] + '...'
        parts.append("-d '%s'" % body)
    parts.append(url)
    # print as a wrapped, readable curl command prefixed with the $ prompt
    line = '  $ ' + ' \\\n      '.join(parts)
    print(line)


def _req(url, method='GET', headers=None, data=None, stream=False):
    _echo_request(url, method, headers, data)
    body = data.encode() if isinstance(data, str) else data
    r = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        resp = urllib.request.urlopen(r, context=_ctx, timeout=30)
        if stream:
            return resp.status, dict(resp.getheaders()), resp
        return resp.status, dict(resp.getheaders()), resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode()


def discover(tier='catalog'):
    """Scene 1: unauth request -> 401 + WWW-Authenticate -> metadata -> AS."""
    print('== RFC 9728 discovery ==')
    url = MCP + NS[tier]
    status, headers, body = _req(
        url, 'POST', {'content-type': 'application/json'},
        json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
                    'params': {'protocolVersion': '2025-06-18', 'capabilities': {}}}))
    print('1. unauth initialize -> HTTP %d' % status)
    www = headers.get('WWW-Authenticate') or headers.get('www-authenticate')
    print('   WWW-Authenticate: %s' % (www or '(none)'))
    if status != 401 or not www:
        print('   NOTE: expected 401 with WWW-Authenticate. Check Avi SSO policy.')
        return None
    meta_url = None
    for part in www.split(','):
        part = part.strip()
        if part.startswith('resource_metadata='):
            meta_url = part.split('=', 1)[1].strip('"')
    if not meta_url:
        meta_url = MCP + '/.well-known/oauth-protected-resource'
    print('2. GET %s' % meta_url)
    status, _, body = _req(meta_url)
    print('   -> HTTP %d' % status)
    meta = json.loads(body)
    print(json.dumps(meta, indent=2))
    auth_servers = meta.get('authorization_servers', [])
    print('3. authorization server: %s' % (auth_servers[0] if auth_servers else '(none)'))
    print('   supported scopes: %s' % meta.get('scopes_supported', []))
    return meta


def get_token(tier):
    cid, secret = CLIENTS[tier]
    token_url = '%s/realms/%s/protocol/openid-connect/token' % (KC, REALM)
    form = urllib.parse.urlencode({
        'grant_type': 'client_credentials',
        'client_id': cid,
        'client_secret': secret,
        'scope': 'mcp.%s' % tier,
    })
    status, _, body = _req(token_url, 'POST',
                           {'content-type': 'application/x-www-form-urlencoded'}, form)
    if status != 200:
        print('token request failed: HTTP %d\n%s' % (status, body), file=sys.stderr)
        sys.exit(1)
    return json.loads(body)['access_token']


def mcp_call(tier, tool, args, token=None, namespace=None, session_id=None):
    ns = namespace or NS[tier]
    url = MCP + ns
    headers = {'content-type': 'application/json', 'accept': 'application/json'}
    if token:
        headers['authorization'] = 'Bearer ' + token
    if session_id:
        headers['mcp-session-id'] = session_id
    else:
        s, h, b = _req(url, 'POST', headers, json.dumps({
            'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
            'params': {'protocolVersion': '2025-06-18', 'capabilities': {}}}))
        if s != 200:
            return s, h, b, None
        session_id = h.get('mcp-session-id') or h.get('Mcp-Session-Id')
        headers['mcp-session-id'] = session_id
    s, h, b = _req(url, 'POST', headers, json.dumps({
        'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
        'params': {'name': tool, 'arguments': args}}))
    return s, h, b, session_id


def scene_mtls():
    """Scene: mutual TLS enforcement at the Avi virtual service.

    Makes two connections to the MCP VS to prove the client certificate is
    doing real work:
      1. WITHOUT a client cert -> Avi rejects at the TLS handshake.
      2. WITH the agent's client cert -> handshake succeeds, request proceeds
         to the JWT layer (a 401 here is fine; it means TLS passed and auth ran).

    Requires CLIENT_CERT / CLIENT_KEY to be set for the positive case.
    """
    print('== Scene: mutual TLS enforcement at the edge ==\n')
    url = MCP + '/.well-known/oauth-protected-resource'

    # --- Case 1: no client certificate -----------------------------------
    # Enforcement can manifest two ways depending on the Avi client-cert config:
    #  (a) the TLS handshake is aborted (SSLError), or
    #  (b) the handshake completes but Avi returns an HTTP 4xx because no cert
    #      was presented.
    # Either way the certless request does NOT get a normal 200. So we treat
    # ONLY a successful 200 (or a metadata document) as "not enforced"; any
    # failure - TLS, connection, or HTTP 4xx - counts as rejected.
    print('[1] Connecting WITHOUT a client certificate (expect: rejected).')
    if SHOW_REQUESTS:
        print('  $ curl %s' % url)
    no_cert = ssl.create_default_context()
    no_cert.check_hostname = False
    no_cert.verify_mode = ssl.CERT_NONE  # ignore SERVER cert; we test CLIENT cert
    rejected = False
    try:
        req = urllib.request.Request(url, method='GET')
        resp = urllib.request.urlopen(req, context=no_cert, timeout=15)
        # Reached a real 200 with no client cert -> mTLS is NOT enforced.
        print('    -> connection SUCCEEDED (HTTP %d) with no cert. mTLS is NOT '
              'enforced on this VS.' % resp.status)
    except ssl.SSLError as e:
        rejected = True
        why = getattr(e, 'reason', None) or 'client certificate required'
        print('    -> TLS handshake rejected by Avi (%s).' % why)
    except urllib.error.HTTPError as e:
        # Handshake completed, Avi rejected at the HTTP layer (e.g. 400/403).
        if e.code >= 400:
            rejected = True
            print('    -> rejected by Avi at the HTTP layer: HTTP %d.' % e.code)
        else:
            print('    -> unexpected HTTP %d with no cert.' % e.code)
    except urllib.error.URLError as e:
        reason = getattr(e, 'reason', e)
        if isinstance(reason, ssl.SSLError):
            rejected = True
            print('    -> TLS handshake rejected by Avi (no client cert).')
        else:
            # Connection closed / reset / refused without a clean HTTP response.
            # With no cert presented, this is Avi refusing the connection.
            rejected = True
            print('    -> connection refused by Avi without a client cert (%s).' % reason)

    print()

    # --- Case 2: with the agent's client certificate ---------------------
    print('[2] Connecting WITH the agent client certificate (expect: accepted).')
    if not CLIENT_CERT:
        print('    -> CLIENT_CERT not set; cannot run the positive case.')
        print('\nFAIL: set CLIENT_CERT / CLIENT_KEY to demonstrate the accepted path.')
        return
    accepted = False
    with_cert = ssl.create_default_context()
    with_cert.check_hostname = False
    with_cert.verify_mode = ssl.CERT_NONE
    try:
        with_cert.load_cert_chain(certfile=CLIENT_CERT, keyfile=CLIENT_KEY,
                                  password=CLIENT_KEY_PASSWORD)
    except (FileNotFoundError, ssl.SSLError, OSError) as exc:
        print('    -> could not load client cert: %s' % exc)
        print('\nFAIL: client certificate could not be loaded.')
        return
    try:
        req = urllib.request.Request(url, method='GET')
        if SHOW_REQUESTS:
            print('  $ curl --cert %s --key %s %s'
                  % (os.path.basename(CLIENT_CERT), os.path.basename(CLIENT_KEY), url))
        resp = urllib.request.urlopen(req, context=with_cert, timeout=15)
        accepted = True
        print('    -> TLS handshake accepted; HTTP %d from the resource.' % resp.status)
    except urllib.error.HTTPError as e:
        # Handshake completed; server returned an HTTP status (e.g. 401 from JWT).
        accepted = True
        print('    -> TLS handshake accepted; HTTP %d (auth layer beyond mTLS).' % e.code)
    except (ssl.SSLError, urllib.error.URLError) as e:
        reason = getattr(e, 'reason', e)
        print('    -> handshake FAILED even with the cert: %s' % reason)

    print()
    if rejected and accepted:
        print('PASS: Avi rejects connections with no client certificate and accepts')
        print('the agent\'s certificate. Machine identity is enforced at the edge,')
        print('before JWT, WAF, or the backend are ever reached.')
    elif not rejected and accepted:
        print('FAIL: the no-cert connection was not rejected (it reached a normal')
        print('response). Confirm the VS application profile is set to REQUIRE client')
        print('certificates, not Request or None.')
    elif rejected and not accepted:
        print('FAIL: the certified connection did not succeed. Either the endpoint is')
        print('unreachable, or the cert is not accepted - check that MCP is up, the')
        print('cert chains to the PKI profile CA, and CLIENT_CERT/KEY are correct.')
    else:
        print('FAIL: neither connection behaved as expected. Check that the MCP VS is')
        print('reachable at %s.' % MCP)


def scene_authz():
    """Scene 3: least privilege across all three tiers. Each tier's token reaches
    its own namespace (allowed) and is rejected on another tier's namespace
    (blocked). Avi enforces on the mcp_tier JWT claim at the edge."""
    print('== Scene: JWT tier authorization (Avi SSO policy) ==\n')

    # Each tier: (its own legitimate tool + namespace, a cross-tier tool it must
    # NOT be able to reach). The denied target is a higher-privilege action in a
    # different namespace.
    tiers = [
        ('catalog', 'inventory.lookup', {'sku': 'SKU-4410'},
         'payment.release', '/mcp/finance', {'invoice_id': 'INV-20261'}),
        ('ops', 'order.create', {'sku': 'SKU-4410', 'quantity': 5},
         'payment.release', '/mcp/finance', {'invoice_id': 'INV-20261'}),
        ('finance', 'invoice.list', {},
         'shipment.reroute', '/mcp/ops', {'order_id': 'ORD-5591', 'dest': 'XX'}),
    ]

    all_ok = True
    for tier, own_tool, own_args, x_tool, x_ns, x_args in tiers:
        tok = get_token(tier)
        if not tok:
            print('[%s] could not obtain token (check Keycloak client + secret)\n' % tier)
            all_ok = False
            continue
        print('--- %s tier (claim mcp_tier=%s) ---' % (tier, tier))

        # Allowed: its own tool in its own namespace.
        s, _, _, _ = mcp_call(tier, own_tool, own_args, token=tok)
        own_ok = (s == 200)
        print('  [allowed] %-16s on %-13s -> HTTP %d  %s'
              % (own_tool, NS[tier], s, 'PASS' if own_ok else 'unexpected'))

        # Denied: a higher-privilege tool in a different namespace.
        s, _, b, _ = mcp_call(tier, x_tool, x_args, token=tok, namespace=x_ns)
        denied_ok = s in (401, 403)
        print('  [denied]  %-16s on %-13s -> HTTP %d  %s'
              % (x_tool, x_ns, s, 'PASS (blocked)' if denied_ok else 'FAIL (leak!)'))
        if s == 200:
            print('       ' + b[:160])
        print()
        all_ok = all_ok and own_ok and denied_ok

    print('Each tier is confined to its own tools. Avi enforces the mcp_tier claim')
    print('at the edge, so a catalog or ops agent physically cannot move money and')
    print('finance cannot reroute shipments - before any request reaches the')
    print('unauthenticated backend.')
    print()
    print('PASS' if all_ok else 'FAIL: an unexpected authorization result occurred above.')


def _served_by(b, status):
    if status != 200:
        return None
    try:
        return json.loads(b).get('result', {}).get('_meta', {}).get('servedBy')
    except (ValueError, AttributeError):
        return None


def _ssh_host(node):
    override = os.environ.get('SSH_HOST_' + node.replace('-', '_').upper())
    return override or node


def _ssh_systemctl(node, action):
    """Run 'sudo systemctl <action> acme-mcp' on a backend node over SSH.

    Returns (rc, output). Uses the demo key and options that work non-interactively
    as the acme service account. All SSH settings come from env so nothing is
    hard-coded to one environment.
    """
    key = os.environ.get('SSH_KEY', '/opt/waap-demo/.ssh/waap-demo')
    user = os.environ.get('SSH_USER', 'ubuntu')
    known = os.environ.get('SSH_KNOWN_HOSTS', '/opt/waap-demo/.ssh/known_hosts')
    host = _ssh_host(node)
    cmd = [
        'ssh', '-i', key,
        '-o', 'UserKnownHostsFile=' + known,
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=8',
        '-o', 'BatchMode=yes',
        '%s@%s' % (user, host),
        'sudo systemctl %s acme-mcp' % action,
    ]
    import subprocess
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return p.returncode, (p.stdout + p.stderr).strip()
    except Exception as exc:  # noqa: BLE001
        return 1, str(exc)


def scene_session(stop_node=False):
    """Scene 4: session persistence survives a backend failure.

    Interactive mode (default): prints instructions and waits for the presenter
    to stop the node by hand, then presses Enter.

    Automated mode (--stop-node): establishes the session, SSHes to the served
    node and stops acme-mcp itself, runs the follow-ups, then restarts the node.
    Designed to run non-interactively from the dashboard.
    """
    print('== Scene: MCP session persistence under backend failure ==\n')
    tok = get_token('catalog')
    s, h, b, sid = mcp_call('catalog', 'inventory.lookup', {'sku': 'SKU-4410'}, token=tok)
    served = _served_by(b, s) or '?'
    print('Session %s established, pinned to backend %s.' % (sid, served))

    if not stop_node:
        print('Now take that backend offline (stop the systemd unit on %s) and press Enter.' % served)
        try:
            input()
        except EOFError:
            pass
        _session_followups(tok, sid)
        print('\nThe session-id mapping is held in the Avi SE persistence table, not the')
        print('backend. Avi re-pins to a healthy member and the conversation continues.')
        return

    if served == '?' or not sid:
        print('FAIL: could not establish a session (HTTP %d). Check the MCP VS.' % s)
        return
    node = served
    print('Stopping acme-mcp on %s via SSH ...' % node)
    rc, out = _ssh_systemctl(node, 'stop')
    if rc != 0:
        print('FAIL: could not stop %s over SSH: %s' % (node, out or 'no output'))
        print('      (check SSH key, sudoers rule, and reachability from this host)')
        return
    print('  %s: acme-mcp stopped.' % node)

    try:
        import time as _t
        # Give Avi's health monitor time to mark the stopped member down before
        # the follow-ups. If the HM interval*failures is long, raise this via env.
        wait_s = float(os.environ.get('FAILOVER_WAIT', '8'))
        print('  waiting %gs for Avi to detect the down member ...' % wait_s)
        _t.sleep(wait_s)
        survived = _session_followups(tok, sid, expect_other_than=node, retries=5)
    finally:
        print('Restarting acme-mcp on %s via SSH ...' % node)
        rc2, out2 = _ssh_systemctl(node, 'start')
        if rc2 == 0:
            print('  %s: acme-mcp restarted.' % node)
        else:
            print('  WARNING: could not restart %s: %s' % (node, out2 or 'no output'))
            print('  Restart it manually: sudo systemctl start acme-mcp')

    print()
    if survived:
        print('PASS: session survived. Avi re-pinned to a healthy member and the')
        print('conversation continued. The session-id mapping lives in the Avi SE')
        print('persistence table, not on the backend that went down.')
    else:
        print('FAIL: follow-up calls did not succeed on a surviving node. Check that')
        print('the pool has two healthy members and the MCP application profile is on vs-mcp.')


def _session_followups(tok, sid, expect_other_than=None, retries=1):
    """Run follow-up calls on the same session; return True if they succeed
    (and, when expect_other_than is set, are served by a different node).

    Retries tolerate the brief window where Avi has stopped routing to the
    down member but has not yet re-pinned to a healthy one (transient 503).
    """
    import time as _t
    ok = False
    seen_other = False
    attempt = 0
    successes = 0
    while attempt < max(retries, 3) and successes < 3:
        attempt += 1
        s, h, b, _ = mcp_call('catalog', 'inventory.lookup', {'sku': 'SKU-4410'},
                              token=tok, session_id=sid)
        node = _served_by(b, s)
        label = node if node else 'HTTP %d' % s
        print('  follow-up %d -> served by %s' % (attempt, label))
        if s == 200:
            successes += 1
            ok = True
            if expect_other_than and node and node != expect_other_than:
                seen_other = True
        else:
            # transient during failover detection; wait and retry
            _t.sleep(2)
    if expect_other_than:
        return ok and seen_other
    return ok


def chat(prompt):
    tok = get_token('catalog')
    url = LLM + '/v1/chat/completions'
    payload = json.dumps({'model': 'acme-frontier-70b', 'stream': True,
                          'messages': [{'role': 'user', 'content': prompt}]})
    s, h, resp = _req(url, 'POST',
                      {'content-type': 'application/json', 'accept': 'text/event-stream',
                       'authorization': 'Bearer ' + tok}, payload, stream=True)
    if s != 200:
        print('HTTP %d' % s)
        return
    sys.stdout.write('assistant> ')
    for line in resp:
        line = line.decode().strip()
        if not line.startswith('data:'):
            continue
        data = line[5:].strip()
        if data == '[DONE]':
            break
        try:
            chunk = json.loads(data)
        except ValueError:
            continue
        for ch in chunk.get('choices', []):
            piece = ch.get('delta', {}).get('content', '')
            if piece:
                sys.stdout.write(piece)
                sys.stdout.flush()
    print()


def main():
    p = argparse.ArgumentParser(description='ACME MCP demo agent')
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('discover').add_argument('--tier', default='catalog')
    t = sub.add_parser('token'); t.add_argument('--tier', default='catalog')
    c = sub.add_parser('call')
    c.add_argument('--tier', default='catalog')
    c.add_argument('--tool', required=True)
    c.add_argument('--args', default='{}')
    c.add_argument('--namespace')
    sub.add_parser('scene-mtls')
    sub.add_parser('scene-authz')
    ss = sub.add_parser('scene-session')
    ss.add_argument('--stop-node', action='store_true',
                    help='SSH to the served backend and stop/restart acme-mcp automatically')
    ch = sub.add_parser('chat'); ch.add_argument('prompt')
    a = p.parse_args()

    if a.cmd == 'discover':
        discover(a.tier)
    elif a.cmd == 'token':
        print(get_token(a.tier))
    elif a.cmd == 'call':
        tok = get_token(a.tier)
        s, _, b, _ = mcp_call(a.tier, a.tool, json.loads(a.args), token=tok, namespace=a.namespace)
        print('HTTP %d' % s)
        print(b)
    elif a.cmd == 'scene-mtls':
        scene_mtls()
    elif a.cmd == 'scene-authz':
        scene_authz()
    elif a.cmd == 'scene-session':
        scene_session(stop_node=getattr(a, 'stop_node', False))
    elif a.cmd == 'chat':
        chat(a.prompt)


if __name__ == '__main__':
    main()
