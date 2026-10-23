<#
.SYNOPSIS
  Applies the PHP2Shell mitigations from Broadcom KB 460068 to an Avi WAF policy via the REST API.

.DESCRIPTION
  Reference: https://knowledge.broadcom.com/external/article/460068

  Step 1  Enables these CRS rules in Enforcement mode (via crs_overrides):
            CRS_920_Protocol_Validation        920170, 920180, 920370, 920380
            CRS_932_Application_Attack_RCE     932100 - 932200
            CRS_933_Application_Attack_PHP     933100 - 933190
  Step 2  Adds the four PHP2Shell pre-CRS rules (IDs 200 to 203).

  You can modify an existing WAF policy or create a new one. Existing settings, other CRS
  overrides and other pre-CRS groups are kept.

  If you create a new policy, these defaults apply:
    - Policy mode:      Enforcement (WAF_MODE_ENFORCEMENT)
    - WAF profile/CRS:  the ones you choose from the controller lists
    - Rule groups:      inherited from the CRS version you choose
    - Step 1 and 2:     applied as described above, in Enforcement mode
    - Everything else:  left at the controller defaults

  Interactive runs prompt for anything not supplied and end with a review step. Answering n at the
  review goes back (to the WAF profile menu when creating a policy, or to the policy menu when
  modifying one). Nothing is changed on the controller until you confirm.

  Safety features:
    - A backup of the policy is saved (access limited to you) before any change. Use -Restore to undo.
    - -WhatIf shows the planned change and writes nothing.
    - The change is skipped if the policy already has the settings, and refused if someone else
      changed the policy while the script was running.
    - After the change the script checks that the controller reports every requested setting.

  Security notes:
    - TLS certificates are verified by default. Import the controller CA into the OS trust store, or
      use -SkipCertificateCheck as an explicit opt-in (not recommended).
    - Prefer -Credential or the interactive prompt. A password typed on a command line ends up in
      shell history. AVI_PASS is cleared from the environment after login.
    - Use a dedicated Avi account whose role is limited to WAF policy changes, not "admin".

  Environment variables (optional): AVI_CONTROLLER, AVI_USER, AVI_PASS, AVI_TENANT, AVI_API_VERSION,
  WAF_POLICY_NAME, CREATE_POLICY=true, WAF_PROFILE_NAME, WAF_CRS_NAME, RULE_MODE, CRS_MODE,
  CRS_ONLY=true, GROUP_NAME, AVI_INSECURE=true, DRY_RUN=true.

.PARAMETER Credential
  Avi credentials (for example from Get-Credential). Takes precedence over -AviUser / -AviPass.

.PARAMETER SkipCertificateCheck
  Do not verify the controller certificate. Credentials and the session can be intercepted.

.PARAMETER Restore
  Path to a backup file written by an earlier run; puts crs_overrides and pre_crs_groups back.

.EXAMPLE
  ./powershell_php2shell.ps1

.EXAMPLE
  ./powershell_php2shell.ps1 -AviController 10.1.1.10 -Credential (Get-Credential) -WafPolicyName MyPolicy -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AviController = $env:AVI_CONTROLLER,
    [string]$AviUser       = $env:AVI_USER,
    [SecureString]$AviPass,
    [PSCredential]$Credential,
    [string]$AviTenant     = $(if ($env:AVI_TENANT) { $env:AVI_TENANT } else { 'admin' }),
    [string]$AviApiVersion = $(if ($env:AVI_API_VERSION) { $env:AVI_API_VERSION } else { '30.2.1' }),
    [string]$WafPolicyName = $env:WAF_POLICY_NAME,
    [switch]$CreatePolicy,
    [string]$WafProfileName = $env:WAF_PROFILE_NAME,
    [string]$WafCrsName     = $env:WAF_CRS_NAME,
    [string]$RuleMode = $(if ($env:RULE_MODE) { $env:RULE_MODE } else { 'WAF_MODE_ENFORCEMENT' }),   # mode of the Step 2 rules
    [string]$CrsMode  = $(if ($env:CRS_MODE) { $env:CRS_MODE } else { 'WAF_MODE_ENFORCEMENT' }),     # mode forced on the Step 1 rules
    [switch]$CrsOnly,                       # only touch crs_overrides, leave pre_crs_groups alone
    [string]$GroupName = $(if ($env:GROUP_NAME) { $env:GROUP_NAME } else { 'PHP2Shell-CVE-2026-109618-109619' }),
    [switch]$SkipCertificateCheck,
    [ValidateRange(5, 600)][int]$TimeoutSec = 30,
    [string]$BackupDir = '.',
    [string]$Restore
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'5.1') { throw 'PowerShell 5.1 or later is required' }

