# =============================================================================
# Troubleshoot Local Kubernetes HTTPS Setup
# =============================================================================
# This script diagnoses common issues with local HTTPS configuration.
# =============================================================================

param(
    [switch]$Verbose
)

$ErrorActionPreference = "Continue"

function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Write-Step { param($Message) Write-Host "[STEP] $Message" -ForegroundColor Cyan }
function Write-Check { param($Message) Write-Host "  [✓] $Message" -ForegroundColor Green }
function Write-Cross { param($Message) Write-Host "  [✗] $Message" -ForegroundColor Red }

Write-Host "=============================================="
Write-Host "Troubleshooting Local K8s HTTPS Setup"
Write-Host "=============================================="
Write-Host ""

$issues = @()

# Check 1: Hosts file entries
Write-Step "Checking hosts file..."
$hostsContent = Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -Raw

$domains = @("app.localhost", "api.localhost", "hello.localhost", "keycloak.localhost", "gitlab.localhost", "argocd.localhost", "grafana.localhost")
foreach ($domain in $domains) {
    if ($hostsContent -match $domain) {
        Write-Check "$domain is configured"
    } else {
        Write-Cross "$domain is NOT configured"
        $issues += "Missing hosts entry for $domain"
    }
}
Write-Host ""

# Check 2: CA Certificate in Windows store
Write-Step "Checking CA certificate..."
$caCert = Get-ChildItem -Path Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*Local Development CA*" }

if ($caCert) {
    Write-Check "CA certificate is installed"
    Write-Host "      Subject: $($caCert.Subject)"
    Write-Host "      Valid until: $($caCert.NotAfter)"
    
    if ($caCert.NotAfter -lt (Get-Date)) {
        Write-Cross "CA certificate has EXPIRED"
        $issues += "CA certificate has expired"
    }
} else {
    Write-Cross "CA certificate is NOT installed"
    $issues += "CA certificate not found in Windows trust store"
}
Write-Host ""

# Check 3: DNS resolution
Write-Step "Checking DNS resolution..."
foreach ($domain in $domains) {
    try {
        $result = [System.Net.Dns]::GetHostAddresses($domain)
        Write-Check "$domain resolves to $($result.IPAddressToString)"
    } catch {
        Write-Cross "$domain does NOT resolve"
        $issues += "DNS resolution failed for $domain"
    }
}
Write-Host ""

# Check 4: Port connectivity
Write-Step "Checking port connectivity..."
$testPort = 443

foreach ($domain in $domains) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $connect = $tcp.BeginConnect($domain, $testPort, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne(3000, $false)
        
        if ($wait) {
            $tcp.EndConnect($connect)
            Write-Check "Port $testPort on $domain is reachable"
        } else {
            Write-Cross "Port $testPort on $domain is NOT reachable (timeout)"
            $issues += "Cannot connect to port $testPort on $domain"
        }
        $tcp.Close()
    } catch {
        Write-Cross "Port $testPort on $domain is NOT reachable"
        $issues += "Cannot connect to port $testPort on $domain - $_"
    }
}
Write-Host ""

# Check 5: HTTPS certificate validity
Write-Step "Checking HTTPS certificates..."
foreach ($domain in $domains) {
    try {
        $request = [System.Net.HttpWebRequest]::Create("https://$domain/")
        $request.Timeout = 5000
        $request.AllowAutoRedirect = $false
        
        try {
            $response = $request.GetResponse()
            $response.Close()
            Write-Check "HTTPS to $domain works"
        } catch [System.Net.WebException] {
            if ($_.Exception.Status -eq "TrustFailure") {
                Write-Cross "Certificate for $domain is NOT trusted"
                $issues += "Certificate not trusted for $domain"
            } elseif ($_.Exception.Status -eq "ConnectFailure") {
                Write-Cross "Cannot connect to $domain"
                $issues += "Connection failed to $domain"
            } else {
                # Other errors might be fine (404, etc) - connection worked
                Write-Check "HTTPS to $domain connects (got error: $($_.Exception.Status))"
            }
        }
    } catch {
        Write-Cross "Error testing $domain - $_"
    }
}
Write-Host ""

