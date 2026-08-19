<#
.SYNOPSIS
    Validates that an Avi Load Balancer account is usable by ServiceNow Discovery
    before you save it in the ServiceNow credential store.

.DESCRIPTION
    Runs the same sequence a REST-based Discovery pattern performs:
      1. Reachability + TLS handshake to the controller
      2. Controller API version detection (/api/initial-data)
      3. Session login (POST /login) and CSRF/session cookie capture
      4. Tenant scope check (GET /api/tenant)
      5. Read privilege check against each inventory endpoint Discovery walks
      6. Clean logout (POST /logout) so you do not leak sessions

.EXAMPLE
    .\Test-AviDiscoveryCredential.ps1 -Controller avi-ctrl.corp.local -SkipCertificateCheck

.EXAMPLE
    $cred = Get-Credential snow-discovery
    .\Test-AviDiscoveryCredential.ps1 -Controller 10.10.10.20 -Credential $cred -Tenant '*'
#>

[CmdletBinding()]
param(
    # Controller FQDN or VIP. Use the exact same value configured on the ServiceNow
    # Discovery schedule / MID Server, not an IP if ServiceNow is using a name.
    [Parameter(Mandatory = $true)]
    [string]$Controller,

    # Omit to be prompted. Never hardcode the password in this file.
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    # 'admin' is the default tenant. Use '*' to test read across all tenants,
    # which is what a multi-tenant Discovery configuration needs.
    [string]$Tenant = 'admin',

    # Leave empty to auto-detect. Supply explicitly (e.g. '22.1.3') to skip
    # detection entirely and force a specific API contract.
    [string]$ApiVersion,

    # Last-resort value if every detection tier fails. Deliberately conservative:
    # an older version is accepted by newer controllers, while a newer version
    # sent to an older controller is rejected with 403.
    [string]$VersionFloor = '18.2.6',

    # Object types the Discovery pattern reads. Trim or extend to match the
    # pattern version in your instance.
    [string[]]$Endpoints = @(
        'cluster/runtime',
        'cloud',
        'virtualservice',
        'vsvip',
        'pool',
        'poolgroup',
        'serviceengine',
        'serviceenginegroup',
        'healthmonitor',
        'vrfcontext',
        'network'
    ),

    # Self-signed controller certificate. See note at the bottom about the
    # MID Server Java trust store, which this switch does NOT affect.
    [switch]$SkipCertificateCheck,

    # Objects to pull per endpoint. 1 is enough to prove read access. Raise it
    # when you want to show the customer what Discovery will actually ingest.
    [int]$PageSize = 25,

    # Console detail level.
    #   Config  = API call plus the configuration of every object (default)
    #   Summary = the PASS/FAIL check lines only
    #   Full    = API call plus raw unmodified JSON of every object
    [ValidateSet('Config', 'Summary', 'Full')]
    [string]$Show = 'Config',

    # Objects printed per endpoint in the Config view before truncating.
    [int]$MaxDetail = 10,

    # Write a report to disk. Extension picks the format: .json, .csv, or .html
    [string]$OutFile,

    # Write the discovered Avi objects (not the check results) to a normalized
    # JSON inventory. This is the file to diff against ServiceNow CI records.
    [string]$InventoryFile,

    # Include the complete unmodified API object alongside the normalized view.
    # Makes the file much larger, but nothing is lost.
    [switch]$IncludeRaw,

    # Page through every object rather than stopping at -PageSize. Forced on
    # automatically whenever -InventoryFile is used.
    [switch]$All,

    # Emit the result objects to the pipeline so you can filter them yourself.
    [switch]$PassThru,

    [int]$TimeoutSec = 30
)

$ErrorActionPreference = 'Stop'
$ScriptVersion  = '1.8.1'
$script:Results = New-Object System.Collections.Generic.List[object]
$IsCore = $PSVersionTable.PSVersion.Major -ge 6

#region helpers ---------------------------------------------------------------

function Add-Result {
    param(
        [string]$Step,
        [string]$Status,
        [string]$Detail,
        [int]$Count = -1,
        $Data = $null,
        $Requests = $null
    )
    $script:Results.Add([pscustomobject]@{
        Step     = $Step
        Status   = $Status
        Count    = $(if ($Count -ge 0) { $Count } else { $null })
        Detail   = $Detail
        Requests = $Requests
        Data     = $Data
    })
    $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ('{0,-6} {1,-26} {2}' -f $Status, $Step, $Detail) -ForegroundColor $color
}