# -WhatIf means dry run. Cleared afterwards so it does not affect other cmdlets used by this script.
$DryRun = [bool]$WhatIfPreference -or ($env:DRY_RUN -eq 'true')
$WhatIfPreference = $false
if ($env:CREATE_POLICY -eq 'true') { $CreatePolicy = [switch]::new($true) }
if ($env:CRS_ONLY -eq 'true')      { $CrsOnly = [switch]::new($true) }
if ($env:AVI_INSECURE -eq 'true')  { $SkipCertificateCheck = [switch]::new($true) }

# ---- Input validation (values end up in URLs and HTTP headers) ----
foreach ($m in @(@('RuleMode', $RuleMode), @('CrsMode', $CrsMode))) {
    if ($m[1] -notin 'WAF_MODE_ENFORCEMENT', 'WAF_MODE_DETECTION_ONLY') {
        throw "$($m[0]) must be WAF_MODE_ENFORCEMENT or WAF_MODE_DETECTION_ONLY (got '$($m[1])')"
    }
}
if ($AviTenant -notmatch '^[A-Za-z0-9_.-]+$')               { throw 'AviTenant has an invalid value' }
if ($AviApiVersion -notmatch '^[0-9]+(\.[0-9]+){1,3}$')     { throw 'AviApiVersion has an invalid value' }

# ---- Console helpers ----
$Interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
$KbUrl = 'https://knowledge.broadcom.com/external/article/460068'
$Rule  = '=' * 70

function Write-Say([string]$Text = '') { Write-Host "  $Text" }
function Write-Blank { Write-Host '' }
function Write-Heading([string]$Text) {
    Write-Host ''
    Write-Host $Rule
    Write-Host "  $Text"
    Write-Host $Rule
    Write-Host ''
}

# Returns $true for yes, $false for no
function Confirm-Choice([string]$Question) {
    while ($true) {
        $a = Read-Host "  $Question [y/n]"
        if ($a -match '^(y|yes)$') { return $true }
        if ($a -match '^(n|no)$')  { return $false }
        Write-Say 'Please answer y or n.'
    }
}

# Shows a numbered menu and returns the selected item
function Select-FromList([string]$Title, [string[]]$Items) {
    Write-Say $Title
    Write-Blank
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ('    {0,2}) {1}' -f ($i + 1), $Items[$i]) }
    Write-Blank
    while ($true) {
        $n = Read-Host "  Select [1-$($Items.Count)]"
        if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $Items.Count) { return $Items[[int]$n - 1] }
        Write-Say "Enter a number between 1 and $($Items.Count)."
    }
}

if ($Interactive -and -not $Restore) {
    Write-Heading 'PHP2Shell WAF protection for Avi Load Balancer'
    Write-Say "Reference: $KbUrl"
    Write-Blank
    Write-Say 'This script applies the mitigations from the KB article above'
    Write-Say '(CVE-2026-109618 and CVE-2026-109619) to an Avi WAF policy:'
    Write-Blank
    Write-Say '  Step 1  Enables these CRS rules in Enforcement mode:'
    Write-Say '            CRS_920_Protocol_Validation          920170, 920180, 920370, 920380'
    Write-Say '            CRS_932_Application_Attack_RCE       932100 - 932200'
    Write-Say '            CRS_933_Application_Attack_PHP       933100 - 933190'
    Write-Blank
    Write-Say '  Step 2  Adds four pre-CRS rules (IDs 200 to 203) that block PHPSESSID'
    Write-Say '          in POST bodies, unsafe PHP_SESSION_UPLOAD_PROGRESS values, PHP open'
    Write-Say '          tags in upload filenames, and serialized objects in filenames.'
    Write-Blank
    Write-Say 'You can modify an existing WAF policy or create a new one.'
    Write-Say 'Existing settings, other CRS overrides and other pre-CRS groups are kept.'
    Write-Blank
    Write-Say 'If you create a new policy, these defaults apply:'
    Write-Say '  - Policy mode:      Enforcement (WAF_MODE_ENFORCEMENT)'
    Write-Say '  - WAF profile/CRS:  the ones you choose from the controller lists'
    Write-Say '  - Rule groups:      inherited from the CRS version you choose'
    Write-Say '  - Step 1 and 2:     applied as described above, in Enforcement mode'
    Write-Say '  - Everything else:  left at the controller defaults'
    Write-Blank
    Write-Say 'A backup of the policy is saved before any change (undo with -Restore).'
    Write-Say 'Nothing is changed on the controller until you confirm a summary.'
}
if ($Interactive) { Write-Heading 'Connect to the Avi controller' }

