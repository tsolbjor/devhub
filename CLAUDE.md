# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kubernetes DevOps platform deployed on Rancher Desktop (WSL2) for local development and UpCloud for production. The platform provides identity management (Keycloak), secrets management (Vault), source control (GitLab), GitOps (ArgoCD), and monitoring (Prometheus/Grafana/Loki/Tempo).

## Common Commands

All scripts are in `k8s/scripts/local/`. Run from that directory.

```bash
# Full automated setup (20-40 min, zero manual steps)
./setup-all.sh

# Deploy entire platform (or redeploy after changes)
./deploy.sh local

# Deploy a single service
./deploy.sh local keycloak
./deploy.sh local argocd
./deploy.sh local monitoring
./deploy.sh local vault
./deploy.sh local gitlab

# Check status
./deploy.sh local all status

# Delete everything
./deploy.sh local all delete

# Bootstrap ArgoCD app-of-apps
./deploy.sh local bootstrap

# Generate local CA and TLS certs
./setup-ca.sh

# Set up nginx-ingress and cluster resources
./setup-cluster.sh

# Configure Keycloak realm, groups, and OIDC clients
./setup-keycloak.sh

# Initialize and unseal Vault
./setup-vault.sh
```

## Architecture

### Configuration Flow

1. `k8s/overlays/{local,upcloud}/config.yaml` — single source of truth for domain and TLS settings
2. `deploy.sh` reads config.yaml, exports env vars
3. `envsubst` templates Helm values files with **only** `${DOMAIN} ${TLS_SECRET_NAME} ${CLUSTER_ISSUER} ${ACME_EMAIL}` — this restriction is intentional to avoid breaking ArgoCD's `$oidc.keycloak.clientSecret` variable
4. `helm upgrade --install` applies templated values

### Directory Layout

- `k8s/base/devops/` — base Helm values for each service
- `k8s/overlays/{local,upcloud}/devops/` — environment-specific Helm value overrides and ingress definitions
- `k8s/argocd/apps/` — ArgoCD Application manifests (app-of-apps pattern auto-syncs everything here)
- `k8s/argocd/projects/` — ArgoCD project RBAC definitions
- `k8s/scripts/local/` — deployment and setup automation scripts
- `k8s/scripts/windows/` — PowerShell scripts for Windows host CA install and hosts file setup
- `k8s/certs/` — generated CA and domain certs (gitignored)
- `k8s/docs/` — detailed guides (LOCAL_SETUP.md, UPCLOUD_SETUP.md, KEYCLOAK_SSO.md, SSO_TESTING_GUIDE.md)

### Ingress

Uses **nginx-ingress** controller (not Traefik). All ingresses use `ingressClassName: nginx`. Ingress rules for all services are defined in a single file: `k8s/overlays/local/devops/ingress.yaml`.

### Services and Namespaces

Each service gets its own namespace: `keycloak`, `vault`, `gitlab`, `argocd`, `monitoring`, `external-secrets`. Application workloads go in `tshub` namespace.

The local TLS secret (`local-tls-secret`) is copied into every service namespace by deploy.sh.

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
- ArgoCD apps follow the app-of-apps pattern: add a YAML file to `k8s/argocd/apps/` and ArgoCD auto-discovers it
- YAML files must not have duplicate keys (silent override behavior)
- Grafana requires `initChownData: enabled: false` for local k3s/Rancher Desktop
