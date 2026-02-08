# Kubernetes Platform Setup

This directory contains infrastructure for deploying the DevOps platform to:
- **Local**: WSL with Rancher Desktop, dockerd, nginx ingress
- **UpCloud**: Managed Kubernetes cluster

**Applications are managed via ArgoCD GitOps** - see [argocd/README.md](argocd/README.md).

## Directory Structure

```
k8s/
├── argocd/                      # ArgoCD GitOps application management
│   ├── apps/                    # Application definitions (GitOps)
│   │   ├── app-of-apps.yaml     # Root app that manages all apps
│   │   └── *.yaml               # Individual app manifests
│   └── projects/                # ArgoCD project definitions
│       └── tshub.yaml
├── base/
│   └── devops/                  # DevOps platform components
│       ├── argocd/values.yaml
│       ├── cert-manager/
│       ├── external-dns/
│       ├── external-secrets/
│       ├── gitlab/values.yaml
│       ├── keycloak/values.yaml
│       ├── monitoring/
│       ├── namespaces/
│       └── vault/values.yaml
├── overlays/
│   ├── local/
│   │   ├── config.yaml          # Environment configuration
│   │   └── devops/              # DevOps overrides
│   │       ├── ingress.yaml
│   │       ├── gitlab/values.yaml
│   │       ├── keycloak/values.yaml
│   │       ├── vault/values.yaml
│   │       ├── argocd/values.yaml
│   │       └── monitoring/values.yaml
│   └── upcloud/
│       ├── config.yaml          # Your domain config
│       ├── cert-manager/
│       └── devops/              # DevOps overrides (templated)
│           └── */values.yaml
├── scripts/
│   ├── local/                   # Local setup scripts
│   ├── upcloud/                 # UpCloud setup scripts
│   └── windows/                 # Windows configuration
├── certs/                       # Generated certificates (gitignored)
└── docs/
```

## Quick Start

### Local Development

```bash
# 1. Generate certificates
cd k8s/scripts/local
./setup-ca.sh

# 2. Configure Windows (run as Administrator in PowerShell)
cd k8s\scripts\windows
.\setup-all.ps1

# 3. Set up cluster with nginx-ingress
./setup-cluster.sh

# 4. Deploy DevOps platform
./deploy.sh local

# 5. Bootstrap ArgoCD app-of-apps (after adding your apps)
./deploy.sh local bootstrap
```

### UpCloud Production

```bash
# 1. Configure kubectl to point to UpCloud cluster

# 2. Set up the cluster
cd k8s/scripts/upcloud
./setup-cluster.sh

# 3. Deploy platform
export DOMAIN=yourdomain.com
export ACME_EMAIL=admin@yourdomain.com
./deploy.sh upcloud

# 4. Bootstrap ArgoCD
./deploy.sh upcloud bootstrap
```

## Deploy Script Usage

The deploy script handles DevOps platform infrastructure:

```bash
./deploy.sh [local|upcloud] [component] [action]
```

**Components:**
- `all` / `devops` - Deploy entire platform (default)
- `keycloak`, `vault`, `monitoring`, `gitlab`, `argocd` - Individual components
- `bootstrap` - Deploy ArgoCD app-of-apps for GitOps

**Actions:**
- `deploy` - Install/upgrade (default)
- `status` - Show deployment status
- `delete` - Remove resources

**Examples:**
```bash
# Deploy platform locally
./deploy.sh local

# Check status
./deploy.sh local all status

# Deploy only ArgoCD
./deploy.sh local argocd

# Bootstrap GitOps apps
./deploy.sh local bootstrap
```

## Application Management (GitOps)

Applications are **not** deployed directly by this script. They are managed via ArgoCD GitOps:

1. **Add Application manifests** to `k8s/argocd/apps/`:
   ```yaml
   # k8s/argocd/apps/my-service.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: my-service
     namespace: argocd
   spec:
     project: tshub
     source:
       repoURL: https://gitlab.local.dev/tshub/my-service.git
       path: k8s
     destination:
       server: https://kubernetes.default.svc
       namespace: tshub
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   ```

2. **Bootstrap** the app-of-apps:
   ```bash
   ./deploy.sh local bootstrap
   ```

3. ArgoCD will automatically sync and manage all applications

See [argocd/README.md](argocd/README.md) for detailed GitOps documentation.

## Configuration

Domain and environment-specific settings are managed through overlay files.

### Configuration Structure

