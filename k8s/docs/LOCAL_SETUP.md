# Local Development Setup (Windows + WSL)

This guide sets up trusted HTTPS for local Kubernetes development on Windows with WSL2.

## Prerequisites

- Windows 10/11
- WSL2 (Ubuntu or similar)
- Rancher Desktop (or another local Kubernetes distribution)
- `kubectl`, `helm`, `openssl`, `jq`, `envsubst` in WSL

## Quick Start (Automated)

```bash
cd k8s/scripts
./setup-all.sh --env local
```

This command:
1. Generates local CA and wildcard localhost certs
2. Installs ingress-nginx and cluster prerequisites
3. Deploys platform services
4. Initializes and configures Vault
5. Configures Keycloak realm and OIDC clients
6. Bootstraps ArgoCD app-of-apps

## Manual Setup (Step by Step)

### 1. Generate certificates (WSL)

```bash
cd k8s/scripts
./setup-ca.sh --env local
```

### 2. Trust CA + hosts entries on Windows (PowerShell as Administrator)

```powershell
cd k8s\scripts\windows
.\setup-all.ps1
```

Or run separately:

```powershell
.\install-ca.ps1
.\setup-hosts.ps1
```

### 3. Install ingress and cluster resources (WSL)

```bash
cd k8s/scripts
./setup-cluster.sh --env local
```

### 4. Deploy platform services (WSL)

```bash
cd k8s/scripts
./deploy.sh --env local
```

### 5. Configure Keycloak and Vault (WSL)

```bash
cd k8s/scripts
./setup-keycloak.sh --env local all
./setup-vault.sh --env local all
./deploy.sh --env local bootstrap
```

## Access URLs

- https://keycloak.localhost
- https://vault.localhost
- https://gitlab.localhost
- https://argocd.localhost
- https://grafana.localhost

## Credentials

```bash
# Keycloak admin
kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d

# Grafana admin
kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

# ArgoCD admin
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# GitLab root
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d
```

Keycloak-generated OIDC secrets are written to `k8s/scripts/local/oidc-secrets.env`.

## Troubleshooting

### Certificates not trusted

1. Re-run `install-ca.ps1` as Administrator.
2. Restart browser.
3. Verify in `certmgr.msc` under Trusted Root Certification Authorities.

### Domain not resolving

1. Check `C:\Windows\System32\drivers\etc\hosts`.
2. Run `ipconfig /flushdns`.

### Ingress issues

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
kubectl get ingress -A
```

### Service communication over HTTPS fails

Ensure `local-ca-certificates` ConfigMap is mounted and app CA env var is set (`SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, etc.).

## Add More Local Domains

1. Edit [setup-ca.sh](../scripts/setup-ca.sh) and add entries to `DOMAINS`.
2. Re-run `./setup-ca.sh --env local`.
3. Re-run `k8s/scripts/windows/setup-hosts.ps1`.
4. Update ingress manifests in [overlays/local/devops/ingress.yaml](../overlays/local/devops/ingress.yaml) or app ingress manifests.

## Firefox

Firefox uses its own certificate store. Import `k8s/certs/ca/ca.crt` into Firefox Authorities and trust it for websites.
