# Test-AviDiscoveryCredential.ps1

Validates that an Avi Load Balancer account is usable and records configurations.

It answers four questions that a plain "can I log in?" test does not:

1. Can this host reach the controller over TLS?
2. Do these credentials authenticate, and what API version does the controller actually speak?
3. Can this account **read** every object type the Discovery pattern walks?
4. Which tenants are in scope, and will the returned objects reconcile cleanly into a CMDB?

---

## Requirements

| Item | Detail |
|---|---|
| PowerShell | 5.1 (Windows) or 7.x. Both are supported and tested. |
| Network | Outbound HTTPS (443) to the Avi Controller. |
| Avi account | Read access to the object types listed under [Endpoints](#endpoints). No write or system access needed. |
| Permissions | None special on the local host. Do not run elevated. |

---

## Quick start

```powershell
.\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.example.local -SkipCertificateCheck
```

You will be prompted for the Avi username and password.

To avoid retyping the password across runs (and avoid burning failed-login attempts on a typo):

```powershell
$cred = Get-Credential snow-svc
.\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.example.local -Credential $cred -SkipCertificateCheck
```

### Verify which build you are running

The script prints its version in the header. If you are troubleshooting with someone, confirm it first:

```powershell
Select-String -Path .\Test-AviDiscoveryCredential.ps1 -Pattern "ScriptVersion  = "
```

---

## Parameters

### Connection

| Parameter | Default | Purpose |
|---|---|---|
| `-Controller` | *(required)* | Controller FQDN, VIP, or full URL. |
| `-Credential` | prompts | A `PSCredential`. Omit to be prompted. Never hardcode a password in the file. |
| `-Tenant` | `admin` | Tenant scope sent as `X-Avi-Tenant`. Use `*` to test read across all tenants. |
| `-SkipCertificateCheck` | off | Ignore certificate validation errors. See the [trust store warning](#3-java-trust-store-vs-powershell). |
| `-TimeoutSec` | `30` | Per-request timeout. |

### API version

| Parameter | Default | Purpose |
|---|---|---|
| `-ApiVersion` | auto-detect | Force a specific `X-Avi-Version` and skip detection. |
| `-VersionFloor` | `18.2.6` | Last-resort value if every detection tier fails. Deliberately old: older versions are accepted by newer controllers, the reverse is rejected with 403. |

### What to read

| Parameter | Default | Purpose |
|---|---|---|
| `-Endpoints` | see below | Object types to test. Trim or extend to match your Discovery pattern version. |
| `-PageSize` | `25` | Objects fetched per endpoint. |
| `-All` | off | Follow pagination and fetch every object. Forced on by `-InventoryFile`. |

### Output

| Parameter | Default | Purpose |
|---|---|---|
| `-Show` | `Config` | `Config` = API call plus each object's configuration. `Summary` = check lines only. `Full` = API call plus raw JSON. |
| `-MaxDetail` | `10` | Objects printed per endpoint in the `Config` view before truncating. |
| `-OutFile` | none | Write the **check report**. Format from the extension: `.json`, `.csv`, `.html`. |
| `-InventoryFile` | none | Write the **object inventory** as normalized JSON. |
| `-IncludeRaw` | off | Include the complete unmodified API object under a `raw` key. |
| `-PassThru` | off | Emit result objects to the pipeline. |

---

## Endpoints

Tested by default:

```
cluster/runtime   cloud       virtualservice   vsvip     pool
poolgroup         serviceengine   serviceenginegroup
healthmonitor     vrfcontext  network
```

Override to match your pattern:

```powershell
.\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.example.local `
    -Endpoints 'virtualservice','pool','serviceengine'
```

---

## What the output means

### Check log

Each line is one check, with `PASS` / `WARN` / `FAIL`:

```
PASS   Reachability               Controller responded, version field empty
PASS   Login                      Authenticated as snow-svc
PASS   API version                32.1.2 (detected)
PASS   Tenant access              2 tenant(s) visible: admin, Dev Team
PASS   GET /api/virtualservice    count = 4 | WebServer-L7-Vs, DNS-L7-Vs, ...
WARN   GET /api/poolgroup         count = 0 (readable, but nothing to discover)
```

`WARN` is not a failure. It flags something worth a look: an empty object type, or duplicate object names.

### Configuration detail

Shows the literal API call issued and the configuration of each object it returned:

```
  GET /api/virtualservice
    API  GET https://avi-ctrl.example.local/api/virtualservice?include_name=true&page_size=25
    WebServer-L7-Vs
      uuid             virtualservice-8f2c-...
      tenant           admin
      cloud            Default-Cloud
      enabled          True
      pool             WebServer-L7-Vs-Pool
      ipAddresses      10.0.140.50
      services         port=443 ssl=True
```

The `API` line is the actual URI that was sent, not a reconstruction. When pagination is in play you get one line per page. This is what you hand to the ServiceNow team so they can reproduce the call.

### Summary

```
API version detected: 32.1.2   (source: /api/cluster/version)
Pin this value in the ServiceNow pattern's X-Avi-Version header.
------------------------------------------------------------------------------
Checks: 12 passed, 3 warning, 0 failed
  WARN  GET /api/poolgroup: count = 0 (readable, but nothing to discover)
------------------------------------------------------------------------------
RESULT: PASS. This account is usable for ServiceNow Discovery.
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed. |
| `1` | One or more checks failed. |
| `2` | Could not reach the controller. Stopped before login. |
| `3` | Login failed. Stopped before inventory checks. |

Suitable for a pipeline or a scheduled sanity check.

---

## Example output

A full run against a lab controller, using `-Tenant '*'` to test read across all tenants. Repetitive blocks are trimmed with `[...]`; everything else is verbatim.

> **Note:** hostnames, domains, DNS records, IP addresses, UUIDs, and certificate names in this sample are placeholders. Structure, field names, and formatting are unchanged from a real run.

<details>
<summary><b>Click to expand full sample run</b></summary>

```text
PS C:\Users\admin\Desktop> .\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.example.local -Tenant '*'

Avi Discovery credential test  (script v1.8.2)
Controller : https://avi-ctrl.example.local
Account    : snow-svc
Tenant     : *
Host       : WIN-MIDSRV01  (running as WIN-MIDSRV01\admin)
PowerShell : 5.1.26100.9168 Desktop
Script     : C:\Users\admin\Desktop\Test-AviDiscoveryCredential.ps1
------------------------------------------------------------------------------
PASS   Reachability               Controller responded, version field empty
PASS   Login                      Authenticated as snow-svc
PASS   API version                32.1.2 (detected)
PASS   Tenant access              2 tenant(s) visible: admin, Dev Team

Inventory read checks (tenant scope: *)
PASS   GET /api/cluster/runtime   readable (single object, not a collection)
PASS   GET /api/cloud             count = 2 | Default-Cloud, Demo NSX Cloud
PASS   GET /api/virtualservice    count = 5 | WebServer-L7-Vs, DNS-L7-Vs, Horizon-L7-Vs, SCM-L7-Vs, Dev-WebServer-L7-Vs
PASS   GET /api/vsvip             count = 5 | WebServer-L7-Vs-VsVip, DNS-L7-Vs-VsVip, ... (+3 more)
PASS   GET /api/pool              count = 5 | WebServer-L7-Vs-Pool, DNS-L7-Vs-Pool, ... (+3 more)
WARN   GET /api/poolgroup         count = 0 (readable, but nothing to discover)
PASS   GET /api/serviceengine     count = 6 | site1_nsx_dns-se-aaaaa, ... (+5 more)
WARN   GET /api/serviceenginegroup count = 4 | Default-Group, Default-Group, DNS-SEG, Application-SEG | duplicate names: Default-Group x2 (reconcile on uuid, not name)
PASS   GET /api/healthmonitor     count = 17 | System-HTTP, System-HTTPS, System-Ping, ... (+14 more)
WARN   GET /api/vrfcontext        count = 6 | global, management, management, global, T1-Gateway-B, ... (+1 more) | duplicate names: global x2, management x2 (reconcile on uuid, not name)
PASS   GET /api/network           count = 6 | vdpg-0001-site1-se-mgmt-net, ... (+5 more)
PASS   Logout                     Session closed

==============================================================================
API version detected: 32.1.2   (source: /api/cluster/version)
Pin this value in the ServiceNow pattern's X-Avi-Version header.
------------------------------------------------------------------------------
Checks: 13 passed, 3 warning, 0 failed
  WARN  GET /api/poolgroup: count = 0 (readable, but nothing to discover)
  WARN  GET /api/serviceenginegroup: ... duplicate names: Default-Group x2 (reconcile on uuid, not name)
  WARN  GET /api/vrfcontext: ... duplicate names: global x2, management x2 (reconcile on uuid, not name)
------------------------------------------------------------------------------
RESULT: PASS. This account is usable for ServiceNow Discovery.
==============================================================================

==============================================================================
CONFIGURATION DETAIL
Each block shows the exact API call and the objects it returned.
==============================================================================

  GET /api/cluster/runtime
    API  GET https://avi-ctrl.example.local/api/cluster/runtime
    object 1
      node_info        uuid=005056000001 ip=node1.controller.local mgmt_ip=10.0.11.31 version=32.1.2(9077) ...
      node_states      state=CLUSTER_ACTIVE name=10.0.11.31 role=CLUSTER_LEADER up_since=2026-07-24 1...
      nodes_count      1
      leader           True
      cluster_state    up_since=2026-07-24 14:15:00 state=CLUSTER_UP_NO_HA progress=100
      flavor           CONTROLLER_SMALL

  GET /api/cloud
    API  GET https://avi-ctrl.example.local/api/cloud?include_name=true&page_size=25
    Default-Cloud
      uuid             cloud-00000001-1111-4222-8333-000000000001
      tenant           admin
      vtype            CLOUD_NONE
      dhcp             True
      ipamProfile      ipam-profile
      dnsProfile       dns-profile
    Demo NSX Cloud
      uuid             cloud-00000002-1111-4222-8333-000000000002
      tenant           admin
      vtype            CLOUD_NSXT
      dhcp             True
      ipamProfile      ipam-profile
      dnsProfile       dns-profile

  GET /api/virtualservice
    API  GET https://avi-ctrl.example.local/api/virtualservice?include_name=true&page_size=25
    WebServer-L7-Vs
      uuid             virtualservice-00000003-1111-4222-8333-000000000003
      tenant           admin
      cloud            Demo NSX Cloud
      enabled          True
      vsvip            WebServer-L7-Vs-VsVip
      seGroup          Application-SEG
      vrf              T1-Gateway-B
      appProfile       System-Secure-HTTP
      pool             WebServer-L7-Vs-Pool
      services         port=443 ssl=True
      sslProfile       System-Standard-PFS
      sslCertificates  corp-wildcard
    DNS-L7-Vs
      uuid             virtualservice-00000004-1111-4222-8333-000000000004
      tenant           admin
      cloud            Demo NSX Cloud
      enabled          True
      vsvip            DNS-L7-Vs-VsVip
      seGroup          DNS-SEG
      vrf              T1-Gateway-A
      appProfile       System-DNS
      pool             DNS-L7-Vs-Pool
      services         port=53 ssl=False
    [... Horizon-L7-Vs, SCM-L7-Vs trimmed ...]
    Dev-WebServer-L7-Vs
      uuid             virtualservice-00000005-1111-4222-8333-000000000005
      tenant           Dev Team
      cloud            Demo NSX Cloud
      enabled          True
      vsvip            Dev-WebServer-L7-Vs-VsVip
      seGroup          Application-SEG
      vrf              T1-Gateway-B
      appProfile       System-Secure-HTTP
      pool             Dev-WebServer-L7-Vs-Pool
      services         port=443 ssl=True
      sslProfile       System-Standard-PFS
      sslCertificates  System-Default-Cert

  GET /api/vsvip
    API  GET https://avi-ctrl.example.local/api/vsvip?include_name=true&page_size=25
    WebServer-L7-Vs-VsVip
      uuid             vsvip-00000006-1111-4222-8333-000000000006
      tenant           admin
      cloud            Demo NSX Cloud
      ipAddresses      10.0.151.128
      fqdn             www.example.local; app1.example.local
      vrf              T1-Gateway-B
    [... 4 more VsVips trimmed ...]

  GET /api/pool
    API  GET https://avi-ctrl.example.local/api/pool?include_name=true&page_size=25
    WebServer-L7-Vs-Pool
      uuid             pool-00000007-1111-4222-8333-000000000007
      tenant           admin
      cloud            Demo NSX Cloud
      enabled          True
      lbAlgorithm      LB_ALGORITHM_ROUND_ROBIN
      defaultPort      80
      healthMonitors   System-HTTP
      serverCount      4
      servers          ip=10.0.148.82 hostname=10.0.148.82 enabled=True ratio=1; ip=10.0.148.81 hostname=10.0.148.81 enabled=True ratio=1; ip=10.0.148.80 hostname=10.0.148.80 enabled=True ratio=1; ip=10.0.148.83 hostname=10.0.148.83 enabled=True ratio=1
    DNS-L7-Vs-Pool
      uuid             pool-00000008-1111-4222-8333-000000000008
      tenant           admin
      cloud            Demo NSX Cloud
      enabled          True
      lbAlgorithm      LB_ALGORITHM_LEAST_CONNECTIONS
      defaultPort      53
      healthMonitors   System-DNS
      serverCount      1
      servers          ip=10.0.99.53 hostname=10.0.99.53 enabled=True ratio=1
    [... 3 more pools trimmed ...]

  GET /api/poolgroup
    API  GET https://avi-ctrl.example.local/api/poolgroup?include_name=true&page_size=25
    (no objects returned)

  GET /api/serviceengine
    API  GET https://avi-ctrl.example.local/api/serviceengine?include_name=true&page_size=25
    site1_nsx_dns-se-aaaaa
      uuid             se-005056000002
      tenant           admin
      cloud            Demo NSX Cloud
      seGroup          DNS-SEG
      mgmtIp           10.0.140.69
      enabled          SE_STATE_ENABLED
    [... 5 more service engines trimmed ...]

  GET /api/serviceenginegroup
    API  GET https://avi-ctrl.example.local/api/serviceenginegroup?include_name=true&page_size=25
    Default-Group
      uuid             serviceenginegroup-00000009-1111-4222-8333-000000000009
      tenant           admin
      cloud            Default-Cloud
      haMode           HA_MODE_SHARED
      minSes           1
      maxSes           10
      vcpusPerSe       1
      memoryPerSe      2048
    Default-Group
      uuid             serviceenginegroup-0000000a-1111-4222-8333-00000000000a
      tenant           admin
      cloud            Demo NSX Cloud
      haMode           HA_MODE_SHARED
      minSes           1
      maxSes           10
      vcpusPerSe       1
      memoryPerSe      2048
    Application-SEG
      uuid             serviceenginegroup-0000000b-1111-4222-8333-00000000000b
      tenant           admin
      cloud            Demo NSX Cloud
      haMode           HA_MODE_SHARED_PAIR
      minSes           2
      maxSes           4
      vcpusPerSe       2
      memoryPerSe      4096
    [... DNS-SEG trimmed ...]

  GET /api/healthmonitor
    API  GET https://avi-ctrl.example.local/api/healthmonitor?include_name=true&page_size=25
    System-HTTP
      uuid             healthmonitor-0000000c-1111-4222-8333-00000000000c
      tenant           admin
      type             HEALTH_MONITOR_HTTP
      receiveTimeout   4
      sendInterval     10
    [... 9 more shown, then: ...]
    ... 7 more not shown (raise -MaxDetail)

  GET /api/vrfcontext
    API  GET https://avi-ctrl.example.local/api/vrfcontext?include_name=true&page_size=25
    global
      uuid             vrfcontext-0000000d-1111-4222-8333-00000000000d
      tenant           admin
      cloud            Default-Cloud
      staticRoutes     1
    global
      uuid             vrfcontext-0000000e-1111-4222-8333-00000000000e
      tenant           admin
      cloud            Demo NSX Cloud
      staticRoutes     1
    T1-Gateway-B
      uuid             vrfcontext-0000000f-1111-4222-8333-00000000000f
      tenant           admin
      cloud            Demo NSX Cloud
      staticRoutes     1
    [... management x2, T1-Gateway-A trimmed ...]

  GET /api/network
    API  GET https://avi-ctrl.example.local/api/network?include_name=true&page_size=25
    nsx-10.0.151.0-avi-se-data
      uuid             network-00000010-1111-4222-8333-000000000010
      tenant           admin
      cloud            Demo NSX Cloud
      vrf              T1-Gateway-B
      dhcp             True
      subnets          10.0.151.0/24
    VRF-B-Vip-Network
      uuid             network-00000011-1111-4222-8333-000000000011
      tenant           admin
      cloud            Demo NSX Cloud
      vrf              T1-Gateway-B
      dhcp             False
      subnets          10.0.199.0/24
    [... 4 more networks trimmed ...]
```

</details>

### Reading this run

| Observation | What it tells you |
|---|---|
| `API version 32.1.2 (detected)` | `/api/initial-data` returned an empty version field, so detection fell through to `/api/cluster/version`. **Pin 32.1.2** in the ServiceNow pattern. |
| `2 tenant(s) visible: admin, Dev Team` | The account sees both tenants. Compare against a `-Tenant admin` run: virtual services go 4 → 5, because `Dev-WebServer-L7-Vs` lives in `Dev Team`. If ServiceNow is bound to `admin` only, that object is invisible to Discovery. |
| `poolgroup count = 0` | Nothing configured. Harmless, but confirm the pattern tolerates an empty collection. |
| `Default-Group x2`, `global x2`, `management x2` | Same names in `Default-Cloud` and `Demo NSX Cloud`. **Correlate CIs on UUID**, or on cloud + tenant + name. Name alone collapses these into single CIs. |
| `... 7 more not shown` | `-MaxDetail` truncation at 10 objects per endpoint. Raise it or use `-InventoryFile` for the complete set. |
| Every `API GET` line | The literal URI issued. Hand these to the ServiceNow team to reproduce a call by hand. |

### The tenant comparison worth running

```powershell
.\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.example.local -Tenant admin
.\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.example.local -Tenant '*'
```

In the run above this is a 4-vs-5 difference on virtual services, pools, and VsVips. On a production controller with many tenants the gap is usually much larger, and it is the difference between a Discovery run that looks successful and one that is actually complete.


---

## Reports

### Check report

```powershell
.\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.example.local -OutFile avi-cred-test.html
```

- **`.html`** — styled pass/fail table with an API call column. Best for attaching to a ticket or sending to a ServiceNow admin.
- **`.json`** — full nested structure including per-check data.
- **`.csv`** — summary rows only. CSV cannot represent nested objects, so object data is dropped by design.

### Object inventory

```powershell
.\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.example.local -InventoryFile avi-inventory.json
```

Normalized JSON of the configured objects, for diffing against ServiceNow CI records:

```json
{
  "generated": "2026-08-19T14:22:05-04:00",
  "controller": "https://avi-ctrl.example.local",
  "apiVersion": "32.1.2",
  "account": "snow-svc",
  "tenantScope": "admin",
  "objectCounts": { "virtualservice": 4, "pool": 4 },
  "apiCalls": {
    "virtualservice": ["https://avi-ctrl.example.local/api/virtualservice?include_name=true&page_size=200"]
  },
  "objects": {
    "virtualservice": [
      {
        "objectType": "virtualservice",
        "name": "WebServer-L7-Vs",
        "uuid": "virtualservice-8f2c-...",
        "tenant": "admin",
        "cloud": "Default-Cloud",
        "enabled": true,
        "pool": "WebServer-L7-Vs-Pool",
        "ipAddresses": ["10.0.140.50"],
        "services": [{ "port": 443, "ssl": true }]
      }
    ]
  }
}
```

`-InventoryFile` automatically enables full pagination, so the inventory is complete rather than first-page-only.

Object references are resolved to names. The script sends `include_name=true`, which makes the controller append `#friendly-name` to every `*_ref`, so you get `"pool": "WebServer-L7-Vs-Pool"` instead of a UUID URL.

---

## Common failure modes

These are the ones that actually generate tickets.

### 1. `X-Avi-Version` mismatch

A header newer than the controller returns **403** with a message that reads like a permissions problem. The script detects the real version in five tiers:

1. `-ApiVersion` if you supplied it
2. `/api/initial-data` (unauthenticated; the field is empty on some builds)
3. `/api/cluster/version` after login (authoritative)
4. A version parsed out of a 403 mismatch error, with one login retry
5. `-VersionFloor`

When no version is known yet, the header is **omitted** rather than guessed. Avi accepts a login with no `X-Avi-Version`; it rejects one that is too new.

**Action:** pin the detected version in the ServiceNow pattern.

### 2. Tenant scope

A read-only account bound to `admin` returns empty results for objects in other tenants. Discovery "succeeds" and finds nothing.

```powershell
.\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.example.local -Tenant admin
.\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.example.local -Tenant '*'
```

If the counts differ, the ServiceNow credential needs a role granted across tenants.

### 3. Java trust store vs PowerShell

`-SkipCertificateCheck` only relaxes .NET. **The MID Server uses Java**, so a self-signed or internal-CA controller certificate must still be imported into the MID Server's `cacerts` / agent keystore.

This is the single most common false positive: the PowerShell test passes and Discovery still fails on TLS.

### 4. Password expiry and account lockout

Avi local accounts support expiry and change-on-first-login. An account created interactively often carries the change flag, which returns **401** at `/login` with no obvious clue.

Avi's User Account Profile also locks an account after a threshold of failed logins (commonly 3) for a window (commonly 30 minutes). **While locked, the correct password still returns 401.** The message does not distinguish the two cases.

Check with an admin account before retrying, since each attempt can restart the lockout timer:

```powershell
(Invoke-RestMethod "https://avi-ctrl.example.local/api/user?name=snow-svc" -Headers $h -WebSession $s).results |
    Select-Object name, is_active, require_password_update_on_login, local
```

In the UI: **Administration > Accounts > Users**, plus the User Account Profile bound to that user.

### 5. Duplicate object names

Avi object names are unique **per cloud and per tenant**, not globally. It is normal to see two `Default-Group` SE Groups or two `global` VRF contexts in a multi-cloud deployment. The script flags these:

```
WARN  GET /api/serviceenginegroup  ... | duplicate names: Default-Group x2 (reconcile on uuid, not name)
```

If the ServiceNow pattern builds correlation IDs from name alone, those collapse into one CI. The correlation ID must be the Avi **UUID**, or a composite of cloud + tenant + name. Far easier to raise before the first full discovery than to de-duplicate CIs afterward.

---

## Suggested Avi role

A custom read-only role covering these object types is sufficient for inventory. No write or system access required.

```
VirtualService  Pool         PoolGroup    VsVip
ServiceEngine   ServiceEngineGroup        Cloud
HealthMonitor   VrfContext   Network
```

---

## Troubleshooting the script itself

Failures are reported distinctly so an HTTP problem is never confused with a script bug:

```
FAIL   GET /api/cloud   HTTP 403: ...
FAIL   GET /api/cloud   SCRIPT ERROR [System.ArgumentException] at line 312: ...
```

If you hit a `SCRIPT ERROR`, collect:

```powershell
$Error[0] | Format-List * -Force
$Error[0].ScriptStackTrace
```

---

## A note on field mappings

The inventory normalizer maps the fields a CMDB typically reconciles on. **Avi field names shift between versions.** If a field comes back null unexpectedly, use `-IncludeRaw` (or `-Show Full`) to see what it is actually called on your build:

```powershell
.\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.example.local `
    -InventoryFile out.json -IncludeRaw -Show Full
```

**Verified on 32.1.2:** all mapped fields populate correctly, including `mgmtIp` on service engines and `maxSes` / `vcpusPerSe` / `memoryPerSe` on service engine groups. Mappings on older builds (18.x, 20.x, 22.x) have not been verified; spot-check those two object types first if you run against one.

Two edge cases the normalizer handles deliberately:

- An NSX-T network can carry a subnet entry with no prefix, because addressing is managed upstream. Those are skipped rather than emitted as `/`.
- `port_range_end` equals `port` on a single-port service, so it is only shown when it describes an actual range.

---

## Security notes

- The script never writes a password to disk, and never accepts one as a plaintext parameter.
- It calls `POST /logout` on completion so sessions are not left open.
- Reports contain object names, UUIDs, IP addresses, and pool member addresses. Treat inventory files as infrastructure-sensitive and handle them accordingly before emailing them to a customer.
