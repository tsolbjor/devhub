# Local Development Scripts

This directory contains scripts for setting up and managing the local Kubernetes DevOps platform.

## Quick Start

**To get everything running with zero manual steps, run:**

```bash
cd k8s/scripts/local
./setup-all.sh
```

This takes 20-40 minutes and fully deploys the entire DevOps platform including Keycloak, Vault, GitLab, ArgoCD, and monitoring.

## Prerequisites

- **Rancher Desktop** (or similar local K8s) with Kubernetes running
- Required CLI tools: `kubectl`, `helm`, `openssl`, `jq`, `envsubst`, `curl`

## Scripts Reference

| Script | Description |
|--------|-------------|
| `setup-all.sh` | Master script that runs all setup steps automatically |
| `deploy.sh` | Deploy/manage individual services or the entire platform |
| `setup-ca.sh` | Generate local CA and TLS certificates |
| `setup-cluster.sh` | Configure nginx-ingress and cluster resources |
| `setup-keycloak.sh` | Configure Keycloak realm, groups, and OIDC clients |
| `setup-vault.sh` | Initialize and unseal Vault |

### setup-all.sh

Fully automated setup that orchestrates all other scripts:

1. Generates CA and TLS certificates
2. Sets up nginx-ingress controller
3. Deploys all DevOps components
4. Waits for Vault, initializes, unseals, and configures it
5. Waits for Keycloak and configures realm/clients
6. Waits for GitLab to be fully ready
7. Bootstraps ArgoCD app-of-apps

```bash
./setup-all.sh                  # Full setup
./setup-all.sh --skip-post-config  # Skip Vault/Keycloak configuration
```

### deploy.sh

Deploy, check status, or delete platform components:

```bash
./deploy.sh local              # Deploy everything
./deploy.sh local keycloak     # Deploy only Keycloak
./deploy.sh local argocd       # Deploy only ArgoCD
./deploy.sh local monitoring   # Deploy only monitoring stack
./deploy.sh local vault        # Deploy only Vault
./deploy.sh local gitlab       # Deploy only GitLab

./deploy.sh local all status   # Check status of all services
./deploy.sh local all delete   # Delete everything

./deploy.sh local bootstrap    # Bootstrap ArgoCD app-of-apps
```

### setup-ca.sh

Generates a local Certificate Authority and TLS certificates for all services:

- Creates CA valid for 10 years
- Generates certificates for `*.localhost` domains
- Certificates stored in `k8s/certs/`

```bash
./setup-ca.sh
```

### setup-cluster.sh

Configures the local Kubernetes cluster:

- Installs nginx-ingress controller
- Creates required namespaces
- Distributes TLS secrets to all namespaces

```bash
./setup-cluster.sh
```

### setup-keycloak.sh

Configures Keycloak for SSO:

- Creates `devops` realm
- Sets up groups: `devops-admins`, `developers`, `viewers`
- Creates OIDC clients: `grafana`, `argocd`, `gitlab`, `vault`

```bash
./setup-keycloak.sh
```

### setup-vault.sh

Initializes and configures HashiCorp Vault:

- Initializes Vault with 5 key shares and 3 threshold
- Unseals Vault automatically
- Enables secrets engines

Keys are saved to `vault-init-keys.json` (gitignored).

```bash
./setup-vault.sh
```

## Other Files

| File | Description |
|------|-------------|
| `oidc-secrets.env` | OIDC client secrets for service configuration |
| `vault-init-keys.json` | Vault unseal keys (auto-generated, gitignored) |

## Service URLs (after setup)

| Service | URL |
|---------|-----|
| Keycloak | https://keycloak.localhost |
| Vault | https://vault.localhost |
| GitLab | https://gitlab.localhost |
| ArgoCD | https://argocd.localhost |
| Grafana | https://grafana.localhost |
| Prometheus | https://prometheus.localhost |

## Troubleshooting

Check service status:
```bash
./deploy.sh local all status
```

View pod logs:
```bash
kubectl logs -n <namespace> <pod-name>
```

For detailed setup information, see:
- [LOCAL_SETUP.md](../../docs/LOCAL_SETUP.md)
- [KEYCLOAK_SSO.md](../../docs/KEYCLOAK_SSO.md)
- [SSO_TESTING_GUIDE.md](../../docs/SSO_TESTING_GUIDE.md)