# ---- Controller and credentials: parameters / environment, otherwise prompted ----
function Read-Required([string]$Current, [string]$Prompt, [string]$Name) {
    if ($Current) { return $Current }
    if (-not $Interactive) { throw "$Name is not set and there is no terminal to prompt on" }
    $v = Read-Host $Prompt
    if (-not $v) { throw "$Name cannot be empty" }
    return $v
}
$AviController = Read-Required $AviController 'Avi controller (IP or hostname, e.g. 10.1.1.10)' 'AviController'
# Hostname or IPv4 with an optional port; blocks '@', '/', '?' and similar that would redirect the credentials
if ($AviController -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$') { throw 'AviController has an invalid value' }

if ($Credential) {
    $AviUser = $Credential.UserName
    $AviPass = $Credential.Password
} else {
    $AviUser = Read-Required $AviUser 'Avi username' 'AviUser'
    if (-not $AviPass) {
        if ($env:AVI_PASS) { $AviPass = ConvertTo-SecureString $env:AVI_PASS -AsPlainText -Force }
        elseif ($Interactive) { $AviPass = Read-Host 'Avi password' -AsSecureString }
        else { throw 'No password: use -Credential, -AviPass, AVI_PASS or an interactive session' }
    }
}
[Environment]::SetEnvironmentVariable('AVI_PASS', $null)   # do not leave it in the environment of child processes

$Base = "https://$AviController"

# ---- TLS: verified by default. Skipping verification is an explicit opt-in. ----
$Common = @{ TimeoutSec = $TimeoutSec }
$PrevCertPolicy = $null
$CertPolicyChanged = $false
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
if ($SkipCertificateCheck) {
    Write-Warning 'TLS certificate verification is DISABLED. Credentials and the session can be intercepted.'
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $Common['SkipCertificateCheck'] = $true
    } else {
        # Windows PowerShell 5.1 only has a process-wide setting. It is restored in the finally block below.
        if (-not ('TrustAllCertsPolicy' -as [type])) {
            Add-Type @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
'@
        }
        $PrevCertPolicy = [Net.ServicePointManager]::CertificatePolicy
        [Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        $CertPolicyChanged = $true
    }
}

function Write-TlsHint([string]$Message) {
    if ($Message -match 'SSL|TLS|certificate|trust|secure channel') {
        Write-Host '  The controller certificate could not be verified.' -ForegroundColor Yellow
        Write-Host '  Import the controller CA into the OS trust store, or use -SkipCertificateCheck (not recommended).' -ForegroundColor Yellow
    }
}

# Calls the Avi API. On failure, throws with the HTTP status and the error body returned by Avi.
$script:Session = $null
$script:Headers = @{}
function Invoke-Avi {
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Uri, $Body)
    $p = @{ Method = $Method; Uri = $Uri; WebSession = $script:Session; Headers = $script:Headers } + $Common
    if ($null -ne $Body) {
        $p['Body'] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 30 -Compress }
        $p['ContentType'] = 'application/json'
    }
    try {
        Invoke-RestMethod @p
    } catch {
        $detail = $null
        if ($_.ErrorDetails) { $detail = $_.ErrorDetails.Message }
        if (-not $detail -and $_.Exception.Response -and $_.Exception.Response.GetResponseStream) {
            try { $detail = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
        }
        Write-TlsHint $_.Exception.Message
        $msg = "Avi API call failed: $Method $Uri`n$($_.Exception.Message)"
        if ($detail) { $msg += "`nResponse: $detail" }
        throw $msg
    }
}

# All object names of a type, following pagination
function Get-AviNames([string]$Type) {
    $names = @(); $page = 1
    while ($true) {
        $r = Invoke-Avi -Uri "$Base/api/${Type}?fields=name&page_size=200&page=$page"
        $names += @($r.results | ForEach-Object { $_.name })
        if (-not ($r.PSObject.Properties['next'] -and $r.next)) { break }
        $page++
    }
    @($names | Sort-Object)
}
function Escape([string]$s) { [uri]::EscapeDataString($s) }
function Get-Prop($Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties[$Name].Value }
}

# Only follow object references on the controller we logged in to: the session headers are sent
# with every call, so a reference to another host must never be fetched.
function Resolve-SafeRef([string]$Ref) {
    if ($Ref.StartsWith("$Base/api/", [StringComparison]::OrdinalIgnoreCase)) { return $Ref }
    if ($Ref.StartsWith('/api/')) { return "$Base$Ref" }
    throw "Refusing to follow a reference outside ${Base}: $Ref"
}
# The CRS rule groups (ref is an object URL, or a ?name= query)
function Get-CrsGroups([string]$Ref) {
    $r = Invoke-Avi -Uri (Resolve-SafeRef $Ref)
    if ($r.PSObject.Properties['results']) { if (@($r.results).Count -gt 0) { @($r.results[0].groups) } }
    else { @($r.groups) }
}

