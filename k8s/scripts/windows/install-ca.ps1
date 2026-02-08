# =============================================================================
# Install CA Certificate on Windows
# =============================================================================
# This script installs the local development CA certificate into the
# Windows certificate store so browsers and applications trust it.
#
# MUST BE RUN AS ADMINISTRATOR
# =============================================================================

#Requires -RunAsAdministrator

param(
    [string]$CertPath = ""
)

$ErrorActionPreference = "Stop"

# Colors for output
function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Write-Step { param($Message) Write-Host "[STEP] $Message" -ForegroundColor Cyan }

Write-Host "=============================================="
Write-Host "Install CA Certificate on Windows"
Write-Host "=============================================="
Write-Host ""

# Find the certificate file
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$K8sDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)

# Check multiple possible locations
$PossiblePaths = @(
    (Join-Path $K8sDir "certs\ca\ca.crt"),
    (Join-Path $K8sDir "certs\ca\ca.pem"),
    "\\wsl$\Ubuntu\home\$env:USERNAME\code\tshub2\k8s\certs\ca\ca.crt",
    "\\wsl.localhost\Ubuntu\home\$env:USERNAME\code\tshub2\k8s\certs\ca\ca.crt"
)

if ($CertPath -and (Test-Path $CertPath)) {
    $CaFile = $CertPath
} else {
    $CaFile = $null
    foreach ($path in $PossiblePaths) {
        # Expand environment variables
        $expandedPath = [Environment]::ExpandEnvironmentVariables($path)
        if (Test-Path $expandedPath) {
            $CaFile = $expandedPath
            break
        }
    }
}

if (-not $CaFile) {
    Write-Err "CA certificate not found!"
    Write-Host ""
    Write-Host "Searched in:"
    foreach ($path in $PossiblePaths) {
        Write-Host "  - $path"
    }
    Write-Host ""
    Write-Host "Please run setup-ca.sh in WSL first, or provide the path:"
    Write-Host "  .\install-ca.ps1 -CertPath 'C:\path\to\ca.crt'"
    exit 1
}

Write-Info "Found CA certificate: $CaFile"

# Check if certificate is already installed
Write-Step "Checking for existing certificate..."
$ExistingCert = Get-ChildItem -Path Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*Local Development CA*" }

if ($ExistingCert) {
    Write-Warn "Found existing certificate with same name."
    Write-Host "  Subject: $($ExistingCert.Subject)"
    Write-Host "  Thumbprint: $($ExistingCert.Thumbprint)"
    Write-Host ""
    
    $response = Read-Host "Do you want to remove the old certificate and install new one? (y/n)"
    if ($response -eq 'y' -or $response -eq 'Y') {
        Write-Step "Removing old certificate..."
        Remove-Item -Path "Cert:\LocalMachine\Root\$($ExistingCert.Thumbprint)"
        Write-Info "Old certificate removed."
    } else {
        Write-Info "Keeping existing certificate. Exiting."
        exit 0
    }
}

# Install the certificate
Write-Step "Installing CA certificate to Trusted Root store..."

try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CaFile)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $store.Open("ReadWrite")
    $store.Add($cert)
    $store.Close()
    
    Write-Info "CA certificate installed successfully!"
    Write-Host ""
    Write-Host "Certificate details:"
    Write-Host "  Subject: $($cert.Subject)"
    Write-Host "  Issuer: $($cert.Issuer)"
    Write-Host "  Valid from: $($cert.NotBefore)"
    Write-Host "  Valid to: $($cert.NotAfter)"
    Write-Host "  Thumbprint: $($cert.Thumbprint)"
    Write-Host ""
} catch {
    Write-Err "Failed to install certificate: $_"
    exit 1
}

Write-Host "=============================================="
Write-Host "Installation Complete!"
Write-Host "=============================================="
Write-Host ""
Write-Host "The CA certificate is now trusted by Windows."
Write-Host "Browsers like Chrome and Edge will now trust"
Write-Host "certificates signed by this CA."
Write-Host ""
Write-Host "Note: Firefox uses its own certificate store."
Write-Host "You may need to import the certificate manually"
Write-Host "in Firefox settings."
Write-Host ""
