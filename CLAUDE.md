# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kubernetes DevOps platform with three layers:
1. **Infrastructure (OpenTofu)** — provisions K8s clusters and managed data services on UpCloud, Azure, GCP, or AWS
2. **Platform cluster (Helm/K8s)** — deploys DevOps services (Keycloak, Vault, GitLab, ArgoCD, Prometheus/Grafana/Loki/Tempo/Alloy, External-DNS, cert-manager, Crossplane)
3. **Workload cluster** — lean K8s cluster running developer apps, managed by platform ArgoCD via app-of-apps

Platform environments: `local` (Rancher Desktop/WSL2), `upcloud-dev`, `upcloud-prod`, `azure-dev`, `azure-prod`, `gcp-dev`, `gcp-prod`, `aws-dev`, `aws-prod`.
Workload environments: `upcloud-workload`, `azure-workload`, `gcp-workload`, `aws-workload`.

## Common Commands

### OpenTofu (infrastructure)

```bash
# UpCloud
cd tofu/upcloud/dev  && tofu init && tofu plan && tofu apply
cd tofu/upcloud/prod && tofu init && tofu plan && tofu apply

# Azure
cd tofu/azure/dev  && tofu init && tofu plan && tofu apply
cd tofu/azure/prod && tofu init && tofu plan && tofu apply

# GCP
cd tofu/gcp/dev  && tofu init && tofu plan && tofu apply
cd tofu/gcp/prod && tofu init && tofu plan && tofu apply

# AWS
cd tofu/aws/dev  && tofu init && tofu plan && tofu apply
cd tofu/aws/prod && tofu init && tofu plan && tofu apply
```

### K8s Scripts (platform services)

All scripts are in `k8s/scripts/`. Run from that directory.

```bash
# Full local automated setup (20-40 min, zero manual steps)
./setup-all.sh --env local

# Sync tofu outputs into k8s overlay config + fetch kubeconfig
./sync-tofu-outputs.sh --env upcloud-dev
./sync-tofu-outputs.sh --env azure-dev
./sync-tofu-outputs.sh --env gcp-dev
./sync-tofu-outputs.sh --env aws-dev

# Deploy entire platform (or redeploy after changes)
./deploy.sh --env local
./deploy.sh --env upcloud-dev

# Deploy a single service
./deploy.sh --env local keycloak
./deploy.sh --env local argocd
./deploy.sh --env local monitoring
./deploy.sh --env local vault
./deploy.sh --env local gitlab
./deploy.sh --env local external-dns
./deploy.sh --env local crossplane

# Check status
./deploy.sh --env local all status

# Delete everything
./deploy.sh --env local all delete

# Bootstrap ArgoCD app-of-apps
./deploy.sh --env local bootstrap

# Generate local CA and TLS certs
./setup-ca.sh --env local

# Set up nginx-ingress and cluster resources
./setup-cluster.sh --env local

# Configure Keycloak realm, groups, and OIDC clients
./setup-keycloak.sh --env local

# Initialize and unseal Vault
./setup-vault.sh --env local
```

### Workload Cluster (developer apps)

```bash
# Provision workload cluster infra (VPC + K8s, no data services)
cd tofu/aws/workload  && tofu init && tofu plan && tofu apply
cd tofu/azure/workload && tofu init && tofu plan && tofu apply
cd tofu/gcp/workload  && tofu init && tofu plan && tofu apply

# Sync workload tofu outputs + fetch kubeconfig
./sync-tofu-outputs.sh --env aws-workload

# Deploy minimal platform components to workload cluster
# (cert-manager, nginx-ingress, external-dns, external-secrets, alloy)
./deploy-workload.sh --env aws-workload

# Register workload cluster with platform ArgoCD + create Vault token + registry pull secret
./register-workload-cluster.sh --env aws-workload --platform-env aws-dev
```

## Architecture

### Deployment Workflow (all clouds)

