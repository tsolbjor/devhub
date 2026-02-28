# devhub

Kubernetes DevOps platform for local development and cloud environments. Two layers: **OpenTofu** provisions cloud infrastructure, **Helm/K8s scripts** deploy platform services on top.

## Platform Services

| Service | Purpose |
|---------|---------|
| **Keycloak** | Identity management and SSO (OIDC) |
| **Vault** | Secrets management |
| **GitLab** | Source control, CI/CD, container registry |
| **ArgoCD** | GitOps continuous deployment |
| **Prometheus** | Metrics collection and alerting |
| **Grafana** | Dashboards and observability |
| **Loki** | Log aggregation |
| **Tempo** | Distributed tracing |

## Environments

| Environment | Infrastructure | Data Services | Domain |
|-------------|---------------|---------------|--------|
| `local` | Local Kubernetes (Rancher Desktop or similar) | StatefulSets (PG, Valkey, MinIO) | `*.localhost` |
| `upcloud-dev`, `upcloud-prod` | UpCloud Managed K8s | Managed (PG, Valkey, S3) | configurable |
| `azure-dev`, `azure-prod` | AKS | Managed (PostgreSQL, Redis, Blob) | configurable |
| `gcp-dev`, `gcp-prod` | GKE | Managed (PostgreSQL, Redis, GCS) | configurable |
| `aws-dev`, `aws-prod` | EKS | Managed (PostgreSQL, Redis, S3) | configurable |

## Repository Structure

```
devhub/
├── tofu/                            # Infrastructure as Code (OpenTofu)
│   ├── upcloud/                     #   UpCloud modules + env roots
│   ├── azure/                       #   Azure modules + env roots
│   ├── gcp/                         #   GCP modules + env roots
│   └── aws/                         #   AWS modules + env roots
│
├── k8s/                             # Kubernetes platform deployment
│   ├── base/devops/                 #   Base Helm values for each service
│   ├── overlays/
│   │   ├── local/                   #   Local: config.yaml + Helm overrides + data-services
│   │   ├── upcloud/, azure/, gcp/, aws/  #   Shared cloud Helm value overrides
│   │   ├── upcloud-dev/, upcloud-prod/   #   UpCloud env overlays
│   │   ├── azure-dev/, azure-prod/       #   Azure env overlays
│   │   ├── gcp-dev/, gcp-prod/           #   GCP env overlays
│   │   └── aws-dev/, aws-prod/           #   AWS env overlays
│   ├── argocd/                      #   ArgoCD app-of-apps manifests (GitOps)
│   ├── scripts/                     #   Deployment and setup scripts
│   └── docs/                        #   Detailed setup guides
│
└── CLAUDE.md                        # AI assistant context
```

## Quick Start

### Local Development

```bash
# One command — sets up everything (CA, certs, nginx-ingress, all services)
cd k8s/scripts
./setup-all.sh --env local
```

Services available at `https://{service}.localhost` (Keycloak, GitLab, ArgoCD, Grafana, etc.)

### UpCloud Deployment

```bash
# 1. Provision infrastructure
cd tofu/upcloud/dev
tofu init && tofu apply

# 2. Sync tofu outputs to k8s config + fetch kubeconfig
cd k8s/scripts
./sync-tofu-outputs.sh --env upcloud-dev

# 3. Edit domain and email in k8s/overlays/upcloud-dev/config.yaml

# 4. Deploy platform services
export KUBECONFIG=upcloud-dev/kubeconfig
./deploy.sh --env upcloud-dev
```

## How It Works

### Infrastructure Layer (OpenTofu)

The `tofu/` directory contains provider-specific modules and environment roots for UpCloud, Azure, GCP, and AWS. Managed deployments provision:

- **Kubernetes cluster** (provider-managed)
- **PostgreSQL** for Keycloak and GitLab
- **Redis/Valkey** for GitLab caching/session workloads
- **Object storage** for GitLab artifacts, packages, registry, and backups

Dev and prod environments use separate state and configurable sizing.

### Platform Layer (K8s Scripts)

The `k8s/scripts/` directory deploys services via Helm:

1. `config.yaml` per overlay defines domain, TLS, and data service endpoints
2. `deploy.sh` reads config, templates Helm values with `envsubst`, runs `helm upgrade --install`
3. `sync-tofu-outputs.sh` bridges the two layers by writing tofu outputs into config.yaml

Services are deployed in dependency order: namespaces, TLS, monitoring, Keycloak, Vault, External Secrets, GitLab, ArgoCD, ingress.

### GitOps Layer (ArgoCD)

Application workloads are managed via ArgoCD app-of-apps pattern. Add Application manifests to `k8s/argocd/apps/` and ArgoCD auto-discovers and syncs them.

## Common Operations

```bash
cd k8s/scripts

# Deploy a single service
./deploy.sh --env local keycloak

# Check all service status
./deploy.sh --env local all status

# Configure Keycloak SSO (realm, OIDC clients)
./setup-keycloak.sh --env local

# Initialize and unseal Vault
./setup-vault.sh --env local

# Bootstrap ArgoCD app-of-apps
./deploy.sh --env local bootstrap

# Tear down everything
./deploy.sh --env local all delete
```

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

## Documentation

- [k8s/docs/LOCAL_SETUP.md](k8s/docs/LOCAL_SETUP.md) — Local development setup guide
- [k8s/docs/UPCLOUD_SETUP.md](k8s/docs/UPCLOUD_SETUP.md) — UpCloud deployment guide
- [k8s/docs/KEYCLOAK_SSO.md](k8s/docs/KEYCLOAK_SSO.md) — Keycloak SSO configuration
- [k8s/docs/SSO_TESTING_GUIDE.md](k8s/docs/SSO_TESTING_GUIDE.md) — SSO testing guide
- [k8s/argocd/README.md](k8s/argocd/README.md) — ArgoCD app-of-apps patterns