function Get-ErrorDetail {
    param($ErrorRecord)
    $code = $null
    $text = $ErrorRecord.Exception.Message

    $resp = $ErrorRecord.Exception.Response
    if ($resp) {
        if ($IsCore) { $code = [int]$resp.StatusCode }
        else { $code = [int]$resp.StatusCode.value__ }
    }

    # No HTTP response at all means transport failure (DNS, routing, TLS trust).
    # The useful text lives in the inner exception, not the outer one.
    if (-not $resp) {
        $inner = $ErrorRecord.Exception.InnerException
        while ($inner) {
            $text = $inner.Message
            $inner = $inner.InnerException
        }
    }

    $body = $ErrorRecord.ErrorDetails.Message
    if (-not $body -and $resp -and -not $IsCore) {
        try {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd()
            $reader.Close()
        } catch { }
    }

    if ($body) {
        try {
            $parsed = $body | ConvertFrom-Json
            if ($parsed.error) { $text = $parsed.error }
            elseif ($parsed.detail) { $text = $parsed.detail }
            else { $text = $body }
        } catch { $text = $body }
    }

    [pscustomobject]@{
        Code    = $code
        Message = ($text -replace '\s+', ' ').Trim()
        Type    = $ErrorRecord.Exception.GetType().FullName
        Line    = $ErrorRecord.InvocationInfo.ScriptLineNumber
        Command = $ErrorRecord.InvocationInfo.Line.Trim()
    }
}

# Formats an error for display. HTTP failures and script bugs look completely
# different and must not be reported with the same wording.
function Format-Failure {
    param($Err)
    if ($Err.Code) {
        return "HTTP $($Err.Code): $($Err.Message)"
    }
    return "SCRIPT ERROR [$($Err.Type)] at line $($Err.Line): $($Err.Message)"
}