# Canonical form (sorted keys) so two policy snapshots can be compared reliably
function ConvertTo-Canonical($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}; foreach ($k in ($o.Keys | Sort-Object)) { $h[$k] = ConvertTo-Canonical $o[$k] }; return $h
    }
    if ($o -is [pscustomobject]) {
        $h = [ordered]@{}; foreach ($p in ($o.PSObject.Properties | Sort-Object Name)) { $h[$p.Name] = ConvertTo-Canonical $p.Value }; return $h
    }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) {
        return , @($o | ForEach-Object { ConvertTo-Canonical $_ })
    }
    return $o
}
# The two fields this script changes, as a comparable string
function Get-PolicyState($Policy) {
    $s = [ordered]@{ c = @(Get-Prop $Policy 'crs_overrides' | Where-Object { $_ }) }
    if (-not $CrsOnly) { $s['p'] = @(Get-Prop $Policy 'pre_crs_groups' | Where-Object { $_ }) }
    (ConvertTo-Canonical $s) | ConvertTo-Json -Depth 30 -Compress
}

# Restrict a file to the current user (it contains the policy; created empty first, then written)
function New-PrivateFile([string]$Path, [string]$Content) {
    $null = New-Item -ItemType File -Path $Path -Force
    if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        $null = & icacls.exe $Path /inheritance:r /grant:r "$($env:USERNAME):(R,W)"
    } else {
        & chmod 600 $Path
    }
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $Content)
}

$CreatedUuid = $null
$LoggedIn = $false
$script:Failed = $false

