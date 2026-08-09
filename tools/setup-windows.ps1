<#
.SYNOPSIS
  Prepares this Windows machine to run Things.

.DESCRIPTION
  Two jobs, both of which are otherwise silent failures:

  1. Opens the LAN sync port (6768) in Windows Firewall. Without this the iPhone
     discovers the PC over Bonjour, shows it in the peer list, and then times out
     on connect — which reads as "sync is broken" rather than "a firewall dropped
     the SYN". The web port (6767) is deliberately NOT opened: it binds to
     127.0.0.1 only and must never be reachable from the LAN.

  2. Reports the LAN address to type into the iPhone's "Connect manually" field,
     because mDNS across a Wi-Fi/Ethernet boundary is unreliable in exactly the
     setup this project has.

  Run once, from an elevated PowerShell. Re-running is safe.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\setup-windows.ps1
#>

[CmdletBinding()]
param(
    [int] $SyncPort = 6768,
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'
$ruleName = "Things LAN sync ($SyncPort)"

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "This needs an elevated PowerShell (Run as administrator)." -ForegroundColor Yellow
    Write-Host "Nothing was changed."
    exit 1
}

if ($Remove) {
    try {
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
        Write-Host "Removed firewall rule: $ruleName" -ForegroundColor Green
    } catch {
        Write-Host "No such rule. Nothing to remove."
    }
    exit 0
}

# ── Firewall ────────────────────────────────────────────────────────────────
$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Firewall rule already present: $ruleName" -ForegroundColor DarkGray
} else {
    # Private profile only. Things should never be reachable from a public network,
    # and a rule scoped to Any is how a personal vault ends up exposed on hotel Wi-Fi.
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $SyncPort `
        -Profile Private `
        -Description 'Things peer-to-peer sync. Private networks only. Paired devices only.' | Out-Null
    Write-Host "Opened TCP $SyncPort inbound on PRIVATE networks only." -ForegroundColor Green
}

# ── Report the manual-connect address ───────────────────────────────────────
Write-Host ""
Write-Host "Manual connect addresses for the iPhone:" -ForegroundColor Cyan

$addrs = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notlike '127.*' -and
        $_.IPAddress -notlike '169.254.*' -and
        $_.PrefixOrigin -ne 'WellKnown'
    } |
    Sort-Object InterfaceMetric

if (-not $addrs) {
    Write-Host "  (no LAN address found — is the machine connected?)" -ForegroundColor Yellow
} else {
    foreach ($a in $addrs) {
        $alias = (Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue).Name
        Write-Host ("  {0,-16} {1}:{2}" -f $alias, $a.IPAddress, $SyncPort)
    }
    Write-Host ""
    Write-Host "  If Bonjour discovery fails, type one of the above into" -ForegroundColor DarkGray
    Write-Host "  Things > Settings > Sync > Connect manually." -ForegroundColor DarkGray
}

# ── Check the network profile, which is the usual real culprit ──────────────
Write-Host ""
$publicNets = Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public'
if ($publicNets) {
    Write-Host "WARNING: these connections are set to Public, so the rule above does NOT apply:" -ForegroundColor Yellow
    $publicNets | ForEach-Object { Write-Host ("  - {0}" -f $_.Name) -ForegroundColor Yellow }
    Write-Host "  Set your home network to Private in Settings > Network, or sync will not connect." -ForegroundColor Yellow
} else {
    Write-Host "Network profile: Private. Good." -ForegroundColor Green
}

Write-Host ""
Write-Host "Web client stays loopback-only at http://localhost:6767 (not opened, by design)." -ForegroundColor DarkGray