function Initialize-TlsHandling {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

    if ($SkipCertificateCheck -and -not $IsCore) {
        if (-not ('AviTrustAllPolicy' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class AviTrustAllPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
'@
        }
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object AviTrustAllPolicy
    }
}

# Common splat so PS 5.1 and PS 7 behave the same.
function Get-BaseArgs {
    $base = @{ TimeoutSec = $TimeoutSec }
    if ($SkipCertificateCheck -and $IsCore) { $base['SkipCertificateCheck'] = $true }
    return $base
}

# Avi object references look like:
#   https://controller/api/pool/pool-9f3c-...#my-pool-name
# The readable name after '#' is only present when the request carries
# include_name=true. Falls back to the UUID segment when it is absent.
function Get-RefName {
    param([string]$Ref)
    if (-not $Ref) { return $null }
    if ($Ref -match '#(.+)$') { return $matches[1] }
    return ($Ref -split '/')[-1]
}

function Get-RefNames {
    param($Refs)
    # Comma operator keeps an empty result as an empty array. Without it an
    # empty list collapses to $null and serializes as null instead of [].
    if (-not $Refs) { return ,@() }
    return ,@($Refs | ForEach-Object { Get-RefName $_ })
}

function ConvertTo-Normalized {
    param([string]$Type, $Obj)

    $n = [ordered]@{
        objectType = $Type
        name       = $Obj.name
        uuid       = $Obj.uuid
        tenant     = Get-RefName $Obj.tenant_ref
        cloud      = Get-RefName $Obj.cloud_ref
    }

    switch ($Type) {
        'virtualservice' {
            $n.enabled  = $Obj.enabled
            $n.vsvip    = Get-RefName $Obj.vsvip_ref
            $n.seGroup  = Get-RefName $Obj.se_group_ref
            $n.vrf      = Get-RefName $Obj.vrf_context_ref
            $n.appProfile = Get-RefName $Obj.application_profile_ref
            $n.pool      = Get-RefName $Obj.pool_ref
            $n.poolGroup = Get-RefName $Obj.pool_group_ref
            $n.ipAddresses = @($Obj.vip | ForEach-Object { $_.ip_address.addr } | Where-Object { $_ })
            $n.services = @($Obj.services | ForEach-Object {
                [ordered]@{
                    port      = $_.port
                    portRange = $_.port_range_end
                    ssl       = [bool]$_.enable_ssl
                }
            })
            $n.sslProfile      = Get-RefName $Obj.ssl_profile_ref
            $n.sslCertificates = Get-RefNames $Obj.ssl_key_and_certificate_refs
        }
        'vsvip' {
            $n.ipAddresses = @($Obj.vip | ForEach-Object { $_.ip_address.addr } | Where-Object { $_ })
            $n.fqdn        = @($Obj.dns_info | ForEach-Object { $_.fqdn } | Where-Object { $_ })
            $n.vrf         = Get-RefName $Obj.vrf_context_ref
        }
        'pool' {
            $n.enabled       = $Obj.enabled
            $n.lbAlgorithm   = $Obj.lb_algorithm
            $n.defaultPort   = $Obj.default_server_port
            $n.healthMonitors = Get-RefNames $Obj.health_monitor_refs
            $n.serverCount   = @($Obj.servers).Count
            $n.servers = @($Obj.servers | ForEach-Object {
                [ordered]@{
                    ip       = $_.ip.addr
                    port     = $_.port
                    hostname = $_.hostname
                    enabled  = $_.enabled
                    ratio    = $_.ratio
                }
            })
        }
        'poolgroup' {
            $n.members = @($Obj.members | ForEach-Object {
                [ordered]@{ pool = Get-RefName $_.pool_ref; ratio = $_.ratio; priority = $_.priority_label }
            })
        }
        'serviceengine' {
            $n.seGroup  = Get-RefName $Obj.se_group_ref
            $n.mgmtIp   = @($Obj.mgmt_vnic.vnic_networks | ForEach-Object { $_.ip.ip_addr.addr } | Where-Object { $_ }) | Select-Object -First 1
            $n.enabled  = $Obj.enable_state
            $n.hostname = $Obj.hostname
        }
        'serviceenginegroup' {
            $n.haMode      = $Obj.ha_mode
            $n.minSes      = $Obj.min_scaleout_per_vs
            $n.maxSes      = $Obj.max_se
            $n.vcpusPerSe  = $Obj.vcpus_per_se
            $n.memoryPerSe = $Obj.memory_per_se
        }
        'cloud' {
            $n.vtype     = $Obj.vtype
            $n.dhcp      = $Obj.dhcp_enabled
            $n.ipamProfile = Get-RefName $Obj.ipam_provider_ref
            $n.dnsProfile  = Get-RefName $Obj.dns_provider_ref
        }
        'healthmonitor' {
            $n.type            = $Obj.type
            $n.receiveTimeout  = $Obj.receive_timeout
            $n.sendInterval    = $Obj.send_interval
        }
        'network' {
            $n.vrf     = Get-RefName $Obj.vrf_context_ref
            $n.dhcp    = $Obj.dhcp_enabled
            $n.subnets = @($Obj.configured_subnets | ForEach-Object {
                "$($_.prefix.ip_addr.addr)/$($_.prefix.mask)"
            })
        }
        'vrfcontext' {
            $n.staticRoutes = @($Obj.static_routes).Count
        }
    }

    if ($IncludeRaw) { $n.raw = $Obj }
    return [pscustomobject]$n
}

# Renders one normalized field value for console display. Returns $null for
# anything empty so blank fields can be skipped entirely.
function Format-ConfigValue {
    param($Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
        return $Value
    }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return [string]$Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = @()
        foreach ($k in $Value.Keys) {
            $v = $Value[$k]
            if ($null -ne $v -and "$v" -ne '') { $pairs += "$k=$v" }
        }
        if ($pairs.Count -eq 0) { return $null }
        return ($pairs -join ' ')
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($e in $Value) {
            $f = Format-ConfigValue $e
            if ($f) { $parts += $f }
        }
        if ($parts.Count -eq 0) { return $null }
        return ($parts -join '; ')
    }

    # PSCustomObject
    $pairs = @()
    foreach ($pr in $Value.PSObject.Properties) {
        if ($null -ne $pr.Value -and "$($pr.Value)" -ne '') { $pairs += "$($pr.Name)=$($pr.Value)" }
    }
    if ($pairs.Count -eq 0) { return $null }
    return ($pairs -join ' ')
}

# Prints the API call that produced a result, then the configuration of each
# object it returned.
function Write-ConfigDetail {
    param($Row, [int]$Max)

    Write-Host ""
    Write-Host "  $($Row.Step)" -ForegroundColor Cyan

    foreach ($u in @($Row.Requests)) {
        Write-Host "    API  GET $u" -ForegroundColor DarkGray
    }

    $data = @($Row.Data)
    if ($data.Count -eq 0) {
        Write-Host "    (no objects returned)" -ForegroundColor DarkGray
        return
    }

    $type  = ($Row.Step -replace '^GET /api/', '') -replace '/.*$', ''
    $shown = 0

    foreach ($obj in $data) {
        if ($shown -ge $Max) {
            Write-Host "    ... $($data.Count - $Max) more not shown (raise -MaxDetail)" -ForegroundColor DarkGray
            break
        }
        $shown++

        $n     = ConvertTo-Normalized -Type $type -Obj $obj
        $label = if ($n.name) { $n.name } elseif ($n.uuid) { $n.uuid } else { "object $shown" }

        Write-Host "    $label" -ForegroundColor White

        $printed = 0
        foreach ($pr in $n.PSObject.Properties) {
            if ($pr.Name -in 'name', 'objectType', 'raw') { continue }
            $f = Format-ConfigValue $pr.Value
            if ($f) { Write-Host ("      {0,-16} {1}" -f $pr.Name, $f); $printed++ }
        }

        # Status blobs and object types with no normalizer mapping produce
        # nothing above. Show the raw top-level fields rather than a bare label.
        if ($printed -eq 0) {
            foreach ($pr in $obj.PSObject.Properties) {
                if ($pr.Name -eq 'url') { continue }
                $f = Format-ConfigValue $pr.Value
                if ($f) {
                    if ($f.Length -gt 120) { $f = $f.Substring(0, 117) + '...' }
                    Write-Host ("      {0,-16} {1}" -f $pr.Name, $f)
                }
            }
        }
    }
}

