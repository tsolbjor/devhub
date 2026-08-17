# Kubernetes Platform

Deploys the DevOps platform services onto Kubernetes clusters. Supports local development and managed cloud clusters (UpCloud, Azure, GCP, AWS).

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
│       ├── forgejo/values.yaml
│       ├── keycloak/values.yaml
│       ├── monitoring/
│       ├── namespaces/
│       └── vault/values.yaml
├── overlays/
│   ├── local/                       # Local: Rancher Desktop / WSL2
│   │   ├── config.yaml              #   Domain, TLS, data services config
│   │   ├── data-services/           #   StatefulSets for PG, Valkey, MinIO
│   │   └── devops/                  #   Helm value overrides + gateway.yaml/httproutes.yaml
│   ├── upcloud/
│   │   └── devops/                  #   Shared UpCloud Helm value overrides
│   ├── upcloud-dev/                 # UpCloud dev environment
│   │   ├── config.yaml              #   Domain + managed data service endpoints
│   │   └── devops -> ../upcloud/devops
│   └── upcloud-prod/                # UpCloud prod environment
│       ├── config.yaml
│       └── devops -> ../upcloud/devops
│   ├── azure/, azure-dev/, azure-prod/
│   │                                 # Azure shared + env-specific overlays
│   ├── gcp/, gcp-dev/, gcp-prod/     # GCP shared + env-specific overlays
│   └── aws/, aws-dev/, aws-prod/     # AWS shared + env-specific overlays
├── scripts/
│   ├── lib/common.sh                # Shared library (logging, config, templating)
│   ├── deploy.sh                    # Main deployment script
│   ├── sync-tofu-outputs.sh         # Bridge: tofu outputs → scripts/<env>/*.env
│   ├── setup-all.sh                 # Full local automated setup
│   ├── setup-ca.sh                  # Generate local CA and TLS certs
│   ├── setup-cluster.sh             # cluster prerequisites and checks
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

# Bridge tofu → k8s: writes scripts/upcloud-dev/{tofu-outputs,secrets}.env + kubeconfig
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
./deploy.sh --env <environment> [component] [action]
```

Supported environments:
`local`, `upcloud-dev`, `upcloud-prod`, `azure-dev`, `azure-prod`, `gcp-dev`, `gcp-prod`, `aws-dev`, `aws-prod`

Workload clusters use `deploy-workload.sh` with `{upcloud,azure,gcp,aws}-workload`.

**Components:**
- `all` / `devops` — Deploy entire platform (default)
- `keycloak`, `vault`, `monitoring`, `forgejo`, `woodpecker`, `gateway`, `kyverno`, `reloader`, `argocd` — Individual services
- `data-services` — Data services only (local: StatefulSets, managed envs: external service wiring)
- `velero`, `external-dns`, `external-secrets`, `headlamp`, `cluster-autoscaler` — Individual services
- `storage` — Default StorageClass (EKS: gp3 via the EBS CSI driver)
- `policies` — Priority classes, NetworkPolicies, PodDisruptionBudgets
- `db-users` — Create managed-PostgreSQL users (once per new database)
- `loki-auth` — (Re)generate Loki ingest credentials + publish the push endpoint
- `platform-secrets` — Move platform credentials into Vault + ExternalSecrets
- `bootstrap` — Deploy ArgoCD app-of-apps
- `gitops` — Hand the platform components over to ArgoCD
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

Two files per environment, one owner each. Infrastructure values are **not** kept
in `config.yaml` — `sync-tofu-outputs.sh` writes them to generated, gitignored
files, so `tofu apply` never produces a git diff.

`overlays/<env>/config.yaml` (human-owned, committed):

```yaml
domain: dev.example.com
tls:
  type: cert-manager       # or local-ca
  secretName: ""
  clusterIssuer: letsencrypt-prod
acmeEmail: admin@example.com

dataServices:
  type: managed            # "local" for in-cluster StatefulSets

gitops:
  repoUrl: https://git.dev.example.com/devhub/devhub.git
  targetRevision: HEAD
```

`scripts/<env>/tofu-outputs.env` + `secrets.env` (generated, mode 600):

```sh
PG_HOST=devhub-dev-postgresql.xxx.rds.amazonaws.com
REDIS_HOST=... REDIS_TLS_ENABLED=true
LOKI_BUCKET=devhub-dev-loki   LOKI_IRSA_ROLE_ARN=arn:aws:iam::...
VAULT_KMS_KEY_ID=...          VELERO_BUCKET=devhub-dev-velero
```

Helm values use `${DOMAIN}`, `${PG_HOST}`, `${LOKI_BUCKET}` and friends as
placeholders, templated by `deploy.sh` via `envsubst` with an explicit allow-list
(`TEMPLATE_VARS` in `scripts/lib/common.sh`). Adding a new placeholder without
adding it to that list makes `scripts/validate-overlays.sh` fail — which is what
CI runs on every push.

## Services

| Service | URL Pattern | Namespace |
|---------|-------------|-----------|
| Keycloak | `https://keycloak.{domain}` | `keycloak` |
| Vault | `https://vault.{domain}` | `vault` |
| Forgejo (git + registry) | `https://git.{domain}` | `forgejo` |
| Woodpecker CI | `https://ci.{domain}` | `woodpecker` |
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

# Forgejo admin
kubectl get secret forgejo-admin-secret -n forgejo -o jsonpath='{.data.password}' | base64 -d
```

## Troubleshooting

```bash
# Pod issues
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>

# Ingress issues
kubectl get ingress -A
kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=envoy-gateway

# ArgoCD sync issues
argocd app list
argocd app get <app-name>
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

## See Also

- [docs/LOCAL_SETUP.md](docs/LOCAL_SETUP.md) — Detailed local setup guide
- [docs/UPCLOUD_SETUP.md](docs/UPCLOUD_SETUP.md) — UpCloud deployment guide
- [docs/KEYCLOAK_SSO.md](docs/KEYCLOAK_SSO.md) — Keycloak SSO configuration
- [docs/OPERATIONS.md](docs/OPERATIONS.md) — Day two: state, secrets, backups/restore, GitOps, access, alerting
- [argocd/README.md](argocd/README.md) — ArgoCD app-of-apps patterns

## Entry point

Start with `./devhub quickstart` (guided, resumable). It calls the same scripts
documented here.

These scripts are usually invoked through `./devhub` at the repository root,
which maps environments to tofu modules and routes platform vs workload
deployments. They remain fully usable on their own:

```bash
./devhub deploy --env local keycloak     # equivalent to:
k8s/scripts/deploy.sh --env local keycloak
```
