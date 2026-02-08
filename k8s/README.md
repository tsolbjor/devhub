# Kubernetes Deployment Setup

This directory contains everything needed to deploy services to:
- **Local**: WSL with Rancher Desktop, dockerd, nginx ingress
- **UpCloud**: Managed Kubernetes cluster

## Directory Structure

```
k8s/
├── base/                    # Base Kubernetes manifests (shared)
│   ├── kustomization.yaml
│   └── namespace.yaml
├── overlays/
│   ├── local/              # Local development configuration
│   │   ├── kustomization.yaml
│   │   ├── ingress.yaml
│   │   └── tls-secret.yaml
│   └── upcloud/            # UpCloud production configuration
│       ├── kustomization.yaml
│       ├── ingress.yaml
│       └── cert-manager/
├── scripts/
│   ├── local/
│   │   ├── setup-ca.sh           # Generate local CA and certificates
│   │   ├── setup-cluster.sh      # Configure local k8s cluster
│   │   └── deploy.sh             # Deploy to local cluster
│   ├── upcloud/
│   │   ├── setup-cluster.sh      # Configure UpCloud cluster
│   │   └── deploy.sh             # Deploy to UpCloud
│   └── windows/
│       ├── setup-hosts.ps1       # Configure Windows hosts file
│       ├── install-ca.ps1        # Install CA certificate on Windows
│       └── setup-all.ps1         # Complete Windows setup
└── certs/                        # Generated certificates (gitignored)
```

## Quick Start

### Local Development

1. **Generate certificates and set up CA:**
   ```bash
   cd k8s/scripts/local
   ./setup-ca.sh
   ```

2. **Configure Windows host (run as Administrator in PowerShell):**
   ```powershell
   cd k8s\scripts\windows
   .\setup-all.ps1
   ```

3. **Set up the local cluster:**
   ```bash
   cd k8s/scripts/local
   ./setup-cluster.sh
   ```

4. **Deploy services:**
   ```bash
   cd k8s/scripts/local
   ./deploy.sh
   ```

### UpCloud Production

1. **Configure kubectl to point to UpCloud cluster**

2. **Set up the cluster with cert-manager:**
   ```bash
   cd k8s/scripts/upcloud
   ./setup-cluster.sh
   ```

3. **Deploy services:**
   ```bash
   cd k8s/scripts/upcloud
   ./deploy.sh
   ```

## Local Development Details

The local setup uses:
- **mkcert**: For generating locally-trusted certificates
- **nginx-ingress**: As the ingress controller
- **Custom CA**: Installed on both WSL and Windows for trusted HTTPS

### Domains

Local services are accessible at:
- `https://app.local.dev`
- `https://api.local.dev`
- Add more in the configuration as needed

### Ports

- HTTPS: 443 (mapped from ingress controller)
- HTTP: 80 (redirects to HTTPS)

## UpCloud Production Details

The UpCloud setup uses:
- **cert-manager**: For automatic Let's Encrypt certificates
- **nginx-ingress**: As the ingress controller (UpCloud managed)
- **LoadBalancer**: UpCloud's load balancer service

## Troubleshooting

### Certificate not trusted on Windows
Run the CA installation script again as Administrator:
```powershell
.\install-ca.ps1
```

### Cannot access services from Windows
1. Check hosts file entries: `C:\Windows\System32\drivers\etc\hosts`
2. Verify ingress is running: `kubectl get pods -n ingress-nginx`
3. Check ingress controller has external IP: `kubectl get svc -n ingress-nginx`

### Services not accessible
1. Check pods are running: `kubectl get pods -n tshub`
2. Check ingress rules: `kubectl get ingress -n tshub`
3. Check service endpoints: `kubectl get endpoints -n tshub`