# Fetches a collection endpoint, following Avi's 'next' links so the inventory
# is complete rather than just the first page.
function Get-AviCollection {
    param(
        [string]$Endpoint,
        [hashtable]$Headers,
        $WebSession,
        [int]$Size,
        [switch]$FollowPaging
    )

    $sep = if ($Endpoint -match '\?') { '&' } else { '?' }
    $uri = "$BaseUri/api/$Endpoint"

    # include_name makes every *_ref carry a human-readable '#name' suffix.
    if ($Endpoint -notmatch 'runtime|version') {
        $uri += "${sep}include_name=true&page_size=$Size"
    }

    $items = New-Object System.Collections.Generic.List[object]
    $requests = New-Object System.Collections.Generic.List[object]
    $total = $null
    $pages = 0
    $isCollection = $true

    do {
        $requests.Add($uri)
        $r = Invoke-RestMethod @BaseArgs -Uri $uri -Method Get -Headers $Headers -WebSession $WebSession
        $pages++

        # Explicit loop rather than $r.PSObject.Properties.Name -contains 'results'.
        # Member enumeration over a PSMemberInfoCollection is not reliable across
        # PowerShell versions and object shapes.
        $hasResults = $false
        if ($null -ne $r) {
            foreach ($p in $r.PSObject.Properties) {
                if ($p.Name -eq 'results') { $hasResults = $true; break }
            }
        }

        # Collection endpoints return a results array. Singletons such as
        # cluster/runtime return the object itself and have no count field.
        if ($hasResults) {
            foreach ($i in @($r.results)) { $items.Add($i) }
            if ($null -eq $total) {
                $reported = $null
                foreach ($p in $r.PSObject.Properties) {
                    if ($p.Name -eq 'count') { $reported = $p.Value; break }
                }
                $total = if ($null -ne $reported) { [int]$reported } else { @($r.results).Count }
            }
        }
        else {
            $isCollection = $false
            $items.Add($r)
            $total = 1
        }

        $nextUri = $null
        if ($FollowPaging) {
            foreach ($p in $r.PSObject.Properties) {
                if ($p.Name -eq 'next' -and $p.Value) {
                    # 'next' can carry an internal cluster hostname. Re-anchor it
                    # on the address we were given or the follow-up call fails.
                    $nextUri = [string]$p.Value
                    if ($nextUri -match '/api/(.+)$') { $nextUri = "$BaseUri/api/$($matches[1])" }
                    break
                }
            }
        }
        $uri = $nextUri
    } while ($uri -and $pages -lt 200)

    if ($null -eq $total) { $total = $items.Count }

    # NOTE: do NOT use @($items) here. A List[T] created by New-Object comes back
    # wrapped in a PSObject, and the @() array subexpression operator throws
    # "Argument types do not match" on that combination. ToArray() is safe.
    [pscustomobject]@{
        Items        = $items.ToArray()
        Requests     = $requests.ToArray()
        Total        = [int]$total
        Pages        = [int]$pages
        IsCollection = [bool]$isCollection
    }
}

#endregion --------------------------------------------------------------------

if ($Credential -eq [System.Management.Automation.PSCredential]::Empty) {
    $Credential = Get-Credential -Message "Avi account that ServiceNow Discovery will use"
}

$BaseUri = if ($Controller -match '^https?://') { $Controller.TrimEnd('/') } else { "https://$Controller" }
$user    = $Credential.UserName
$plain   = $Credential.GetNetworkCredential().Password

Initialize-TlsHandling

# PowerShell splats from a VARIABLE only (@BaseArgs). Build it once here.
$BaseArgs = Get-BaseArgs

