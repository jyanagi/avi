<#
  provision-vsphere.ps1 - PowerCLI alternative to provision-vsphere.sh.
  Clones the base template into the three demo VMs and applies static network
  config via a cloud-init guestinfo customization. Use this if your team
  standardizes on PowerCLI instead of govc.

  Prerequisites (staged offline):
    - VMware.PowerCLI module installed on the jump host
    - config/config.env values mirrored into the variables below or loaded

  Load config values before running, e.g. in PowerShell:
    Get-Content .\config\config.env | Where-Object {$_ -match '='} |
      ForEach-Object { $k,$v = $_ -split '=',2; Set-Item -Path "Env:$k" -Value ($v.Trim('"')) }
#>

param(
  [string]$ConfigDir = "$PSScriptRoot\..\config"
)

$ErrorActionPreference = "Stop"

# load config.env into environment
Get-Content "$ConfigDir\config.env" | Where-Object { $_ -match '^\s*[A-Z]' -and $_ -match '=' } | ForEach-Object {
  $parts = $_ -split '=',2
  $key = $parts[0].Trim()
  $val = $parts[1].Trim().Trim('"')
  Set-Item -Path "Env:$key" -Value $val
}

$pubKey = Get-Content "$ConfigDir\ssh\waap-demo.pub" -Raw

Write-Host "[vsphere] Connecting to $env:VSPHERE_SERVER"
if ($env:VSPHERE_INSECURE -eq "true") {
  Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
}
Connect-VIServer -Server $env:VSPHERE_SERVER -User $env:VSPHERE_USER -Password $env:VSPHERE_PASSWORD | Out-Null

function New-DemoVM($name, $ip) {
  if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
    Write-Host "[vsphere] VM $name exists, skipping clone"
  } else {
    Write-Host "[vsphere] Cloning $env:VSPHERE_TEMPLATE -> $name"
    $tpl = Get-Template -Name $env:VSPHERE_TEMPLATE
    $ds  = Get-Datastore -Name $env:VSPHERE_DATASTORE
    $cluster = Get-Cluster -Name $env:VSPHERE_CLUSTER
    New-VM -Name $name -Template $tpl -Datastore $ds -ResourcePool $cluster `
      -Location (Get-Folder -Name $env:VSPHERE_FOLDER -ErrorAction SilentlyContinue) | Out-Null
  }

  # metadata + userdata for cloud-init guestinfo
  $userdata = @"
#cloud-config
hostname: $name
fqdn: $name.$env:NET_DOMAIN
users:
  - name: $env:TEMPLATE_SSH_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $pubKey
ssh_pwauth: false
"@
  $metadata = @"
instance-id: $name
local-hostname: $name
network:
  version: 2
  ethernets:
    ens192:
      dhcp4: false
      addresses: [$ip/$env:NET_NETMASK]
      gateway4: $env:NET_GATEWAY
      nameservers:
        addresses: [$env:NET_DNS]
        search: [$env:NET_DOMAIN]
"@

  $b64ud = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userdata))
  $b64md = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($metadata))

  $vm = Get-VM -Name $name
  New-AdvancedSetting -Entity $vm -Name "guestinfo.userdata" -Value $b64ud -Confirm:$false -Force | Out-Null
  New-AdvancedSetting -Entity $vm -Name "guestinfo.userdata.encoding" -Value "base64" -Confirm:$false -Force | Out-Null
  New-AdvancedSetting -Entity $vm -Name "guestinfo.metadata" -Value $b64md -Confirm:$false -Force | Out-Null
  New-AdvancedSetting -Entity $vm -Name "guestinfo.metadata.encoding" -Value "base64" -Confirm:$false -Force | Out-Null

  Start-VM -VM $vm -Confirm:$false | Out-Null
  Write-Host "[vsphere] $name powered on with static IP $ip"
}

New-DemoVM $env:MCP_A_NAME $env:MCP_A_IP
New-DemoVM $env:MCP_B_NAME $env:MCP_B_IP
New-DemoVM $env:AGENT_NAME $env:AGENT_IP

Write-Host "[vsphere] Provisioning complete. Allow a few minutes for cloud-init + SSH."
Disconnect-VIServer -Confirm:$false
