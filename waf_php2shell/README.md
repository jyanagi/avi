# PHP2Shell virtual patch for Avi Load Balancer WAF

Two equivalent scripts that apply the PHP2Shell mitigations from Broadcom KB 460068 to an Avi Load Balancer WAF policy through the REST API. They let you virtually patch PHP web applications at the load balancer while the application and PHP runtime are being updated.

Reference: https://knowledge.broadcom.com/external/article/460068

| File | Runs on | Use when |
|---|---|---|
| `curl_php2shell.sh` | Linux, macOS, WSL (bash) | You work from a Linux or macOS shell |
| `powershell_php2shell.ps1` | Windows PowerShell 5.1 or PowerShell 7+ (Windows, Linux, macOS) | You work from Windows or prefer PowerShell |

Both scripts behave the same way. Pick one.

## Status and testing

These scripts have been tested and validated against Avi 32.1.4. When executing the scripts, run them against a lab or non-production controller first, use `--dry-run` / `-WhatIf` to review the planned change, and start with Detection mode if you want to watch for false positives before blocking (see [Choosing the mode](#choosing-the-mode)).

## What the scripts change

The scripts create or modify one WAF policy. Everything else in the policy is preserved.

**Step 1: enable these CRS rules in Enforcement mode**

| CRS group | Rule IDs | Purpose |
|---|---|---|
| `CRS_920_Protocol_Validation` | 920170, 920180, 920370, 920380 | Malformed or abnormal requests, argument and header limits |
| `CRS_932_Application_Attack_RCE` | 932100 to 932200 | Remote command execution payloads |
| `CRS_933_Application_Attack_PHP` | 933100 to 933190 | PHP code injection payloads |

The rules are enabled through `crs_overrides` on the policy. The groups and rule IDs are read from the CRS version the policy references. The script stops with an error if 920170, 920180, 920370 or 920380 is missing, or if no rule exists in the 932 or 933 ranges, which usually means the CRS version does not match the KB.

**Step 2: add four pre-CRS rules** in a group named `PHP2Shell-CVE-2026-109618-109619`

| Rule ID | Blocks |
|---|---|
| 200 | `PHPSESSID` submitted as a POST form field (session fixation) |
| 201 | `PHP_SESSION_UPLOAD_PROGRESS` values with unsafe characters |
| 202 | PHP open tags in upload filenames |
| 203 | Serialized PHP objects in upload filenames |

Other pre-CRS groups and other CRS overrides already on the policy are kept. Re-running the script replaces only its own group.

## Prerequisites

**Avi Load Balancer**
- A controller reachable over HTTPS from the machine that runs the script.
- An existing WAF profile and CRS version if you plan to create a new policy.
- An account that can read and write WAF policies in the target tenant. A dedicated account limited to WAF policy changes is recommended over `admin`.
- API version 30.2.1 is the default. Set `AVI_API_VERSION` (shell) or `-AviApiVersion` (PowerShell) if your controller differs. The script warns when the controller reports a different version.

**For `curl_php2shell.sh`**
- bash 3.2 or later (the macOS default works)
- curl 7.76 or later
- jq
- awk (any version)

Check:

```bash
bash --version | head -1
curl --version | head -1
jq --version
```

**For `powershell_php2shell.ps1`**
- Windows PowerShell 5.1 or PowerShell 7 or later
- On Linux or macOS with PowerShell 7: `chmod` must be available (it is by default)
- If script execution is restricted on Windows, allow it for the current session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
Unblock-File ./powershell_php2shell.ps1
```

**TLS trust.** Both scripts verify the controller certificate by default. If the controller uses a self-signed or private-CA certificate, either:
- shell: `export AVI_CACERT=/path/to/ca.pem`
- PowerShell: import the CA into the operating system trust store

Skipping verification is possible but not recommended (see [Security](#security)).

## Quick start (interactive)

The scripts prompt for everything they need, show a summary, and ask for confirmation before changing anything.

```bash
./curl_php2shell.sh
```

```powershell
./powershell_php2shell.ps1
```

The flow is:

1. Banner with the KB reference and a description of what will happen.
2. Controller address, username and password (the password is not echoed).
3. Select an existing WAF policy to modify, or choose to create a new one.
4. For a new policy: enter a name, then select a WAF profile and a CRS version.
5. Review screen with the full summary. Answer `y` to proceed. Answer `n` to go back: to the WAF profile menu when creating a policy, or to the policy menu when modifying one.
6. A backup is saved, the change is applied, and the result is verified.

### What a new policy gets

When you choose to create a new policy:

- Policy mode is Enforcement (`WAF_MODE_ENFORCEMENT`).
- The WAF profile and CRS version are the ones you select from the controller lists.
- Rule groups are inherited from the CRS version you select.
- Step 1 and Step 2 are then applied in Enforcement mode.
- Everything else stays at the controller defaults.

## Non-interactive use (automation)

Supply everything through environment variables or parameters. No banner or confirmation is shown when there is no terminal.

**Modify an existing policy**

```bash
export AVI_CONTROLLER=avi.example.com
export AVI_USER=waf-svc
export AVI_PASS='...'            # or leave unset to be prompted
export WAF_POLICY_NAME=My-WAF-Policy
./curl_php2shell.sh
```

```powershell
./powershell_php2shell.ps1 -AviController avi.example.com -Credential (Get-Credential) -WafPolicyName My-WAF-Policy
```

**Create a new policy**

```bash
CREATE_POLICY=true WAF_POLICY_NAME=PHP2Shell-Policy \
WAF_PROFILE_NAME=System-WAF-Profile WAF_CRS_NAME=CRS-2026-2 \
./curl_php2shell.sh
```

```powershell
./powershell_php2shell.ps1 -AviController avi.example.com -Credential (Get-Credential) `
  -CreatePolicy -WafPolicyName PHP2Shell-Policy -WafProfileName System-WAF-Profile -WafCrsName CRS-2026-2
```

## Options

| Purpose | `curl_php2shell.sh` | `powershell_php2shell.ps1` |
|---|---|---|
| Preview without writing | `--dry-run` or `DRY_RUN=true` | `-WhatIf` or `DRY_RUN=true` |
| Undo a previous run | `--restore FILE` | `-Restore FILE` |
| Help | `-h` | `Get-Help ./powershell_php2shell.ps1 -Full` |
| Controller | `AVI_CONTROLLER` | `-AviController` or `AVI_CONTROLLER` |
| Username | `AVI_USER` | `-AviUser`, `-Credential`, or `AVI_USER` |
| Password | `AVI_PASS` or prompt | `-Credential`, `-AviPass` (SecureString), `AVI_PASS`, or prompt |
| Tenant (default `admin`) | `AVI_TENANT` | `-AviTenant` or `AVI_TENANT` |
| API version (default `30.2.1`) | `AVI_API_VERSION` | `-AviApiVersion` or `AVI_API_VERSION` |
| Policy to modify or create | `WAF_POLICY_NAME` | `-WafPolicyName` or `WAF_POLICY_NAME` |
| Create a new policy | `CREATE_POLICY=true` | `-CreatePolicy` or `CREATE_POLICY=true` |
| WAF profile for a new policy | `WAF_PROFILE_NAME` | `-WafProfileName` or `WAF_PROFILE_NAME` |
| CRS version for a new policy | `WAF_CRS_NAME` | `-WafCrsName` or `WAF_CRS_NAME` |
| Mode of Step 2 rules | `RULE_MODE` | `-RuleMode` or `RULE_MODE` |
| Mode of Step 1 rules (and new policy mode) | `CRS_MODE` | `-CrsMode` or `CRS_MODE` |
| Step 1 only, leave pre-CRS groups alone | `CRS_ONLY=true` | `-CrsOnly` or `CRS_ONLY=true` |
| Name of the pre-CRS group | `GROUP_NAME` | `-GroupName` or `GROUP_NAME` |
| CA bundle for TLS verification | `AVI_CACERT=/path/ca.pem` | OS trust store |
| Skip TLS verification (not recommended) | `AVI_INSECURE=true` | `-SkipCertificateCheck` or `AVI_INSECURE=true` |
| Request timeout in seconds (default 30) | `AVI_TIMEOUT` | `-TimeoutSec` |
| Backup directory (default current directory) | `BACKUP_DIR` | `-BackupDir` |

### Choosing the mode

`RULE_MODE` and `CRS_MODE` accept `WAF_MODE_ENFORCEMENT` (block) or `WAF_MODE_DETECTION_ONLY` (log only). Both default to Enforcement. To observe traffic before blocking:

```bash
RULE_MODE=WAF_MODE_DETECTION_ONLY CRS_MODE=WAF_MODE_DETECTION_ONLY ./curl_php2shell.sh
```

Re-run with the defaults once you are satisfied. Note that the mode of a rule only takes effect as an enforcement override when the policy itself allows it; the script does not change the mode of an existing policy.

## Preview, backup and undo

**Preview.** Shows the exact change and writes nothing:

```bash
./curl_php2shell.sh --dry-run
```

```powershell
./powershell_php2shell.ps1 -WhatIf
```

**Backup.** Before every change to an existing policy, the script saves its current JSON to `waf-backup-<policy>-<timestamp>.json` in `BACKUP_DIR` (default: current directory). The file is readable only by you. Keep it with your change record.

**Undo.** Restores `crs_overrides` and `pre_crs_groups` from a backup:

```bash
./curl_php2shell.sh --restore ./waf-backup-My-WAF-Policy-20260101-120000.json
```

```powershell
./powershell_php2shell.ps1 -Restore ./waf-backup-My-WAF-Policy-20260101-120000.json
```

## Built-in safety checks

- Nothing is written until you confirm the review screen (interactive) or the run is non-interactive.
- If the policy already has the settings, no change is made.
- If someone else changed the policy while the script was running, the script refuses to write and asks you to run it again.
- After the change, the script reads the policy back and confirms every requested setting. If it does not match, the script exits with an error and prints the restore command.
- A policy created by a run is deleted again if a later step fails, so no half-configured policy is left behind.
- The Avi session is logged out when the script ends.

## After the script runs

1. Confirm the policy is attached to each virtual service that serves the PHP application. The scripts change the policy only; they do not attach it to a virtual service. In the Avi UI, edit the virtual service and select the WAF policy, or verify it is already selected.
2. Send test traffic and review the WAF logs for false positives, especially for applications that legitimately post `PHPSESSID` or use upload progress tracking.
3. Keep patching the application and PHP runtime. This is a virtual patch, not a fix for the underlying vulnerability.

## Security

- TLS certificates are verified by default. `AVI_INSECURE=true` or `-SkipCertificateCheck` disables verification and exposes the credentials and session to interception. Use `AVI_CACERT` or the OS trust store instead.
- The shell script sends the password to curl over stdin and unsets it after login. Session headers are passed through a private temporary file, not on the command line. Tracing is disabled while it runs.
- The PowerShell script clears the plaintext password after login and removes `AVI_PASS` from the environment. Prefer `-Credential` or the prompt over typing a password on the command line, where it is saved in shell history.
- Avoid putting `AVI_PASS` in scripts or shell profiles. Use a secret store or the interactive prompt.
- Use a dedicated account with a role limited to WAF policy changes.
- The controller address, tenant, API version and modes are validated before use. The scripts only follow object references that point to the controller you signed in to.
- Backup files contain your policy configuration. Store them accordingly.

## Troubleshooting

| Message | Meaning and fix |
|---|---|
| Certificate could not be verified | Provide the CA with `AVI_CACERT`, import it into the OS trust store, or as a last resort use the insecure option |
| `Login to ... failed` | Check the controller address, credentials, tenant and network access to port 443 |
| `Avi API call failed ... Response: ...` | The controller rejected a request. The `Response` text is the controller's own message |
| `CRS rules not found in group CRS_920_Protocol_Validation` | The CRS version does not contain the expected rule IDs or group names. Choose the CRS version named in the KB |
| `No rules 932100-932200 found ...` or `933100-933190` | Same cause as above for the RCE and PHP groups |
| `The policy was changed by someone else ...` | Another admin or automation edited the policy. Nothing was written. Run the script again |
| `Verification failed ...` | The controller does not report every setting. Use the printed restore command, then check the policy and API version in the Avi UI |
| `Controller reports version X but the API version header is Y` | Set `AVI_API_VERSION` or `-AviApiVersion` to the controller version |
| `curl 7.76 or later is required` | Upgrade curl |
| Menu shows only some policies | The scripts follow pagination; confirm you are using the tenant that owns the policies (`AVI_TENANT`) |

## Limitations

- One WAF policy is changed per run. Run the script again for each additional policy.
- IPv6 literal controller addresses are not accepted. Use a hostname or IPv4 address.
- The scripts rely on the `crs_overrides` field of the WAF policy and the per-rule `mode` value inside it. The older `crs_groups` field is deprecated since Avi 20.1.6 and is not used. If your controller rejects the override format, the controller's message is printed.
- The mode of an existing policy is never changed.