```
tofu apply (dev/ or prod/ for chosen cloud)
    → provisions: K8s cluster + managed data services (cloud-specific)
    ↓
sync-tofu-outputs.sh --env <cloud>-dev
    → writes data service endpoints into k8s/overlays/<env>/config.yaml
    → fetches kubeconfig (via upctl / az / gcloud / aws eks)
    → writes cloud-specific env files (e.g. azure-idp.env, gcp-redis.env)
    ↓
deploy.sh --env <cloud>-dev
    → reads config.yaml, templates Helm values, deploys services
```

### Workload Cluster Workflow

```
tofu apply (workload/ for chosen cloud)
    → provisions: VPC + K8s cluster + external-dns IAM only (no data services)
    ↓
sync-tofu-outputs.sh --env <cloud>-workload
    → writes external-dns IAM into k8s/overlays/<cloud>-workload/config.yaml
    → fetches workload cluster kubeconfig
    ↓
deploy-workload.sh --env <cloud>-workload
    → installs: cert-manager, nginx-ingress, external-dns, external-secrets, alloy
    ↓
register-workload-cluster.sh --env <cloud>-workload
    → registers cluster with platform ArgoCD (argocd cluster add)
    → creates Vault policy + token → stores in workload cluster external-secrets ns
    → creates GitLab group deploy token → stores in Vault for registry pulls
    ↓
Developer creates repo in GitLab devhub group with k8s/ manifests
    → ArgoCD auto-discovers repo via gitlab-appset.yaml
    → Deploys to workload cluster namespace devhub-<repo-name>
    → ExternalSecret pulls registry-pull-secret from Vault for image pulls
```

### Cloud-Specific Managed Services

| Cloud   | K8s  | PostgreSQL                | Cache           | Object Storage |
|---------|------|---------------------------|-----------------|----------------|
| UpCloud | UCS  | Managed PG                | Valkey          | S3-compatible  |
| Azure   | AKS  | PostgreSQL Flexible Server| Azure Cache for Redis | Azure Blob |
| GCP     | GKE  | Cloud SQL                 | Memorystore     | GCS            |
| AWS     | EKS  | RDS                       | ElastiCache     | S3             |

### Keyless Storage Access

GitLab is granted access to object storage without static credentials:
- **Azure**: Workload Identity — `azurerm_user_assigned_identity` + federated credential; annotate K8s SA `gitlab` in namespace `gitlab`
- **GCP**: Workload Identity — `google_service_account` + IAM binding to K8s SA; annotate K8s SA `gitlab`
- **AWS**: IRSA — IAM role + OIDC trust policy + K8s SA annotation (`eks.amazonaws.com/role-arn`)

### Keycloak IdP Federation (managed clouds)

Keycloak remains the universal OIDC broker for all downstream apps. Per-cloud upstream IdPs:
- **Azure**: Entra ID via OIDC; App Roles → Keycloak groups via `oidc-group-idp-mapper`
- **GCP**: Google social provider (built-in); no auto group mapping — assign groups manually
- **AWS**: Cognito via OIDC; `cognito:groups` claim → Keycloak groups via `oidc-group-idp-mapper`

### Configuration Flow

1. `k8s/overlays/{env}/config.yaml` — single source of truth for domain, TLS, and data service settings
2. `deploy.sh` reads config.yaml via `lib/common.sh`, exports env vars
3. `envsubst` templates Helm values with an explicit allow-list to avoid breaking ArgoCD's `$oidc.keycloak.clientSecret`:
   ```
   ${DOMAIN} ${TLS_SECRET_NAME} ${CLUSTER_ISSUER} ${ACME_EMAIL}
   ${PG_HOST} ${VALKEY_HOST} ${REDIS_HOST}
   ${S3_ENDPOINT} ${S3_REGION} ${S3_BUCKET_PREFIX}
   ${AZURE_STORAGE_ACCOUNT} ${GITLAB_IDENTITY_CLIENT_ID} ${EXTERNAL_DNS_IDENTITY_CLIENT_ID}
   ${GCS_PROJECT_ID} ${GCS_BUCKET_PREFIX} ${GITLAB_GSA_EMAIL} ${EXTERNAL_DNS_GSA_EMAIL}
   ${AWS_REGION} ${GITLAB_IRSA_ROLE_ARN} ${EXTERNAL_DNS_IRSA_ROLE_ARN}
   ```