try {
    # 1. Login. The password is only held in the request body for the call, then cleared.
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AviPass)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $plain) { throw 'Password cannot be empty' }
    $loginBody = @{ username = $AviUser; password = $plain } | ConvertTo-Json -Compress
    $plain = $null
    $loginParams = @{ Method = 'Post'; Uri = "$Base/login"; Body = $loginBody; ContentType = 'application/json';
                      SessionVariable = 'AviSession' } + $Common
    try { $null = Invoke-RestMethod @loginParams }
    catch { Write-TlsHint $_.Exception.Message; throw "Login to $AviController failed: $($_.Exception.Message)" }
    finally { $loginBody = $null; $loginParams = $null; $AviPass.Dispose(); $AviPass = $null; [GC]::Collect() }
    $LoggedIn = $true
    $script:Session = $AviSession
    $csrf = ($script:Session.Cookies.GetCookies($Base) | Where-Object { $_.Name -eq 'csrftoken' } | Select-Object -First 1).Value
    if (-not $csrf -or $csrf -notmatch '^[A-Za-z0-9]+$') { throw 'No valid csrftoken received' }
    $script:Headers = @{
        'X-Avi-Version' = $AviApiVersion
        'X-Avi-Tenant'  = $AviTenant
        'X-CSRFToken'   = $csrf
        'Referer'       = $Base
    }

    # Best effort: warn if the API version does not match the controller
    try {
        $ctrlVer = (Invoke-Avi -Uri "$Base/api/initial-data").version.Version
        if ($ctrlVer -and $ctrlVer -ne $AviApiVersion) {
            Write-Warning "Controller reports version $ctrlVer but the API version header is $AviApiVersion (use -AviApiVersion to match)."
        }
    } catch {}
    if ($Interactive -and $AviUser -eq 'admin') {
        Write-Say "Note: you are signed in as 'admin'. A dedicated account limited to WAF policy changes is safer."
    }

    # ---- Restore mode ----
    if ($Restore) {
        if (-not (Test-Path -LiteralPath $Restore)) { throw "Backup file '$Restore' not found" }
        $backup = Get-Content -LiteralPath $Restore -Raw | ConvertFrom-Json
        if (-not $backup.name) { throw 'Backup file has no policy name' }
        $found = Invoke-Avi -Uri "$Base/api/wafpolicy?name=$(Escape $backup.name)"
        if (-not $found.results -or @($found.results).Count -eq 0) { throw "WAF policy '$($backup.name)' not found on $AviController" }
        $ruuid = @($found.results)[0].uuid
        $restoreBody = @{ replace = [ordered]@{
            crs_overrides  = @(Get-Prop $backup 'crs_overrides' | Where-Object { $_ })
            pre_crs_groups = @(Get-Prop $backup 'pre_crs_groups' | Where-Object { $_ })
        } }
        if ($Interactive) {
            Write-Heading 'Restore a WAF policy from backup'
            Write-Say "Controller:    $AviController (tenant $AviTenant)"
            Write-Say "Policy name:   $($backup.name)"
            Write-Say "Backup file:   $Restore"
            Write-Blank
            Write-Say 'crs_overrides and pre_crs_groups will be set back to the values in the backup.'
            Write-Blank
            if (-not (Confirm-Choice 'Proceed with the restore?')) { Write-Say 'Cancelled.'; return }
        }
        if ($DryRun) { Write-Say 'Dry run: nothing written. Planned change:'; $restoreBody | ConvertTo-Json -Depth 30; return }
        $null = Invoke-Avi -Method Patch -Uri "$Base/api/wafpolicy/$ruuid" -Body $restoreBody
        Write-Say "Restored '$($backup.name)' from $Restore"
        return
    }

    # 2. Pick the WAF policy: modify an existing one, or create a new one
    $Uuid = $null
    $newLabel = '<create a new policy>'
    while ($true) {
        if (-not $WafPolicyName -and -not $CreatePolicy) {
            if (-not $Interactive) { throw 'Set -WafPolicyName (or -CreatePolicy -WafPolicyName <new>) when not interactive' }
            Write-Heading 'Select a WAF policy'
            $policies = @(Get-AviNames 'wafpolicy')
            $sel = Select-FromList "WAF policies on $AviController (tenant $AviTenant). Choose one to modify, or create a new one:" ($policies + $newLabel)
            if ($sel -eq $newLabel) { $CreatePolicy = [switch]::new($true) } else { $WafPolicyName = $sel }
        }

        if ($CreatePolicy) {
            if (-not $WafPolicyName) {
                if (-not $Interactive) { throw '-WafPolicyName is required to create a policy' }
                Write-Heading 'Name the new WAF policy'
                $WafPolicyName = Read-Host '  Name for the new WAF policy'
                if (-not $WafPolicyName) { throw 'Name cannot be empty' }
            }
            $exists = Invoke-Avi -Uri "$Base/api/wafpolicy?name=$(Escape $WafPolicyName)"
            if ($exists.count -ne 0) { throw "WAF policy '$WafPolicyName' already exists" }
            if (-not $WafProfileName) {
                Write-Heading 'Select a WAF profile'
                $list = @(Get-AviNames 'wafprofile')
                if ($list.Count -eq 0) { throw 'No WAF profiles found; create one first' }
                $WafProfileName = Select-FromList "WAF profiles on ${AviController}:" $list
            }
            if (-not $WafCrsName) {
                Write-Heading 'Select a CRS version'
                $list = @(Get-AviNames 'wafcrs')
                if ($list.Count -eq 0) { throw 'No WAF CRS versions found' }
                $WafCrsName = Select-FromList "Core Rule Set versions on ${AviController}:" $list
            }
            if ($Interactive) {
                Write-Heading 'Review: create a new WAF policy'
                Write-Say "Controller:    $AviController (tenant $AviTenant)"
                Write-Say "Policy name:   $WafPolicyName  (new)"
                Write-Say "WAF profile:   $WafProfileName"
                Write-Say "CRS version:   $WafCrsName"
                Write-Say "Policy mode:   $CrsMode"
                if ($DryRun) { Write-Say 'Dry run:       nothing will be written' }
                Write-Blank
                Write-Say "Then, as described in $KbUrl :"
                Write-Say "  Step 1  Enable the CRS rules listed above, mode $CrsMode"
                if (-not $CrsOnly) { Write-Say "  Step 2  Add pre-CRS group '$GroupName' (rules 200 to 203), mode $RuleMode" }
                Write-Blank
            }
        } else {
            $found = Invoke-Avi -Uri "$Base/api/wafpolicy?name=$(Escape $WafPolicyName)"
            if (-not $found.results -or @($found.results).Count -eq 0) { throw "WAF policy '$WafPolicyName' not found" }
            $Uuid = @($found.results)[0].uuid
            if ($Interactive) {
                Write-Heading 'Review: modify an existing WAF policy'
                Write-Say "Controller:    $AviController (tenant $AviTenant)"
                Write-Say "Policy name:   $WafPolicyName"
                Write-Say 'Policy mode:   unchanged'
                if ($DryRun) { Write-Say 'Dry run:       nothing will be written' }
                Write-Blank
                Write-Say "As described in $KbUrl :"
                Write-Say "  Step 1  Enable the CRS rules listed above, mode $CrsMode"
                if (-not $CrsOnly) { Write-Say "  Step 2  Add pre-CRS group '$GroupName' (rules 200 to 203), mode $RuleMode" }
                Write-Say 'Other CRS overrides and pre-CRS groups are kept. A backup is saved first.'
                Write-Blank
            }
        }

        if (-not $Interactive) { break }
        if (Confirm-Choice 'Proceed with these settings?') { break }
        Write-Blank
        if ($CreatePolicy) {
            Write-Say 'Returning to the WAF profile selection.'
            $WafProfileName = ''; $WafCrsName = ''
        } else {
            Write-Say 'Returning to the WAF policy selection.'
            $WafPolicyName = ''; $Uuid = $null
        }
    }

    if ($CreatePolicy -and -not $DryRun) {
        if ($Interactive) { Write-Heading 'Applying changes'; Write-Say "Creating WAF policy '$WafPolicyName'"; Write-Blank }
        # The rule groups come from the referenced CRS object (crs_groups is deprecated since 20.1.6).
        $created = Invoke-Avi -Method Post -Uri "$Base/api/wafpolicy" -Body @{
            name            = $WafPolicyName
            mode            = $CrsMode
            waf_profile_ref = "/api/wafprofile?name=$(Escape $WafProfileName)"
            waf_crs_ref     = "/api/wafcrs?name=$(Escape $WafCrsName)"
        }
        if (-not $created.uuid) { throw 'Policy creation failed' }
        $Uuid = $created.uuid
        $CreatedUuid = $Uuid
    } elseif ($Interactive) {
        Write-Heading 'Applying changes'
    }

    # 3. Step 2 rules, verbatim from the KB (chained rules are newline-separated)
    $R200 = @'