# Check 6: Invoke-WebRequest test (PowerShell HTTP client)
Write-Step "Testing with Invoke-WebRequest..."
$testDomains = @("keycloak.localhost", "gitlab.localhost", "argocd.localhost")

foreach ($domain in $testDomains) {
    try {
        $response = Invoke-WebRequest -Uri "https://$domain" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Write-Check "$domain - HTTP $($response.StatusCode)"

        if ($Verbose) {
            Write-Host "      Certificate: $($response.BaseResponse.ServicePoint.Certificate.Subject)"
        }
    } catch [System.Net.WebException] {
        $errorDetails = $_.Exception.Message

        if ($errorDetails -match "RemoteCertificateNameMismatch") {
            Write-Cross "$domain - Certificate name mismatch"
            $issues += "Certificate name mismatch for $domain"
        } elseif ($errorDetails -match "RemoteCertificateChainErrors") {
            Write-Cross "$domain - Certificate chain error (CA not trusted)"
            $issues += "Certificate not trusted for $domain (run install-ca.ps1)"
        } elseif ($errorDetails -match "ConnectFailure") {
            Write-Cross "$domain - Connection failed"
            $issues += "Cannot connect to $domain"
        } else {
            Write-Warn "$domain - $errorDetails"
        }
    } catch {
        $errorMsg = $_.Exception.Message
        Write-Cross "$domain - Error: $errorMsg"

        if ($Verbose -and $_.Exception.InnerException) {
            Write-Host "      Inner: $($_.Exception.InnerException.Message)" -ForegroundColor Yellow
        }

        $issues += "Web request failed for $domain"
    }
}
Write-Host ""

# Summary
Write-Host "=============================================="
if ($issues.Count -eq 0) {
    Write-Host "All checks passed!" -ForegroundColor Green
} else {
    Write-Host "Issues found: $($issues.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Warn "Recommended fixes:"
    Write-Host ""
    
    if ($issues -match "hosts entry") {
        Write-Host "  Hosts file:"
        Write-Host "    Run as Administrator: .\setup-hosts.ps1"
        Write-Host ""
    }
    
    if ($issues -match "CA certificate") {
        Write-Host "  CA Certificate:"
        Write-Host "    1. Run in WSL: ./setup-ca.sh"
        Write-Host "    2. Run as Administrator: .\install-ca.ps1"
        Write-Host ""
    }
    
    if ($issues -match "Cannot connect") {
        Write-Host "  Connection issues:"
        Write-Host "    1. Check if Rancher Desktop is running"
        Write-Host "    2. Check if ingress controller is running:"
        Write-Host "       kubectl get pods -n ingress-nginx"
        Write-Host "    3. Check ingress service:"
        Write-Host "       kubectl get svc -n ingress-nginx"
        Write-Host ""
    }
    
    if ($issues -match "not trusted") {
        Write-Host "  Certificate trust:"
        Write-Host "    Reinstall CA certificate: .\install-ca.ps1"
        Write-Host "    (May need to restart browser)"
        Write-Host ""
    }

    if ($issues -match "Web request failed" -and $issues -notmatch "Cannot connect") {
        Write-Host "  SSL/TLS issues with Invoke-WebRequest:"
        Write-Host "    1. Try accessing in browser (should work if CA installed)"
        Write-Host "    2. Restart PowerShell session"
        Write-Host "    3. Check certificate details:"
        Write-Host "       .\troubleshoot.ps1 -Verbose"
        Write-Host "    4. Test specific service:"
        Write-Host "       curl -k https://keycloak.localhost"
        Write-Host ""
    }
}
Write-Host "=============================================="
