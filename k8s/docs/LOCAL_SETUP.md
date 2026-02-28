# Local Development Quick Start Guide

This guide walks you through setting up trusted HTTPS for local Kubernetes development on Windows with WSL and Rancher Desktop.

## Prerequisites

- **Windows 11** or Windows 10
- **WSL 2** with Ubuntu or similar distribution
- **Rancher Desktop** installed and running with:
  - Container Runtime: dockerd (moby)
  - Kubernetes enabled
- **kubectl** installed in WSL
- **helm** installed in WSL
- **openssl** installed in WSL (usually pre-installed)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Windows Host                             │
│  ┌─────────────┐                                            │
│  │   Browser   │ ◄─── HTTPS (trusted)                       │
│  └──────┬──────┘                                            │
│         │                                                    │
│         ▼                                                    │
│   hosts file: app.localhost → 127.0.0.1                     │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                      WSL 2                               ││
│  │  ┌───────────────────────────────────────────────────┐  ││
│  │  │              Rancher Desktop K8s                   │  ││
│  │  │                                                    │  ││
│  │  │  ┌──────────────┐  ┌──────────────┐              │  ││
│  │  │  │nginx-ingress │  │   Services   │              │  ││
│  │  │  │ (port 443)   │──│  (devhub ns)  │              │  ││
│  │  │  │  + TLS cert  │  │              │              │  ││
│  │  │  └──────────────┘  └──────────────┘              │  ││
│  │  │                                                    │  ││
│  │  │  local-tls-secret (generated cert)                │  ││
│  │  │  local-ca-certificates (CA for service trust)     │  ││
│  │  └───────────────────────────────────────────────────┘  ││
│  └─────────────────────────────────────────────────────────┘│
│                                                              │
│  Windows Certificate Store: Local Development CA (trusted)  │
└─────────────────────────────────────────────────────────────┘
```

## Step-by-Step Setup

### Quick Start (Fully Automated)

For a completely automated setup with **zero manual intervention**, run:

```bash
cd k8s/scripts/local
./setup-all.sh
```

This single command will:
1. Generate CA and TLS certificates
2. Install nginx-ingress controller
3. Deploy all DevOps components (Keycloak, Vault, GitLab, ArgoCD, Monitoring)
4. Initialize and unseal Vault
5. Configure Keycloak realm and OIDC clients
6. Wait for GitLab to be ready
7. Bootstrap ArgoCD app-of-apps

Estimated time: 20-40 minutes (GitLab takes the longest)

### Manual Step-by-Step (Alternative)

If you prefer to run each step manually:

#### Step 1: Generate Certificates (WSL)

```bash
cd k8s/scripts/local
./setup-ca.sh
```

This creates:
- A local Certificate Authority (CA)
- TLS certificates for `*.localhost` domains
- Kubernetes Secret and ConfigMap manifests

#### Step 2: Configure Windows (PowerShell as Administrator)

Navigate to the project directory and run:

```powershell
cd k8s\scripts\windows
.\setup-all.ps1
```

Or run the scripts individually:

```powershell
# Install CA certificate to Windows trust store
.\install-ca.ps1

# Add local domains to hosts file
.\setup-hosts.ps1
```

**What this does:**
- Installs the CA certificate so Windows browsers (Chrome, Edge) trust it
- Adds entries to `C:\Windows\System32\drivers\etc\hosts`

#### Step 3: Set Up Kubernetes Cluster (WSL)

```bash
cd k8s/scripts/local
./setup-cluster.sh
```

This:
- Installs nginx-ingress controller via Helm
- Creates the `devhub` namespace
- Applies TLS secrets and CA certificates

#### Step 4: Deploy DevOps Platform (WSL)

```bash
cd k8s/scripts/local
./deploy.sh
```

#### Step 5: Configure Services (WSL)

```bash
# Initialize and configure Vault
./setup-vault.sh

# Configure Keycloak realm and OIDC clients
./setup-keycloak.sh