Write-Host ""
Write-Host "Avi Discovery credential test  (script v$ScriptVersion)" -ForegroundColor Cyan
Write-Host "Controller : $BaseUri"
Write-Host "Account    : $user"
Write-Host "Tenant     : $Tenant"
Write-Host "Host       : $env:COMPUTERNAME  (running as $env:USERDOMAIN\$env:USERNAME)"
Write-Host "PowerShell : $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
Write-Host "Script     : $PSCommandPath"
Write-Host ("-" * 78)

# --- Step 1: reachability, and opportunistic unauthenticated version read ----
#
# Version detection runs in tiers because no single source is reliable across
# builds. Tier order, best to worst:
#   1. -ApiVersion supplied by the operator (trusted, skips detection)
#   2. /api/initial-data, unauthenticated, but the field is empty on some builds
#   3. /api/cluster/version after login, authoritative but requires a session
#   4. version string parsed out of a 403 version-mismatch error
#   5. conservative floor, only so the run can continue
#
# The chicken-and-egg problem: login itself carries X-Avi-Version. Sending a
# version NEWER than the controller returns 403. Omitting the header entirely
# is accepted, so when detection has not produced a value yet we simply leave
# it off rather than guessing high.

$VersionSource = $null

if ($ApiVersion) {
    $VersionSource = 'operator supplied (-ApiVersion)'
}

try {
    $init = Invoke-RestMethod @BaseArgs -Uri "$BaseUri/api/initial-data" -Method Get

    if (-not $ApiVersion -and $init.version.Version) {
        $ApiVersion    = $init.version.Version
        $VersionSource = '/api/initial-data'
    }

    $build  = $init.version.build
    $detail = 'Controller responded'
    if ($ApiVersion) { $detail += ", version $ApiVersion" }
    elseif ($build)  { $detail += ", build $build, version field empty" }
    else             { $detail += ', version field empty' }

    Add-Result 'Reachability' 'PASS' $detail -Data $init.version
}
catch {
    $e = Get-ErrorDetail $_
    if ($e.Code) {
        Add-Result 'Reachability' 'PASS' "Controller responded, HTTP $($e.Code) on /api/initial-data"
    }
    else {
        Add-Result 'Reachability' 'FAIL' $e.Message
        Write-Host ""
        Write-Host "Stopped: could not reach the controller. Check DNS, routing, port 443, proxy, or TLS trust." -ForegroundColor Red
        exit 2
    }
}

# Header set. X-Avi-Version is added only once a value is known.
$commonHeaders = @{
    'X-Avi-Tenant' = $Tenant
    'Referer'      = $BaseUri
}
if ($ApiVersion) { $commonHeaders['X-Avi-Version'] = $ApiVersion }

# --- Step 2: login -----------------------------------------------------------

$session   = $null
$loginBody = @{ username = $user; password = $plain } | ConvertTo-Json -Compress

function Invoke-AviLogin {
    param([string]$Version)
    $h = @{ 'Referer' = $BaseUri }
    if ($Version) { $h['X-Avi-Version'] = $Version }

    Invoke-RestMethod @BaseArgs `
        -Uri "$BaseUri/login" `
        -Method Post `
        -Body $loginBody `
        -ContentType 'application/json' `
        -Headers $h `
        -SessionVariable session

    # SessionVariable creates the variable in this function's scope. Lift it out.
    $script:LoginSession = $session
}