SecRule REQUEST_METHOD "@streq POST" "id:200, phase:2, deny, status:403, t:none, tag:'CVE-2026-109618', tag:'CVE-2026-109619', msg:'PHP2Shell: PHPSESSID submitted as POST form field (session fixation)', severity:'CRITICAL', chain"
SecRule ARGS_NAMES "@streq phpsessid" "t:none, t:lowercase"
'@
    $R201 = @'
SecRule REQUEST_METHOD "@streq POST" "id:201, phase:2, deny, status:403, t:none, tag:'CVE-2026-109618', tag:'CVE-2026-109619', msg:'PHP2Shell: PHP_SESSION_UPLOAD_PROGRESS value contains unsafe characters', severity:'CRITICAL', chain"
SecRule ARGS:PHP_SESSION_UPLOAD_PROGRESS "!@rx ^[a-zA-Z0-9_.-]+$" "t:none"
'@
    $R202 = @'
SecRule FILES "@rx <\?(?:php|=)" "id:202, phase:2, deny, status:403, t:none, t:lowercase, tag:'CVE-2026-109618', msg:'PHP2Shell: PHP open tag in upload filename', severity:'CRITICAL'"
'@
    $R203 = @'
SecRule FILES "@rx [|;](?:O|C|a|s):\d+:" "id:203, phase:2, deny, status:403, t:none, tag:'CVE-2026-109619', msg:'PHP2Shell: Serialized PHP object in upload filename', severity:'CRITICAL'"
'@
    # Here-strings use the platform line ending; Avi expects "\n" between chained rules
    $R200, $R201, $R202, $R203 = @($R200, $R201, $R202, $R203) | ForEach-Object { ($_ -replace "`r`n", "`n").Trim() }

    # 4. Build the PATCH: pre-CRS group (existing ones kept) + crs_overrides for the Step 1 rules.
    #    The CRS rule groups/IDs are read from the policy's waf_crs_ref; existing crs_overrides are preserved.
    if ($Uuid) {
        $cur = Invoke-Avi -Uri "$Base/api/wafpolicy/$Uuid"
        $crsRef = Get-Prop $cur 'waf_crs_ref'
    } else {    # dry run of a policy that would be created: nothing exists yet, read the CRS directly
        $cur = [pscustomobject]@{}
        $crsRef = "/api/wafcrs?name=$(Escape $WafCrsName)"
    }
    if (-not $crsRef) { throw 'Policy has no waf_crs_ref' }
    $groups = @(Get-CrsGroups $crsRef | Where-Object { $_ })
    if ($groups.Count -eq 0) { throw "The policy's CRS version has no rule groups" }

    # Backup of the policy before any change (access limited to the current user). Undo with -Restore.
    $BackupFile = $null
    if ($Uuid -and -not $DryRun) {
        $null = New-Item -ItemType Directory -Path $BackupDir -Force
        $safeName = $WafPolicyName -replace '[^A-Za-z0-9_.-]', '_'
        $BackupFile = Join-Path $BackupDir ("waf-backup-{0}-{1}.json" -f $safeName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-PrivateFile $BackupFile ($cur | ConvertTo-Json -Depth 30)
        if ($Interactive) { Write-Say "Backup saved: $BackupFile"; Write-Blank }
    }

    # Step 1 rules by group: 920170/920180/920370/920380 in CRS_920_Protocol_Validation,
    # 932100-932200 in CRS_932_Application_Attack_RCE, 933100-933190 in CRS_933_Application_Attack_PHP
    function Test-InScope([string]$Group, $RuleId) {
        $n = 0
        if (-not [int]::TryParse([string]$RuleId, [ref]$n)) { return $false }
        switch ($Group.ToLowerInvariant()) {
            'crs_920_protocol_validation'      { return (@(920170, 920180, 920370, 920380) -contains $n) }
            'crs_932_application_attack_rce'   { return ($n -ge 932100 -and $n -le 932200) }
            'crs_933_application_attack_php'   { return ($n -ge 933100 -and $n -le 933190) }
            default                            { return $false }
        }
    }

    $have = @()
    $targets = @()
    foreach ($g in $groups) {
        $ids = @($g.rules | Where-Object { $_ -and (Test-InScope $g.name $_.rule_id) } | ForEach-Object { [string]$_.rule_id })
        if ($ids.Count -gt 0) {
            $targets += [pscustomobject]@{ name = $g.name; ids = $ids }
            $have += $ids | ForEach-Object { [int]$_ }
        }
    }
    $missing = @(920170, 920180, 920370, 920380 | Where-Object { $have -notcontains $_ })
    if ($missing.Count -gt 0) { throw "CRS rules not found in group CRS_920_Protocol_Validation: $($missing -join ',')" }
    if (@($have | Where-Object { $_ -ge 932100 -and $_ -le 932200 }).Count -eq 0) { throw 'No rules 932100-932200 found in group CRS_932_Application_Attack_RCE' }
    if (@($have | Where-Object { $_ -ge 933100 -and $_ -le 933190 }).Count -eq 0) { throw 'No rules 933100-933190 found in group CRS_933_Application_Attack_PHP' }

    # crs_overrides: keep unrelated entries as they are; merge ours into the entries for the three groups
    $existing = @(Get-Prop $cur 'crs_overrides' | Where-Object { $_ })
    $targetNames = @($targets | ForEach-Object { $_.name })
    $overrides = @($existing | Where-Object { $targetNames -notcontains $_.name })
    foreach ($t in $targets) {
        $entry = [ordered]@{ name = $t.name }
        $old = $existing | Where-Object { $_.name -eq $t.name } | Select-Object -First 1
        if ($old) { foreach ($prop in $old.PSObject.Properties) { $entry[$prop.Name] = $prop.Value } }
        $kept = @(Get-Prop $old 'rule_overrides' | Where-Object { $_ -and ($t.ids -notcontains [string]$_.rule_id) })
        $ours = @($t.ids | ForEach-Object { [ordered]@{ rule_id = $_; enable = $true; mode = $CrsMode } })
        $entry['enable'] = $true
        $entry['rule_overrides'] = @($kept + $ours)
        $overrides += $entry
    }

    $replace = [ordered]@{ crs_overrides = @($overrides) }
    if (-not $CrsOnly) {
        $others = @(Get-Prop $cur 'pre_crs_groups' | Where-Object { $_ -and $_.name -ne $GroupName })
        $newGroup = [ordered]@{
            name = $GroupName; enable = $true; index = $others.Count
            rules = @(
                [ordered]@{ index = 0; name = 'php2shell-200-phpsessid-post';              rule = $R200; enable = $true; mode = $RuleMode },
                [ordered]@{ index = 1; name = 'php2shell-201-upload-progress-chars';       rule = $R201; enable = $true; mode = $RuleMode },
                [ordered]@{ index = 2; name = 'php2shell-202-php-open-tag-filename';       rule = $R202; enable = $true; mode = $RuleMode },
                [ordered]@{ index = 3; name = 'php2shell-203-serialized-object-filename';  rule = $R203; enable = $true; mode = $RuleMode }
            )
        }
        $replace['pre_crs_groups'] = @($others + $newGroup)
    }
    $patchBody = @{ replace = $replace }

    # Dry run: show the plan and stop
    if ($DryRun) {
        if ($Interactive) { Write-Blank; Write-Host $Rule; Write-Say 'Dry run: nothing was written to the controller. Planned change:'; Write-Host $Rule; Write-Blank }
        $patchBody | ConvertTo-Json -Depth 30
        return
    }

    # Nothing to do if the policy already matches
    $desired = [pscustomobject]@{ crs_overrides = $replace['crs_overrides'] }
    if ($replace.Contains('pre_crs_groups')) { $desired | Add-Member -NotePropertyName pre_crs_groups -NotePropertyValue $replace['pre_crs_groups'] }
    if ((Get-PolicyState $desired) -eq (Get-PolicyState $cur)) {
        Write-Say 'The policy already has the Step 1 and Step 2 settings. No change made.'
        return
    }

    # Refuse to overwrite if somebody else changed the policy since it was read
    $fresh = Invoke-Avi -Uri "$Base/api/wafpolicy/$Uuid"
    if ((Get-PolicyState $fresh) -ne (Get-PolicyState $cur)) {
        throw 'The policy was changed by someone else while this script was running. Nothing was written; run it again.'
    }

    # 5. Patch the policy
    if ($Interactive) { Write-Say "Applying Step 1 and Step 2 to '$WafPolicyName'"; Write-Blank }
    $result = Invoke-Avi -Method Patch -Uri "$Base/api/wafpolicy/$Uuid" -Body $patchBody

    # 6. Verify that the controller now reports what was requested
    $need = @($replace['crs_overrides'] | ForEach-Object { $n = $_.name; @($_.rule_overrides) | Where-Object { $_ -and $_.mode -eq $CrsMode } | ForEach-Object { "$n|$($_.rule_id)" } })
    $got  = @(Get-Prop $result 'crs_overrides' | Where-Object { $_ } | ForEach-Object { $n = $_.name; @($_.rule_overrides) | Where-Object { $_ -and $_.enable -eq $true -and $_.mode -eq $CrsMode } | ForEach-Object { "$n|$($_.rule_id)" } })
    $ok = (@($need | Where-Object { $got -notcontains $_ }).Count -eq 0)
    if ($ok -and -not $CrsOnly) {
        $pg = @(Get-Prop $result 'pre_crs_groups' | Where-Object { $_ -and $_.name -eq $GroupName }) | Select-Object -First 1
        $ok = ($null -ne $pg) -and (@($pg.rules).Count -eq 4)
    }
    if (-not $ok) {
        $hint = ''
        if ($BackupFile) { $hint = " Restore with: ./php2shell.ps1 -Restore '$BackupFile'" }
        throw "Verification failed: the controller does not report every requested Step 1 / Step 2 setting.$hint"
    }

    [ordered]@{
        name           = $result.name
        uuid           = $result.uuid
        pre_crs_groups = @(Get-Prop $result 'pre_crs_groups' | Where-Object { $_ } | ForEach-Object {
                            [ordered]@{ name = $_.name; rules = @($_.rules | ForEach-Object { $_.name }) } })
        crs_overrides  = @(Get-Prop $result 'crs_overrides' | Where-Object { $_ } | ForEach-Object {
                            [ordered]@{ group = $_.name; enable = $_.enable
                                        rules = @($_.rule_overrides | Where-Object { $_ } | ForEach-Object {
                                                    [ordered]@{ rule_id = $_.rule_id; enable = $_.enable; mode = $_.mode } }) } })
    } | ConvertTo-Json -Depth 10

    if ($Interactive) {
        Write-Blank; Write-Host $Rule
        Write-Say "Done and verified. Open WAF policy `"$WafPolicyName`" in the Avi UI to check the result."
        if ($BackupFile) { Write-Say "Backup of the previous settings: $BackupFile (undo with -Restore)" }
        Write-Host $Rule; Write-Blank
    }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $script:Failed = $true
    # A policy created by this run is deleted again if a later step fails, so no half-configured policy is left behind.
    if ($CreatedUuid) {
        Write-Host "Failed after creating the policy; deleting it again ($CreatedUuid)" -ForegroundColor Yellow
        try { $null = Invoke-Avi -Method Delete -Uri "$Base/api/wafpolicy/$CreatedUuid" }
        catch { Write-Host "Could not delete it; remove '$WafPolicyName' manually" -ForegroundColor Red }
    }
}
finally {
    # End the Avi session so the cookie is useless after this script exits
    if ($LoggedIn) {
        try { $null = Invoke-RestMethod -Method Post -Uri "$Base/logout" -WebSession $script:Session -Headers $script:Headers @Common } catch {}
    }
    # Undo the process-wide certificate override used on Windows PowerShell 5.1
    if ($CertPolicyChanged) { [Net.ServicePointManager]::CertificatePolicy = $PrevCertPolicy }
    $script:Session = $null
    $script:Headers = @{}
}

if ($script:Failed) {
    # In a console or ISE do not close the host; in automation return a failing exit code
    if ($Interactive) { $global:LASTEXITCODE = 1; return } else { exit 1 }
}