4. `helm upgrade --install` applies templated values

### Directory Layout

```
devhub/
├── tofu/
│   ├── upcloud/                     # UpCloud infrastructure
│   │   ├── modules/cluster/         #   Shared module: UCS + data services
│   │   ├── dev/                     #   Dev root module
│   │   ├── prod/                    #   Prod root module
│   │   └── workload/                #   Workload cluster (no data services)
│   ├── azure/                       # Azure infrastructure
│   │   ├── modules/cluster/         #   Shared module: AKS + data services
│   │   ├── dev/                     #   Dev root module
│   │   ├── prod/                    #   Prod root module
│   │   └── workload/                #   Workload cluster (no data services)
│   ├── gcp/                         # GCP infrastructure
│   │   ├── modules/cluster/         #   Shared module: GKE + data services
│   │   ├── dev/                     #   Dev root module
│   │   ├── prod/                    #   Prod root module
│   │   └── workload/                #   Workload cluster (no data services)
│   ├── aws/                         # AWS infrastructure
│   │   ├── modules/cluster/         #   Shared module: EKS + data services
│   │   ├── dev/                     #   Dev root module
│   │   ├── prod/                    #   Prod root module
│   │   └── workload/                #   Workload cluster (no data services)
│   └── scripts/                     # Shared tofu helpers (setup-cluster.sh, upcloud-login.sh)
├── k8s/
│   ├── base/devops/                 #   Base Helm values for each service
│   ├── overlays/
│   │   ├── local/                   #   Local dev (Rancher Desktop)
│   │   ├── upcloud/devops/          #   Shared UpCloud Helm overrides
│   │   ├── upcloud-dev/             #   UpCloud dev (config.yaml + devops symlink)
│   │   ├── upcloud-prod/            #   UpCloud prod (config.yaml + devops symlink)
│   │   ├── upcloud-workload/        #   UpCloud workload cluster (config.yaml only)
│   │   ├── azure/devops/            #   Shared Azure Helm overrides
│   │   ├── azure-dev/               #   Azure dev (config.yaml + devops symlink)
│   │   ├── azure-prod/              #   Azure prod (config.yaml + devops symlink)
│   │   ├── azure-workload/          #   Azure workload cluster (config.yaml only)
│   │   ├── gcp/devops/              #   Shared GCP Helm overrides
│   │   ├── gcp-dev/                 #   GCP dev (config.yaml + devops symlink)
│   │   ├── gcp-prod/                #   GCP prod (config.yaml + devops symlink)
│   │   ├── gcp-workload/            #   GCP workload cluster (config.yaml only)
│   │   ├── aws/devops/              #   Shared AWS Helm overrides
│   │   ├── aws-dev/                 #   AWS dev (config.yaml + devops symlink)
│   │   ├── aws-prod/                #   AWS prod (config.yaml + devops symlink)
│   │   └── aws-workload/            #   AWS workload cluster (config.yaml only)
│   ├── argocd/                      #   App-of-apps GitOps manifests
│   ├── scripts/                     #   Deployment and setup scripts
│   │   ├── lib/common.sh            #     Shared library
│   │   ├── sync-tofu-outputs.sh     #     Bridge: tofu outputs → k8s config (platform + workload)
│   │   ├── deploy.sh                #     Platform cluster deployment
│   │   ├── deploy-workload.sh       #     Workload cluster deployment
│   │   ├── register-workload-cluster.sh #  Register workload cluster with platform ArgoCD
│   │   ├── setup-*.sh               #     Setup scripts (CA, cluster, Keycloak, Vault)
│   │   └── windows/                 #     PowerShell scripts for Windows host
│   ├── templates/app-template/      #   Template for developer applications
│   │   └── k8s/                    #     K8s manifests (deployment, service, ingress, registry-pull-secret)
│   ├── certs/                       #   Generated certs (gitignored)
│   └── docs/                        #   Detailed guides (see below)
```