try {
    $login   = Invoke-AviLogin -Version $ApiVersion
    $session = $script:LoginSession
}
catch {
    $e = Get-ErrorDetail $_

    # A 403 here is usually a version mismatch, not a credential problem. Avi
    # names the versions it accepts in the error body, so pull one out and retry.
    $harvested = $null
    if ($e.Code -eq 403 -and $e.Message -match '(\d+\.\d+\.\d+)') {
        $harvested = $matches[1]
    }

    if ($harvested -and $harvested -ne $ApiVersion) {
        Add-Result 'API version (from error)' 'WARN' `
            "Login rejected version '$ApiVersion'. Controller named $harvested. Retrying."
        try {
            $ApiVersion    = $harvested
            $VersionSource = 'parsed from 403 version-mismatch error'
            $login   = Invoke-AviLogin -Version $ApiVersion
            $session = $script:LoginSession
        }
        catch {
            $e2 = Get-ErrorDetail $_
            Add-Result 'Login' 'FAIL' (Format-Failure $e2)
            $session = $null
        }
    }
    else {
        Add-Result 'Login' 'FAIL' (Format-Failure $e)
        $session = $null
    }

    if (-not $session) {
        Write-Host ""
        if ($e.Code -eq 401) {
            Write-Host "Login rejected (401). Avi returns the same message for several causes:" -ForegroundColor Red
            Write-Host "  - Wrong password (check for a typo at the prompt, or a trailing space)"
            Write-Host "  - ACCOUNT LOCKED. Avi's User Account Profile locks a local account after a"
            Write-Host "    set number of failed logins (often 3) for a set window (often 30 min)."
            Write-Host "    Once locked, the CORRECT password still returns 401 until it expires."
            Write-Host "  - Password expired, or change-on-first-login still set on the account"
            Write-Host "  - Remote auth (LDAP/SAML) user with no local Avi authorization mapping"
            Write-Host ""
            Write-Host "  Check in the UI: Administration > Accounts > Users, and the User Account" -ForegroundColor Yellow
            Write-Host "  Profile bound to that user for the lockout threshold and timeout." -ForegroundColor Yellow
            Write-Host "  Each further run burns another attempt and can restart the lockout timer," -ForegroundColor Yellow
            Write-Host "  so confirm the account state before retrying." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Controller said: $($e.Message)" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Stopped at login." -ForegroundColor Red
            Write-Host "  403  X-Avi-Version unsupported. Re-run with -ApiVersion set explicitly."
            Write-Host "  Controller said: $(Format-Failure $e)" -ForegroundColor DarkGray
        }
        exit 3
    }
}

$cookies = $session.Cookies.GetCookies($BaseUri)
$csrf    = ($cookies | Where-Object { $_.Name -eq 'csrftoken' }).Value
if ($csrf) { $commonHeaders['X-CSRFToken'] = $csrf }

$detail = "Authenticated as $user"
if ($login.user_profile_ref) { $detail += '. Profile ref present.' }
Add-Result 'Login' 'PASS' $detail

# Authoritative version. This is the tier that actually resolves the empty
# /api/initial-data case, and it settles the header for every call after it.
try {
    $cv = Invoke-RestMethod @BaseArgs `
        -Uri "$BaseUri/api/cluster/version" -Method Get -Headers $commonHeaders -WebSession $session

    if ($cv.Version) {
        if ($ApiVersion -and $cv.Version -ne $ApiVersion) {
            Add-Result 'API version' 'WARN' `
                "Controller reports $($cv.Version), was using $ApiVersion. Header corrected." -Data $cv
        }
        else {
            Add-Result 'API version' 'PASS' "$($cv.Version) (detected)" -Data $cv
        }
        $ApiVersion    = $cv.Version
        $VersionSource = '/api/cluster/version'
        $commonHeaders['X-Avi-Version'] = $ApiVersion
    }
}
catch {
    $e = Get-ErrorDetail $_
    if ($ApiVersion) {
        Add-Result 'API version' 'WARN' "Could not confirm via /api/cluster/version. Using $ApiVersion from $VersionSource."
    }
    else {
        $ApiVersion    = $VersionFloor
        $VersionSource = "fallback floor"
        $commonHeaders['X-Avi-Version'] = $ApiVersion
        Add-Result 'API version' 'WARN' "Detection failed. Falling back to $ApiVersion. Set -ApiVersion explicitly."
    }
}

# --- Step 4: tenant scope ----------------------------------------------------

try {
    $tenants = Invoke-RestMethod @BaseArgs `
        -Uri "$BaseUri/api/tenant?page_size=200" -Method Get -Headers $commonHeaders -WebSession $session

    $names = @($tenants.results | ForEach-Object { $_.name })
    Add-Result 'Tenant access' 'PASS' ("{0} tenant(s) visible: {1}" -f $names.Count, ($names -join ', '))
}
catch {
    $e = Get-ErrorDetail $_
    Add-Result 'Tenant access' 'FAIL' (Format-Failure $e)
}

# --- Step 5: read privilege on each Discovery endpoint -----------------------

Write-Host ""
Write-Host "Inventory read checks (tenant scope: $Tenant)" -ForegroundColor Cyan

$FollowPaging = ($All -or $InventoryFile)
if ($FollowPaging) { $PageSize = [Math]::Max($PageSize, 200) }

foreach ($ep in $Endpoints) {
    try {
        $c = Get-AviCollection -Endpoint $ep -Headers $commonHeaders -WebSession $session `
                               -Size $PageSize -FollowPaging:$FollowPaging

        $items = $c.Items
        $count = $c.Total

        if (-not $c.IsCollection) {
            Add-Result "GET /api/$ep" 'PASS' 'readable (single object, not a collection)' -Count 1 -Data $items -Requests $c.Requests
        }
        else {
            $names = @()
            foreach ($it in $items) {
                if ($it.name)     { $names += [string]$it.name }
                elseif ($it.uuid) { $names += [string]$it.uuid }
            }

            $preview = 'no named objects'
            if ($names.Count -gt 0) {
                $shown   = @($names | Select-Object -First 5)
                $preview = $shown -join ', '
                if ($count -gt $shown.Count) { $preview += ", ... (+$($count - $shown.Count) more)" }
            }

            # Avi object names are unique per cloud and per tenant, not globally.
            # ServiceNow keyed on name alone will collide on these.
            $dupes = @($names | Group-Object | Where-Object { $_.Count -gt 1 })

            if ($count -eq 0) {
                Add-Result "GET /api/$ep" 'WARN' 'count = 0 (readable, but nothing to discover)' -Count 0 -Data $items -Requests $c.Requests
            }
            else {
                $d = "count = $count | $preview"
                if ($c.Pages -gt 1) { $d += " [$($c.Pages) pages]" }

                if ($dupes.Count -gt 0) {
                    $dupText = (@($dupes | ForEach-Object { "$($_.Name) x$($_.Count)" })) -join ', '
                    Add-Result "GET /api/$ep" 'WARN' `
                        "$d | duplicate names: $dupText (reconcile on uuid, not name)" -Count $count -Data $items -Requests $c.Requests
                }
                else {
                    Add-Result "GET /api/$ep" 'PASS' $d -Count $count -Data $items -Requests $c.Requests
                }
            }
        }
    }
    catch {
        $e = Get-ErrorDetail $_
        Add-Result "GET /api/$ep" 'FAIL' (Format-Failure $e)
    }
}

