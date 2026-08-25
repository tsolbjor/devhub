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

# Ask WSL where the certificate is, rather than guessing a UNC path.
#
# The guesses that used to live here were wrong in three independent ways:
# they assumed the distribution is named "Ubuntu", that the repository sits at
# ~/code/devhub, and — the one that actually bit — that the Linux username
# equals $env:USERNAME. It usually does not: Windows "ThomasSolbjor" against
# WSL "thomasolbjor" is enough, because the \\wsl.localhost share is
# case-sensitive. The result was "CA certificate not found" pointing at a path
# where the file demonstrably was.
#
# wsl.exe knows its own $HOME and its own distribution, and wslpath converts
# the answer to the UNC path Windows needs. The /home/* arm covers a repository
# cloned under another user's home.
function Find-CaInWsl {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $null }

    foreach ($leaf in @('ca.crt', 'ca.pem')) {
        $rel = "code/devhub/k8s/certs/ca/$leaf"
        try {
            $linux = & wsl.exe -- bash -lc "ls -1 `"`$HOME/$rel`" /home/*/$rel 2>/dev/null | head -1"
            $linux = ($linux | Out-String).Trim()
            if (-not $linux) { continue }

            $win = (& wsl.exe -- wslpath -w "$linux" | Out-String).Trim()
            if ($win -and (Test-Path -LiteralPath $win)) { return $win }
        } catch {
            # WSL not running, or no default distribution — fall through to the
            # local paths below and, failing those, the -CertPath instruction.
        }
    }
    return $null
}

# Check multiple possible locations
$PossiblePaths = @(
    (Join-Path $K8sDir "certs\ca\ca.crt"),
    (Join-Path $K8sDir "certs\ca\ca.pem")
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
    # Only ask WSL when the repository this script sits in has no certificate —
    # which is the case when it is run from a Windows clone rather than from
    # the WSL checkout that generated the CA.
    if (-not $CaFile) { $CaFile = Find-CaInWsl }
}

if (-not $CaFile) {
    Write-Err "CA certificate not found!"
    Write-Host ""
    Write-Host "Searched in:"
    foreach ($path in $PossiblePaths) {
        Write-Host "  - $path"
    }
    Write-Host "  - the WSL checkout (~/code/devhub and /home/*/code/devhub), via wsl.exe"
    Write-Host ""
    Write-Host "Please run setup-ca.sh in WSL first:"
    Write-Host "  ./devhub ca --env local"
    Write-Host ""
    Write-Host "If the repository lives somewhere else in WSL, pass the path directly."
    Write-Host "Print it from WSL with:"
    Write-Host "  wslpath -w `$PWD/k8s/certs/ca/ca.crt"
    Write-Host "then:"
    Write-Host "  .\install-ca.ps1 -CertPath '\\wsl.localhost\<distro>\...\ca.crt'"
    exit 1
}

Write-Info "Found CA certificate: $CaFile"

# Compare by thumbprint, not by name.
#
# The CA's subject is always "Local Development CA", so every regeneration
# collides by name with the one already in the store. Matching on the name and
# then keeping what was there meant that after `./devhub ca --env local` issued
# a *new* CA — which setup-ca.sh does whenever k8s/certs is empty, so after
# every reset — this script reported "Found existing certificate with same
# name", kept the superseded one, and left the browser unable to trust a single
# platform hostname. The platform looked broken; the certificate store was.
#
# Stale copies are also removed rather than accumulated: they are trusted roots
# valid for ten years, and leaving a pile of superseded development CAs in
# LocalMachine\Root is not something to do quietly.
Write-Step "Checking for existing certificate..."

$NewCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CaFile)
$Existing = @(Get-ChildItem -Path Cert:\LocalMachine\Root |
    Where-Object { $_.Subject -like "*Local Development CA*" })

if ($Existing.Thumbprint -contains $NewCert.Thumbprint) {
    Write-Info "This CA is already trusted (thumbprint $($NewCert.Thumbprint))."
    $Stale = @($Existing | Where-Object { $_.Thumbprint -ne $NewCert.Thumbprint })
    if ($Stale.Count -gt 0) {
        Write-Step "Removing $($Stale.Count) superseded development CA(s)..."
        foreach ($old in $Stale) {
            Write-Host "  - $($old.Thumbprint) (issued $($old.NotBefore))"
            Remove-Item -Path "Cert:\LocalMachine\Root\$($old.Thumbprint)" -Force
        }
    }
    Write-Info "Nothing to do."
    exit 0
}

if ($Existing.Count -gt 0) {
    Write-Warn "A different '$($NewCert.Subject)' is already trusted — it is superseded."
    Write-Step "Removing $($Existing.Count) old certificate(s)..."
    foreach ($old in $Existing) {
        Write-Host "  - $($old.Thumbprint) (issued $($old.NotBefore))"
        Remove-Item -Path "Cert:\LocalMachine\Root\$($old.Thumbprint)" -Force
    }
    Write-Info "Old certificate(s) removed."
}

# Install the certificate
Write-Step "Installing CA certificate to Trusted Root store..."

try {
    $cert = $NewCert
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