### Ingress

Uses **nginx-ingress** controller (not Traefik). All ingresses use `ingressClassName: nginx`. Ingress rules are in `k8s/overlays/{cloud,local}/devops/ingress.yaml`.

### Services and Namespaces

| Namespace          | Service                          |
|--------------------|----------------------------------|
| `cert-manager`     | cert-manager (Let's Encrypt TLS) |
| `external-dns`     | External-DNS                     |
| `keycloak`         | Keycloak                         |
| `vault`            | Vault                            |
| `gitlab`           | GitLab                           |
| `argocd`           | ArgoCD                           |
| `monitoring`       | Prometheus, Grafana, Loki, Tempo |
| `external-secrets` | External Secrets Operator        |
| `data-services`    | PostgreSQL, Valkey, MinIO (local)|
| `crossplane-system`| Crossplane                       |
| `ingress-nginx`    | nginx-ingress controller         |
| `devhub`           | Application workloads (local only) |

**Workload cluster namespaces** (deployed by deploy-workload.sh):

| Namespace          | Service                          |
|--------------------|----------------------------------|
| `cert-manager`     | cert-manager (Let's Encrypt TLS) |
| `external-dns`     | External-DNS                     |
| `external-secrets` | External Secrets Operator        |
| `monitoring`       | Grafana Alloy (log forwarding)   |
| `ingress-nginx`    | nginx-ingress controller         |
| `devhub-<app>`     | One namespace per developer app  |

The local TLS secret (`local-tls-secret`) is copied into every service namespace by deploy.sh.

### Data Services

- **Local**: StatefulSets for PostgreSQL, Valkey, and MinIO in `data-services` namespace
- **UpCloud**: Managed PostgreSQL + Valkey + S3-compatible Object Storage on private SDN
- **Azure**: PostgreSQL Flexible Server + Azure Cache for Redis + Azure Blob Storage
- **GCP**: Cloud SQL + Memorystore (Redis) + Google Cloud Storage
- **AWS**: RDS + ElastiCache (Redis) + S3

### Keycloak SSO

- Realm: `devops` with groups: `devops-admins`, `developers`, `viewers`
- OIDC clients: `grafana`, `argocd`, `gitlab`, `vault`
- Each client needs a custom "groups" client scope with `oidc-group-membership-mapper`
- setup-keycloak.sh uses `kcadm.sh` via `kubectl exec` — avoid `!` `@` `$` chars in passwords (shell escaping issues)

### .localhost DNS Gotcha

glibc >= 2.25 resolves `*.localhost` to 127.0.0.1 (RFC 6761) before querying DNS. This means glibc-based containers (GitLab, Grafana) cannot reach `keycloak.localhost` via DNS. Fix: use internal K8s service URLs for server-side OIDC endpoints (`http://keycloak-keycloakx-http.keycloak.svc.cluster.local`), keep external URLs (`https://keycloak.localhost`) only for browser-facing redirects.

### Deployment Order

deploy.sh installs services in dependency order:

```
nginx-ingress → namespaces → TLS secrets (local only) → cert-manager → external-dns
    → data-services → monitoring → keycloak → vault → external-secrets
    → gitlab → argocd → crossplane → ingress rules
```

## Documentation

Detailed step-by-step guides in `k8s/docs/`:

| File                   | Contents                                          |
|------------------------|---------------------------------------------------|
| `LOCAL_SETUP.md`       | Local dev with Rancher Desktop / WSL2             |
| `UPCLOUD_SETUP.md`     | UpCloud (UCS) deployment walkthrough              |
| `AZURE_SETUP.md`       | Azure (AKS) deployment walkthrough                |
| `GCP_SETUP.md`         | GCP (GKE) deployment walkthrough                  |
| `AWS_SETUP.md`         | AWS (EKS) deployment walkthrough                  |
| `KEYCLOAK_SSO.md`      | Keycloak realm/client/IdP federation setup        |
| `SSO_TESTING_GUIDE.md` | End-to-end SSO testing across all OIDC clients    |
| `crossplane-appsets.md`| Crossplane ApplicationSets and provider config    |

### Developer Application Workflow

Developers create apps that are automatically deployed to the workload cluster:

1. **Create a repo** in the `devhub` GitLab group (copy from `k8s/templates/app-template/`)
2. **Replace `APP_NAME` and `DOMAIN`** in `k8s/` manifests with the app name and domain
3. **Push code** — CI builds, tags, and pushes the image to `registry.DOMAIN/devhub/<app>`
4. **ArgoCD auto-discovers** the repo via `gitlab-appset.yaml` (SCM provider scanning devhub group)
5. **App deploys** to namespace `devhub-<repo-name>` on the workload cluster
6. **Image pull** works because `registry-pull-secret.yaml` ExternalSecret pulls credentials from Vault

App template provides:
- `k8s/deployment.yaml` — uses `registry.DOMAIN/devhub/APP_NAME:latest`, `imagePullSecrets: registry-pull-secret`
- `k8s/service.yaml` — ClusterIP on port 80
- `k8s/ingress.yaml` — cert-manager TLS, nginx ingress, `APP_NAME.DOMAIN`
- `k8s/registry-pull-secret.yaml` — ExternalSecret pulling deploy token from Vault path `secret/gitlab/registry-pull-token`
- `.gitlab-ci.yml` — lint → build → test → deploy (updates image tag in deployment.yaml for ArgoCD)

**Registry URL**: `registry.DOMAIN` (nginx ingress in front of GitLab registry, standard HTTPS port)

## Key Conventions

- Bash scripts use `set -euo pipefail` with colored logging (`[INFO]`, `[WARN]`, `[ERROR]`, `[STEP]`)
- Config parsing uses `grep`/`sed` (no yq dependency required)
- Helm values are split: base values in `k8s/base/devops/{service}/values.yaml`, overlay overrides in `k8s/overlays/{env}/devops/{service}/values.yaml`
- Cloud overlay envs (`upcloud-dev/prod`, `azure-dev/prod`, etc.) symlink `devops/` from their shared cloud overlay — shared Helm values, separate `config.yaml`
- Sensitive secrets (IdP client secrets, Redis auth strings) go in gitignored env files under `k8s/scripts/{env}/` (e.g. `gcp-idp.env`, `aws-idp.env`)
- Non-sensitive config (tenant IDs, client IDs, hostnames, bucket names) goes in `config.yaml`
- ArgoCD apps follow the app-of-apps pattern: add a YAML file to `k8s/argocd/apps/` and ArgoCD auto-discovers it
- OpenTofu uses the module pattern: shared module in `tofu/{cloud}/modules/cluster/`, env-specific root modules in `dev/` and `prod/`
- YAML files must not have duplicate keys (silent override behavior)
- Grafana requires `initChownData: enabled: false` for local k3s/Rancher Desktop
- GCP OAuth client must be created manually in Google Cloud Console (no Terraform resource exists)
- AWS Cognito domain prefix must be globally unique across all AWS accounts
- GCS and S3 bucket names must be globally unique; prefix with project/account to avoid conflicts
- Cloud SQL / RDS: DB users must be created post-apply via psql (no Terraform resource for local users)