# --- Step 6: logout ----------------------------------------------------------

try {
    Invoke-RestMethod @BaseArgs `
        -Uri "$BaseUri/logout" -Method Post -Headers $commonHeaders -WebSession $session | Out-Null
    Add-Result 'Logout' 'PASS' 'Session closed'
}
catch {
    Add-Result 'Logout' 'WARN' 'Logout call failed, session will expire on its own'
}

# --- Summary -----------------------------------------------------------------

$fail = @($script:Results | Where-Object Status -eq 'FAIL')
$warn = @($script:Results | Where-Object Status -eq 'WARN')

$pass = @($script:Results | Where-Object Status -eq 'PASS')

Write-Host ""
Write-Host ("=" * 78)
Write-Host "API version detected: $ApiVersion   (source: $VersionSource)" -ForegroundColor Cyan
Write-Host "Pin this value in the ServiceNow pattern's X-Avi-Version header." -ForegroundColor Cyan
Write-Host ("-" * 78)

Write-Host ("Checks: {0} passed, {1} warning, {2} failed" -f $pass.Count, $warn.Count, $fail.Count)

# Only the exceptions are reprinted. The per-check lines above are the full log,
# so repeating every PASS row here just pushes the important lines off screen.
foreach ($row in $warn) { Write-Host "  WARN  $($row.Step): $($row.Detail)" -ForegroundColor Yellow }
foreach ($row in $fail) { Write-Host "  FAIL  $($row.Step): $($row.Detail)" -ForegroundColor Red }

Write-Host ("-" * 78)
if ($fail.Count -eq 0) {
    Write-Host "RESULT: PASS. This account is usable for ServiceNow Discovery." -ForegroundColor Green
    $exit = 0
}
else {
    Write-Host "RESULT: FAIL on $($fail.Count) check(s)." -ForegroundColor Red
    $exit = 1
}
Write-Host ("=" * 78)

# --- Configuration detail ----------------------------------------------------

if ($Show -ne 'Summary') {
    Write-Host ""
    Write-Host ("=" * 78)
    Write-Host "CONFIGURATION DETAIL" -ForegroundColor Cyan
    Write-Host "Each block shows the exact API call and the objects it returned."
    Write-Host ("=" * 78)

    foreach ($row in $script:Results | Where-Object { $_.Requests }) {
        if ($Show -eq 'Full') {
            Write-Host ""
            Write-Host "  $($row.Step)" -ForegroundColor Cyan
            foreach ($u in @($row.Requests)) {
                Write-Host "    API  GET $u" -ForegroundColor DarkGray
            }
            if (@($row.Data).Count -eq 0) {
                Write-Host "    (no objects returned)" -ForegroundColor DarkGray
            }
            else {
                $row.Data | ConvertTo-Json -Depth 8 | Write-Host
            }
        }
        else {
            Write-ConfigDetail -Row $row -Max $MaxDetail
        }
    }
    Write-Host ""
}

# --- File export -------------------------------------------------------------

if ($OutFile) {
    $ext = [System.IO.Path]::GetExtension($OutFile).ToLower()
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    switch ($ext) {
        '.json' {
            [pscustomobject]@{
                timestamp  = $stamp
                controller = $BaseUri
                account    = $user
                tenant     = $Tenant
                apiVersion = $ApiVersion
                runFrom    = "$env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME"
                overall    = $(if ($fail.Count -eq 0) { 'PASS' } else { 'FAIL' })
                checks     = $script:Results
            } | ConvertTo-Json -Depth 10 | Set-Content -Path $OutFile -Encoding UTF8
        }
        '.csv' {
            # Data is dropped here on purpose. CSV cannot represent nested objects.
            $script:Results |
                Select-Object @{n = 'Timestamp'; e = { $stamp } },
                              @{n = 'Controller'; e = { $BaseUri } },
                              @{n = 'Account'; e = { $user } },
                              Step, Status, Count, Detail,
                              @{n = 'ApiCalls'; e = { (@($_.Requests)) -join ' ; ' } } |
                Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
        }
        '.html' {
            $overall = if ($fail.Count -eq 0) { 'PASS' } else { 'FAIL' }
            $css = @'
<style>
 body { font-family: Segoe UI, sans-serif; margin: 24px; color: #222; }
 h1 { font-size: 18px; } h2 { font-size: 14px; color: #555; font-weight: normal; }
 table { border-collapse: collapse; width: 100%; margin-top: 12px; }
 th, td { border: 1px solid #ddd; padding: 6px 10px; font-size: 13px; text-align: left; }
 th { background: #f4f4f4; }
 .PASS { color: #157347; font-weight: bold; }
 .WARN { color: #997404; font-weight: bold; }
 .FAIL { color: #b02a37; font-weight: bold; }
</style>
'@
            $rows = $script:Results | ForEach-Object {
                "<tr><td>$([System.Web.HttpUtility]::HtmlEncode($_.Step))</td>" +
                "<td class='$($_.Status)'>$($_.Status)</td>" +
                "<td>$($_.Count)</td>" +
                "<td>$([System.Web.HttpUtility]::HtmlEncode($_.Detail))</td>" +
                "<td><code>$([System.Web.HttpUtility]::HtmlEncode(((@($_.Requests)) -join ' ')))</code></td></tr>"
            }
            Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
            $html = "<html><head><meta charset='utf-8'>$css</head><body>" +
                    "<h1>Avi Discovery credential test: <span class='$overall'>$overall</span></h1>" +
                    "<h2>$BaseUri &middot; account $user &middot; tenant $Tenant &middot; API $ApiVersion &middot; $stamp</h2>" +
                    "<table><tr><th>Check</th><th>Status</th><th>Count</th><th>Detail</th><th>API call</th></tr>" +
                    ($rows -join "`n") + "</table></body></html>"
            Set-Content -Path $OutFile -Value $html -Encoding UTF8
        }
        default {
            Write-Warning "Unrecognized extension '$ext'. Use .json, .csv, or .html. Nothing written."
        }
    }

    if (Test-Path $OutFile) {
        Write-Host ""
        Write-Host "Report written to $((Resolve-Path $OutFile).Path)" -ForegroundColor Cyan
    }
}

