# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kubernetes DevOps platform with two layers:
1. **Infrastructure (OpenTofu)** — provisions K8s clusters and managed data services on UpCloud, Azure, GCP, or AWS
2. **Platform (Helm/K8s)** — deploys DevOps services (Keycloak, Vault, GitLab, ArgoCD, Prometheus/Grafana/Loki/Tempo)

Environments: `local` (Rancher Desktop/WSL2), `upcloud-dev`, `upcloud-prod`, `azure-dev`, `azure-prod`, `gcp-dev`, `gcp-prod`, `aws-dev`, `aws-prod`.

## Common Commands

### OpenTofu (infrastructure)

```bash
# Provision dev infrastructure
cd tofu/upcloud/dev && tofu init && tofu plan && tofu apply

# Provision prod infrastructure
cd tofu/upcloud/prod && tofu init && tofu plan && tofu apply
```

### K8s Scripts (platform services)

All scripts are in `k8s/scripts/`. Run from that directory. All scripts require `--env local|upcloud-dev|upcloud-prod`.

```bash
# Full local automated setup (20-40 min, zero manual steps)
./setup-all.sh --env local

# Sync tofu outputs into k8s overlay config + fetch kubeconfig
./sync-tofu-outputs.sh --env upcloud-dev

# Deploy entire platform (or redeploy after changes)
./deploy.sh --env local
./deploy.sh --env upcloud-dev

# Deploy a single service
./deploy.sh --env local keycloak
./deploy.sh --env local argocd
./deploy.sh --env local monitoring
./deploy.sh --env local vault
./deploy.sh --env local gitlab

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

## Architecture

### UpCloud Deployment Workflow

```
tofu apply (dev/ or prod/)
    → provisions: K8s cluster, private network, PostgreSQL, Valkey, Object Storage
    ↓
sync-tofu-outputs.sh --env upcloud-dev
    → writes PG_HOST, VALKEY_HOST, S3_ENDPOINT into k8s overlay config.yaml
    → fetches kubeconfig via upctl
    ↓
deploy.sh --env upcloud-dev
    → reads config.yaml, templates Helm values, deploys services
```

### Configuration Flow

1. `k8s/overlays/{env}/config.yaml` — single source of truth for domain, TLS, and data services settings
2. `deploy.sh` reads config.yaml via `lib/common.sh`, exports env vars
3. `envsubst` templates Helm values files with **only** `${DOMAIN} ${TLS_SECRET_NAME} ${CLUSTER_ISSUER} ${ACME_EMAIL} ${PG_HOST} ${VALKEY_HOST} ${S3_ENDPOINT} ${S3_REGION}` — this restriction is intentional to avoid breaking ArgoCD's `$oidc.keycloak.clientSecret` variable
4. `helm upgrade --install` applies templated values

### Directory Layout

```
devhub/
├── tofu/upcloud/                    # Infrastructure as Code (OpenTofu)
│   ├── modules/cluster/             #   Shared module: K8s + data services
│   ├── dev/                         #   Dev environment root module
│   └── prod/                        #   Prod environment root module
├── k8s/
│   ├── base/devops/                 #   Base Helm values for each service
│   ├── overlays/
│   │   ├── local/                   #   Local dev (Rancher Desktop)
│   │   ├── upcloud/devops/          #   Shared UpCloud Helm overrides
│   │   ├── upcloud-dev/             #   UpCloud dev (config.yaml + devops symlink)
│   │   └── upcloud-prod/            #   UpCloud prod (config.yaml + devops symlink)
│   ├── argocd/                      #   App-of-apps GitOps manifests
│   ├── scripts/                     #   Deployment and setup scripts
│   │   ├── lib/common.sh            #     Shared library
│   │   ├── sync-tofu-outputs.sh     #     Bridge: tofu outputs → k8s config
│   │   ├── deploy.sh                #     Main deployment script
│   │   ├── setup-*.sh               #     Setup scripts (CA, cluster, Keycloak, Vault)
│   │   └── windows/                 #     PowerShell scripts for Windows host
│   ├── certs/                       #   Generated certs (gitignored)
│   └── docs/                        #   Detailed guides
```

### Ingress

Uses **nginx-ingress** controller (not Traefik). All ingresses use `ingressClassName: nginx`. Ingress rules are in `k8s/overlays/{upcloud,local}/devops/ingress.yaml`.

### Services and Namespaces

Each service gets its own namespace: `keycloak`, `vault`, `gitlab`, `argocd`, `monitoring`, `external-secrets`. Application workloads go in `devhub` namespace.

The local TLS secret (`local-tls-secret`) is copied into every service namespace by deploy.sh.

### Data Services

- **Local**: StatefulSets for PostgreSQL, Valkey, and MinIO deployed in `data-services` namespace
- **UpCloud**: Managed services provisioned by OpenTofu (PostgreSQL, Valkey, Object Storage) on private SDN network

### Keycloak SSO

- Realm: `devops` with groups: `devops-admins`, `developers`, `viewers`
- OIDC clients: `grafana`, `argocd`, `gitlab`, `vault`
- Each client needs a custom "groups" client scope with `oidc-group-membership-mapper`
- setup-keycloak.sh uses `kcadm.sh` via `kubectl exec` — avoid `!` `@` `$` chars in passwords (shell escaping issues)

### .localhost DNS Gotcha

glibc >= 2.25 resolves `*.localhost` to 127.0.0.1 (RFC 6761) before querying DNS. This means glibc-based containers (GitLab, Grafana) cannot reach `keycloak.localhost` via DNS. Fix: use internal K8s service URLs for server-side OIDC endpoints (`http://keycloak-keycloakx-http.keycloak.svc.cluster.local`), keep external URLs (`https://keycloak.localhost`) only for browser-facing redirects.

### Deployment Order

deploy.sh installs services in dependency order: namespaces → TLS secrets → monitoring → Keycloak → Vault → External Secrets → GitLab → ArgoCD → ingress rules.

## Key Conventions

- Bash scripts use `set -euo pipefail` with colored logging (`[INFO]`, `[WARN]`, `[ERROR]`, `[STEP]`)
- Config parsing uses `grep`/`sed` (no yq dependency required)
- Helm values are split: base values in `k8s/base/devops/{service}/values.yaml`, overlay overrides in `k8s/overlays/{env}/devops/{service}/values.yaml`
- UpCloud overlay envs (`upcloud-dev`, `upcloud-prod`) symlink `devops/` from `upcloud/devops/` — shared Helm values, separate config.yaml
- ArgoCD apps follow the app-of-apps pattern: add a YAML file to `k8s/argocd/apps/` and ArgoCD auto-discovers it
- OpenTofu uses module pattern: shared module in `tofu/upcloud/modules/cluster/`, env-specific root modules in `dev/` and `prod/`
- YAML files must not have duplicate keys (silent override behavior)
- Grafana requires `initChownData: enabled: false` for local k3s/Rancher Desktop