# Bootstrap ArgoCD app-of-apps
./deploy.sh local bootstrap
```

#### Step 6: Access Your Services

Open your browser and navigate to:
- https://keycloak.localhost
- https://vault.localhost
- https://gitlab.localhost
- https://argocd.localhost
- https://grafana.localhost

You should see a valid (green padlock) HTTPS connection!

## Making Services Trust the CA

When your containerized services need to make HTTPS calls to other local services, they need to trust the local CA. The setup creates a ConfigMap (`local-ca-certificates`) containing the CA certificate.

### Node.js Applications

```yaml
env:
  - name: NODE_EXTRA_CA_CERTS
    value: /etc/ssl/certs/local-ca.crt
volumeMounts:
  - name: ca-certificates
    mountPath: /etc/ssl/certs/local-ca.crt
    subPath: ca.crt
volumes:
  - name: ca-certificates
    configMap:
      name: local-ca-certificates
```

### .NET Applications

```yaml
env:
  - name: SSL_CERT_FILE
    value: /etc/ssl/certs/local-ca.crt
volumeMounts:
  - name: ca-certificates
    mountPath: /etc/ssl/certs/local-ca.crt
    subPath: ca.crt
volumes:
  - name: ca-certificates
    configMap:
      name: local-ca-certificates
```

### Python Applications

```yaml
env:
  - name: REQUESTS_CA_BUNDLE
    value: /etc/ssl/certs/local-ca.crt
  - name: SSL_CERT_FILE
    value: /etc/ssl/certs/local-ca.crt
volumeMounts:
  - name: ca-certificates
    mountPath: /etc/ssl/certs/local-ca.crt
    subPath: ca.crt
volumes:
  - name: ca-certificates
    configMap:
      name: local-ca-certificates
```

## Troubleshooting

### Run the diagnostic tool (Windows)

```powershell
cd k8s\scripts\windows
.\troubleshoot.ps1
```

### Common Issues

#### Certificate not trusted in browser
1. Re-run `install-ca.ps1` as Administrator
2. Restart your browser completely
3. Check if the CA is in Windows Certificate Manager:
   - Run `certmgr.msc`
   - Look under "Trusted Root Certification Authorities" → "Certificates"
   - Find "Local Development CA"

#### Cannot access local domains
1. Check hosts file: `type C:\Windows\System32\drivers\etc\hosts`
2. Flush DNS: `ipconfig /flushdns`
3. Verify with: `ping app.localhost`

#### Ingress not working
```bash
# Check ingress controller pods
kubectl get pods -n ingress-nginx

# Check ingress service
kubectl get svc -n ingress-nginx

# Check ingress rules
kubectl get ingress -n devhub
kubectl describe ingress -n devhub
```

#### Services can't reach each other with HTTPS
1. Verify CA ConfigMap exists: `kubectl get configmap local-ca-certificates -n devhub`
2. Check pod has the volume mounted correctly
3. Check the environment variable is set

## Adding New Domains

1. Edit [setup-ca.sh](../scripts/local/setup-ca.sh) and add domains to the `DOMAINS` array
2. Re-run `./setup-ca.sh` (this regenerates certificates)
3. Update `hosts` file on Windows: `.\setup-hosts.ps1`
4. Update [overlays/local/apps/ingress.yaml](../overlays/local/apps/ingress.yaml) for apps
5. Or update [overlays/local/devops/ingress.yaml](../overlays/local/devops/ingress.yaml) for devops

## Firefox Support

Firefox uses its own certificate store. To trust the local CA:

1. Open Firefox Settings
2. Search for "certificates"
3. Click "View Certificates"
4. Go to "Authorities" tab
5. Click "Import" and select the CA certificate from:
   - WSL path: `\\wsl$\Ubuntu\home\<user>\code\devhub\k8s\certs\ca\ca.crt`
6. Check "Trust this CA to identify websites"
7. Click OK
