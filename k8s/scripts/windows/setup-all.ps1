# =============================================================================
# Complete Windows Setup for Local Kubernetes Development
# =============================================================================
# This script runs all Windows-side configuration needed for local
# Kubernetes development with trusted HTTPS.
#
# MUST BE RUN AS ADMINISTRATOR
# =============================================================================

#Requires -RunAsAdministrator

param(
    [switch]$SkipCa,
    [switch]$SkipHosts
)

$ErrorActionPreference = "Stop"

# Colors for output
function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Write-Step { param($Message) Write-Host "[STEP] $Message" -ForegroundColor Cyan }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=============================================="
Write-Host "Complete Windows Setup"
Write-Host "=============================================="
Write-Host ""
Write-Host "This script will:"
Write-Host "  1. Install the CA certificate to Windows trust store"
Write-Host "  2. Configure hosts file for local domains"
Write-Host ""

$response = Read-Host "Continue? (y/n)"
if ($response -ne 'y' -and $response -ne 'Y') {
    Write-Info "Aborted."
    exit 0
}

Write-Host ""

# Step 1: Install CA certificate
if (-not $SkipCa) {
    Write-Step "Step 1: Installing CA certificate..."
    Write-Host ""
    
    try {
        & "$ScriptDir\install-ca.ps1"
    } catch {
        Write-Err "Failed to install CA certificate: $_"
        Write-Warn "Continuing with remaining steps..."
    }
    
    Write-Host ""
} else {
    Write-Warn "Skipping CA installation (--SkipCa)"
}

# Step 2: Configure hosts file
if (-not $SkipHosts) {
    Write-Step "Step 2: Configuring hosts file..."
    Write-Host ""
    
    try {
        & "$ScriptDir\setup-hosts.ps1"
    } catch {
        Write-Err "Failed to configure hosts file: $_"
    }
    
    Write-Host ""
} else {
    Write-Warn "Skipping hosts configuration (--SkipHosts)"
}

# Summary
Write-Host ""
Write-Host "=============================================="
Write-Host "Windows Setup Complete!"
Write-Host "=============================================="
Write-Host ""
Write-Host "Summary:"
Write-Host "  - CA certificate installed: $(-not $SkipCa)"
Write-Host "  - Hosts file configured: $(-not $SkipHosts)"
Write-Host ""
Write-Host "Next steps in WSL:"
Write-Host "  1. cd k8s/scripts/local"
Write-Host "  2. ./setup-cluster.sh"
Write-Host "  3. ./deploy.sh"
Write-Host ""
Write-Host "Then access your services at:"
Write-Host "  - https://app.local.dev"
Write-Host "  - https://api.local.dev"
Write-Host ""
