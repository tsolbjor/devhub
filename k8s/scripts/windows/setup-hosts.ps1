# =============================================================================
# Setup Windows Hosts File
# =============================================================================
# This script adds entries to the Windows hosts file to route local
# development domains to the Kubernetes cluster.
#
# MUST BE RUN AS ADMINISTRATOR
# =============================================================================

#Requires -RunAsAdministrator

param(
    [string]$IP = "127.0.0.1",
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

# Colors for output
function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Write-Step { param($Message) Write-Host "[STEP] $Message" -ForegroundColor Cyan }

Write-Host "=============================================="
Write-Host "Setup Windows Hosts File"
Write-Host "=============================================="
Write-Host ""

# Domains to add to hosts file
$Domains = @(
    # Application domains
    "app.localhost",
    "api.localhost",
    "auth.localhost",
    "hello.localhost",
    # DevOps domains
    "keycloak.localhost",
    "vault.localhost",
    "gitlab.localhost",
    "registry.localhost",
    "argocd.localhost",
    "grafana.localhost",
    "prometheus.localhost"
)

$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$Marker = "# tshub local development"

# Check if hosts file exists
if (-not (Test-Path $HostsFile)) {
    Write-Err "Hosts file not found at: $HostsFile"
    exit 1
}

Write-Info "Hosts file: $HostsFile"
Write-Info "Target IP: $IP"
Write-Host ""

# Read current hosts file
$CurrentContent = Get-Content $HostsFile -Raw

# Remove existing entries if present
if ($CurrentContent -match $Marker) {
    Write-Step "Removing existing tshub entries..."
    
    # Remove the block between markers
    $pattern = "(?s)$Marker.*?$Marker end"
    $CurrentContent = $CurrentContent -replace $pattern, ""
    
    # Clean up extra blank lines
    $CurrentContent = $CurrentContent -replace "(\r?\n){3,}", "`r`n`r`n"
    $CurrentContent = $CurrentContent.Trim()
    
    Write-Info "Existing entries removed."
}

if ($Remove) {
    Write-Step "Saving hosts file..."
    Set-Content -Path $HostsFile -Value $CurrentContent -NoNewline
    Write-Info "tshub entries removed from hosts file."
    exit 0
}

# Build the new entries block
Write-Step "Adding domain entries..."

$NewEntries = @()
$NewEntries += ""
$NewEntries += $Marker
$NewEntries += "# Added by setup-hosts.ps1 - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

foreach ($domain in $Domains) {
    $NewEntries += "$IP`t$domain"
    Write-Host "  Added: $domain -> $IP"
}

$NewEntries += "$Marker end"
$NewEntries += ""

# Append to hosts file
$NewContent = $CurrentContent + ($NewEntries -join "`r`n")

Write-Step "Saving hosts file..."
Set-Content -Path $HostsFile -Value $NewContent -NoNewline

Write-Info "Hosts file updated successfully!"

# Flush DNS cache
Write-Step "Flushing DNS cache..."
ipconfig /flushdns | Out-Null
Write-Info "DNS cache flushed."

Write-Host ""
Write-Host "=============================================="
Write-Host "Setup Complete!"
Write-Host "=============================================="
Write-Host ""
Write-Host "The following domains now point to ${IP}:"
foreach ($domain in $Domains) {
    Write-Host "  - https://$domain"
}
Write-Host ""
Write-Host "You can verify with:"
Write-Host "  ping app.local.dev"
Write-Host ""
Write-Host "To remove these entries later, run:"
Write-Host "  .\setup-hosts.ps1 -Remove"
Write-Host ""