if ($InventoryFile) {

    # Normalizes the fields a CMDB actually reconciles on. Field availability
    # varies by controller version, so every lookup is null-tolerant and the
    # raw object is available via -IncludeRaw when something is missing.

    $inventory = [ordered]@{}
    $apiCalls  = [ordered]@{}
    foreach ($row in $script:Results | Where-Object { $_.Step -like 'GET /api/*' -and $_.Data }) {
        $type = ($row.Step -replace '^GET /api/', '') -replace '/.*$', ''

        # Status endpoints such as cluster/runtime return a state blob, not
        # configured objects. They belong in the check log, not the inventory.
        $configured = @($row.Data | Where-Object { $_.uuid -or $_.name })
        if ($configured.Count -eq 0) { continue }

        $inventory[$type] = @($configured | ForEach-Object { ConvertTo-Normalized -Type $type -Obj $_ })
        $apiCalls[$type]  = @($row.Requests)
    }

    $doc = [ordered]@{
        generated  = (Get-Date -Format 'o')
        controller = $BaseUri
        apiVersion = $ApiVersion
        account    = $user
        tenantScope = $Tenant
        collectedFrom = "$env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME"
        objectCounts = [ordered]@{}
        apiCalls   = $apiCalls
        objects    = $inventory
    }
    foreach ($k in $inventory.Keys) { $doc.objectCounts[$k] = @($inventory[$k]).Count }

    $doc | ConvertTo-Json -Depth 12 | Set-Content -Path $InventoryFile -Encoding UTF8

    Write-Host ""
    Write-Host "Inventory written to $((Resolve-Path $InventoryFile).Path)" -ForegroundColor Cyan
    Write-Host ("  " + (($doc.objectCounts.GetEnumerator() |
        ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  ')) -ForegroundColor Gray
}

if ($PassThru) { $script:Results }

exit $exit