```
overlays/
├── local/
│   ├── config.yaml              # Environment config (domain, TLS)
│   └── devops/
│       ├── gitlab/values.yaml   # Uses ${DOMAIN} placeholder
│       ├── keycloak/values.yaml # Uses ${DOMAIN} placeholder
│       ├── vault/values.yaml    # Uses ${DOMAIN} placeholder
│       ├── argocd/values.yaml   # Uses ${DOMAIN} placeholder
│       └── monitoring/values.yaml
└── upcloud/
    ├── config.yaml              # Your domain configuration
    └── devops/
        └── */values.yaml        # Uses ${DOMAIN} placeholder
```

### Configuring Domain

All overlay files use `${DOMAIN}` and `${TLS_SECRET_NAME}` placeholders that are templated by `deploy.sh` using values from `config.yaml`.

**Edit the config file** for your environment:

```yaml
# overlays/local/config.yaml (or overlays/upcloud/config.yaml)
domain: local.dev          # Your base domain
tls:
  secretName: local-tls-secret  # TLS secret name
acmeEmail: admin@example.com    # For cert-manager (upcloud only)
```

**For UpCloud**, you can also use environment variable overrides for CI/CD:

```bash
export DOMAIN=yourdomain.com
export ACME_EMAIL=admin@yourdomain.com
./deploy.sh upcloud
```

### How It Works

1. **config.yaml**: Single source of truth for domain and TLS settings
2. **deploy.sh**: Reads config.yaml and exports values as environment variables
3. **envsubst**: Templates `${DOMAIN}`, `${TLS_SECRET_NAME}` in overlay files
4. **Helm/kubectl**: Applies templated configurations

## Services

### DevOps Platform

URLs are derived from `domain` in [config.yaml](overlays/local/config.yaml). Default local domain is `local.dev`:

| Service | URL Pattern | Description |
|---------|-------------|-------------|
| Keycloak | https://keycloak.{domain} | Identity & SSO |
| Vault | https://vault.{domain} | Secrets management |
| GitLab | https://gitlab.{domain} | Source control & CI |
| Registry | https://registry.{domain} | Container registry |
| ArgoCD | https://argocd.{domain} | GitOps deployments |
| Grafana | https://grafana.{domain} | Dashboards |
| Prometheus | https://prometheus.{domain} | Metrics |

## Credentials

After deployment, retrieve credentials:

```bash
# Keycloak admin
kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.admin-password}' | base64 -d

# Grafana admin
kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

# ArgoCD admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# GitLab root
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d
```

## Architecture

### Local Environment
```
Windows Browser
     ↓ HTTPS (443)
WSL localhost → Rancher Desktop → nginx-ingress → Services
     ↑
  Local CA certificates installed in Windows trust store
```

### Production Environment
```
Internet
    ↓ HTTPS (443)
UpCloud LoadBalancer → nginx-ingress → Services
                           ↑
         cert-manager (Let's Encrypt certificates)
```

## Adding New Applications

Applications are managed via ArgoCD GitOps. To add a new application:

1. **Create an Application manifest** in `argocd/apps/`:
   ```yaml
   # argocd/apps/my-service.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: my-service
     namespace: argocd
   spec:
     project: tshub
     source:
       repoURL: https://gitlab.local.dev/tshub/my-service.git
       targetRevision: HEAD
       path: k8s
     destination:
       server: https://kubernetes.default.svc
       namespace: tshub
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```

2. **Commit and push** - ArgoCD will automatically detect and deploy

3. **For local TLS**, add the domain to `scripts/local/setup-ca.sh` and regenerate certs

4. **For Windows hosts**, add entry in `scripts/windows/setup-hosts.ps1`

See [argocd/README.md](argocd/README.md) for more patterns (Helm, Kustomize, ApplicationSets).

## Troubleshooting

### Certificate not trusted on Windows
```powershell
# Run as Administrator
.\install-ca.ps1
```

### Cannot access services from Windows
```powershell
# Run troubleshooting script
.\troubleshoot.ps1
```

### Pods not starting
```bash
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### Ingress not working
```bash
kubectl get ingress -A
kubectl describe ingress -n <namespace>
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
```

### ArgoCD sync issues
```bash
# Check app status
argocd app get <app-name>

# Force sync
argocd app sync <app-name> --force

# Check ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

## See Also

- [docs/LOCAL_SETUP.md](docs/LOCAL_SETUP.md) - Detailed local setup guide
- [docs/UPCLOUD_SETUP.md](docs/UPCLOUD_SETUP.md) - UpCloud deployment guide
