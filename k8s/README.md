# Kubernetes Platform

Deploys the DevOps platform services onto Kubernetes clusters. Supports local development (Rancher Desktop) and UpCloud managed clusters.

**Applications are managed via ArgoCD GitOps** — see [argocd/README.md](argocd/README.md).

## Directory Structure

```
k8s/
├── argocd/                          # ArgoCD GitOps application management
│   ├── apps/                        #   Application definitions (app-of-apps)
│   └── projects/                    #   ArgoCD project RBAC
├── base/
│   └── devops/                      # Base Helm values for each service
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
│   ├── local/                       # Local: Rancher Desktop / WSL2
│   │   ├── config.yaml              #   Domain, TLS, data services config
│   │   ├── data-services/           #   StatefulSets for PG, Valkey, MinIO
│   │   └── devops/                  #   Helm value overrides + ingress.yaml
│   ├── upcloud/
│   │   └── devops/                  #   Shared UpCloud Helm value overrides
│   ├── upcloud-dev/                 # UpCloud dev environment
│   │   ├── config.yaml              #   Domain + managed data service endpoints
│   │   └── devops -> ../upcloud/devops
│   └── upcloud-prod/                # UpCloud prod environment
│       ├── config.yaml
│       └── devops -> ../upcloud/devops
├── scripts/
│   ├── lib/common.sh                # Shared library (logging, config, templating)
│   ├── deploy.sh                    # Main deployment script
│   ├── sync-tofu-outputs.sh         # Bridge: tofu outputs → config.yaml
│   ├── setup-all.sh                 # Full local automated setup
│   ├── setup-ca.sh                  # Generate local CA and TLS certs
│   ├── setup-cluster.sh             # nginx-ingress and cluster resources
│   ├── setup-keycloak.sh            # Keycloak realm, groups, OIDC clients
│   ├── setup-vault.sh               # Vault init, unseal, configure
│   ├── local/                       # Generated files for local env
│   ├── upcloud-dev/                 # Generated files for upcloud-dev (kubeconfig)
│   ├── upcloud-prod/                # Generated files for upcloud-prod (kubeconfig)
│   └── windows/                     # PowerShell: CA install, hosts file
├── certs/                           # Generated certificates (gitignored)
└── docs/                            # Detailed guides
```

## Quick Start

### Local Development

```bash
cd k8s/scripts

# One command — everything from CA certs to running services
./setup-all.sh --env local

# Or step by step:
./setup-ca.sh --env local
./setup-cluster.sh --env local
./deploy.sh --env local
./setup-keycloak.sh --env local
./setup-vault.sh --env local
```

### UpCloud (after tofu apply)

```bash
cd k8s/scripts

# Sync tofu outputs into config.yaml + fetch kubeconfig
./sync-tofu-outputs.sh --env upcloud-dev

# Edit domain and acmeEmail in overlays/upcloud-dev/config.yaml

# Deploy
export KUBECONFIG=upcloud-dev/kubeconfig
./deploy.sh --env upcloud-dev

# Configure SSO and Vault
./setup-keycloak.sh --env upcloud-dev
./setup-vault.sh --env upcloud-dev

# Bootstrap GitOps
./deploy.sh --env upcloud-dev bootstrap
```

## Deploy Script Usage

```bash
./deploy.sh --env local|upcloud-dev|upcloud-prod [component] [action]
```

**Components:**
- `all` / `devops` — Deploy entire platform (default)
- `keycloak`, `vault`, `monitoring`, `gitlab`, `argocd` — Individual services
- `data-services` — Data services only (local: StatefulSets, upcloud: managed config)
- `bootstrap` — Deploy ArgoCD app-of-apps
- `ingress` — Apply ingress rules only

**Actions:**
- `deploy` — Install/upgrade (default)
- `status` — Show deployment status
- `delete` — Remove resources

**Examples:**
```bash
./deploy.sh --env local                    # Deploy everything locally
./deploy.sh --env upcloud-dev argocd       # Deploy only ArgoCD to dev
./deploy.sh --env local all status         # Check all service status
./deploy.sh --env upcloud-prod all delete  # Tear down prod services
```

## Configuration

Each environment has a `config.yaml` in its overlay directory:

```yaml
domain: dev.example.com
tls:
  type: cert-manager
  secretName: ""
  clusterIssuer: letsencrypt-prod
acmeEmail: admin@example.com

dataServices:
  type: managed              # "local" for StatefulSets, "managed" for UpCloud
  postgresql:
    host: pg-host:11550      # Populated by sync-tofu-outputs.sh
  valkey:
    host: valkey-host:11550
  s3:
    endpoint: https://xxx.upcloudobjects.com
    region: europe-1
```

Helm values use `${DOMAIN}`, `${PG_HOST}`, etc. as placeholders, templated by `deploy.sh` via `envsubst`.

## Services

| Service | URL Pattern | Namespace |
|---------|-------------|-----------|
| Keycloak | `https://keycloak.{domain}` | `keycloak` |
| Vault | `https://vault.{domain}` | `vault` |
| GitLab | `https://gitlab.{domain}` | `gitlab` |
| Registry | `https://registry.{domain}` | `gitlab` |
| ArgoCD | `https://argocd.{domain}` | `argocd` |
| Grafana | `https://grafana.{domain}` | `monitoring` |
| Prometheus | `https://prometheus.{domain}` | `monitoring` |

## Credentials

```bash
# Keycloak admin
kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d

# Grafana admin
kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

# ArgoCD admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# GitLab root
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d
```

## Troubleshooting

```bash
# Pod issues
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>

# Ingress issues
kubectl get ingress -A
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx

# ArgoCD sync issues
argocd app list
argocd app get <app-name>
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

## See Also

- [docs/LOCAL_SETUP.md](docs/LOCAL_SETUP.md) — Detailed local setup guide
- [docs/UPCLOUD_SETUP.md](docs/UPCLOUD_SETUP.md) — UpCloud deployment guide
- [docs/KEYCLOAK_SSO.md](docs/KEYCLOAK_SSO.md) — Keycloak SSO configuration
- [argocd/README.md](argocd/README.md) — ArgoCD app-of-apps patterns
