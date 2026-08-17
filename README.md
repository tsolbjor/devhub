# devhub

Kubernetes DevOps platform for local development and cloud environments. Three layers:
**OpenTofu** provisions cloud infrastructure, **scripts** bootstrap the platform,
and **ArgoCD** owns everything after bootstrap — including developer apps running
on separate workload clusters.

## Platform Services

| Service | Purpose |
|---------|---------|
| **Keycloak** | Identity management and SSO (OIDC) |
| **Vault** | Secrets management |
| **Forgejo** | Git hosting, issues, project boards, packages and container registry |
| **Woodpecker CI** | Pipelines; each step an unprivileged pod |
| **ArgoCD** | GitOps continuous deployment |
| **Prometheus** | Metrics collection and alerting |
| **Grafana** | Dashboards and observability |
| **Loki** | Log aggregation (multi-tenant; workload clusters ship logs here) |
| **Tempo** | Distributed tracing |
| **Envoy Gateway** | Gateway API ingress (replaces ingress-nginx) |
| **Kyverno** | Admission policy and per-namespace guardrail generation |
| **Reloader** | Restarts workloads when their secrets rotate |
| **Velero** | Cluster object and volume backups |
| **Headlamp** | Read-only cluster UI (SSO) |
| **Homepage** | Link portal for the services above (SSO at the gateway) |

## Environments

| Environment | Infrastructure | Data Services | Domain |
|-------------|---------------|---------------|--------|
| `local` | Local Kubernetes (Rancher Desktop or similar) | StatefulSets (PG, Valkey, MinIO) | `*.localhost` |
| `upcloud-dev`, `upcloud-prod` | UpCloud Managed K8s | Managed (PG, Valkey, S3) | configurable |
| `azure-dev`, `azure-prod` | AKS | Managed (PostgreSQL, Redis, Blob) | configurable |
| `gcp-dev`, `gcp-prod` | GKE | Managed (PostgreSQL, Redis, GCS) | configurable |
| `aws-dev`, `aws-prod` | EKS | Managed (PostgreSQL, Redis, S3) | configurable |
| `{cloud}-workload` | Lean cluster for developer apps | none (uses the platform's) | configurable |

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
│   │   ├── aws-dev/, aws-prod/           #   AWS env overlays
│   │   └── {cloud}-workload/              #   Workload cluster overlays
│   ├── argocd/                      #   App-of-apps, ApplicationSets, platform-appset.yaml
│   ├── scripts/                     #   Deployment and setup scripts
│   ├── templates/app-template/      #   Developer app scaffold (rootless CI, hardened manifests)
│   └── docs/                        #   Setup and operations guides
│
├── devhub                           # Entry point: routes to the scripts below
├── .github/workflows/validate.yml   # CI: tofu validate, tflint, checkov, shellcheck, manifests
├── renovate.json                    # Chart/provider/image updates
└── CLAUDE.md                        # AI assistant context
```

## Quick Start

```bash
git clone <this repo> && cd devhub
./devhub quickstart
```

`quickstart` asks which environment you want, shows a checklist of what is done
and what is left, and runs the next step. It is safe to re-run at any point: state
is detected, not remembered, so it always continues from where you actually are —
after a failure, a coffee break, or a week later.

```bash
./devhub quickstart --env local --status                 # checklist, then exit
./devhub quickstart --env local --run-remaining-steps    # run all pending steps
./devhub quickstart --env local --auto                   # same, unattended
```

`--run-remaining-steps` still stops to confirm anything that costs money or can
replace resources (it shows the tofu plan before applying). `--auto` answers those
confirmations for you.

```
  aws-dev  (aws / tofu/aws/dev)

  ✓ Required tooling installed
  ✓ backend.hcl + terraform.tfvars
  ✓ Domain set in config.yaml
  → OpenTofu initialised
  · Infrastructure provisioned
  · Outputs and kubeconfig synced
  ...

  Next: ./devhub init --env aws-dev
```

Everything it does is a plain command you can run yourself:

```bash
./devhub help                  # all commands
./devhub doctor                # is the required tooling installed?
./devhub envs                  # what state is each environment in?
source <(./devhub completion)  # bash completion
```

`./devhub` is a thin dispatcher over `k8s/scripts/` — it knows which tofu module
an environment maps to, which deploy script a platform vs workload cluster needs,
and which kubeconfig belongs where. It adds no behaviour of its own, so
`k8s/scripts/deploy.sh --env local` remains equivalent.

### Local Development

```bash
./devhub quickstart --env local     # guided
./devhub bootstrap  --env local     # or the whole thing in one shot
```

Services available at `https://{service}.localhost` (keycloak, git, ci, argocd, grafana, headlamp, vault)

### Cloud Deployment (any of upcloud / azure / gcp / aws)

```bash
./devhub quickstart --env aws-dev   # guided version of everything below

# or step by step:
./devhub preflight --env aws-dev # external prerequisites (see below)
./devhub setup --env aws-dev     # wizard: asks 4 questions, writes the config
./devhub init  --env aws-dev
./devhub plan  --env aws-dev     # read it — private-cluster changes force replacement
./devhub apply --env aws-dev     # 15-25 min
./devhub bootstrap --env aws-dev # 30-50 min
```

`preflight` is step zero: it states what the platform assumes about the outside
world, checks what it can (CLI authentication, DNS zone, registrar delegation,
quota-relevant tooling), and asks about the rest. The assumptions that matter most:

- a **registered domain you control**, with **DNS hosted in the cloud's DNS service**
  and the registrar's nameservers pointing at it. On AWS and Azure the zone must
  exist *before* `tofu apply` — the modules look it up with a data source, so the
  plan fails without it. UpCloud has no DNS product, so the platform expects a
  Cloudflare zone plus an API token.
- **certificates only issue once DNS resolves publicly**: cert-manager proves
  ownership over HTTP-01. You can provision infrastructure before delegation
  finishes; TLS just stays pending until it completes.
- a cloud account with quota and billing, and an email address for expiry notices.

`setup` then collects the handful of values no automation can infer — your domain, the
ACME contact address, and which CIDRs may reach the Kubernetes API (it offers your
current public IP, specific CIDRs, or no public endpoint at all). From those it
writes `backend.hcl` and `terraform.tfvars`, sets `domain`/`acmeEmail`/`gitops.repoUrl`
in the overlay config, and offers to create the state bucket + lock table — which
tofu cannot create for itself, since it needs them to store state.

Non-interactive for CI:

```bash
./devhub setup --env aws-dev --non-interactive --yes \
    --domain dev.example.org --acme-email ops@example.org \
    --api-cidrs 203.0.113.4/32 --state-bucket acme-tfstate --create-state-store
```

Add `--dry-run` to print the files without writing them.

`bootstrap` does everything after the infrastructure: syncs the tofu outputs and
kubeconfig, creates the managed-PostgreSQL users, deploys the platform,
initialises Vault, configures Keycloak, moves credentials into Vault, and hands
the platform over to ArgoCD. It refuses to start if the infrastructure is missing
or the domain is still a placeholder, and prints the LoadBalancer address to point
DNS at when it finishes.

Every step it performs is also a standalone command (`./devhub sync`, `deploy`,
`vault`, `keycloak`, `secrets`, `gitops`) for reruns and partial recovery.

### Workload Cluster (developer apps)

```bash
./devhub infra init  --env aws-workload
./devhub infra apply --env aws-workload
./devhub sync        --env aws-workload
./devhub deploy      --env aws-workload
./devhub register    --env aws-workload --platform-env aws-dev
```

Registration labels the cluster `devhub.io/role=workload`; the platform
ApplicationSet then deploys every app repo in the Forgejo `devhub` group to it.

## How It Works

### Infrastructure Layer (OpenTofu)

The `tofu/` directory contains provider-specific modules and environment roots for UpCloud, Azure, GCP, and AWS. Managed deployments provision:

- **Kubernetes cluster** (provider-managed)
- **PostgreSQL** for Keycloak and Forgejo
- **Redis/Valkey** for Forgejo caching/session workloads
- **Object storage** for Forgejo artifacts, packages, registry, and backups

Dev and prod environments use separate state and configurable sizing.

Alongside the cluster and data services, each cloud module provisions the platform's
supporting resources: Loki log storage, Velero backup storage, a Vault auto-unseal
KMS key, external-dns and Forgejo identities, and a tainted spot node pool for CI.

### Platform Layer (scripts, bootstrap only)

```
overlays/<env>/config.yaml     human-owned: domain, TLS, data-service type, GitOps repo
k8s/scripts/<env>/*.env        generated by sync-tofu-outputs.sh, gitignored, mode 600
```

`deploy.sh` reads both, templates Helm values with an allow-listed `envsubst`, and
installs the components GitOps cannot install for itself: Envoy Gateway, Keycloak,
Vault, Forgejo, ArgoCD. Nothing rewrites `config.yaml`, so `tofu apply` produces no
git diff.

### GitOps Layer (ArgoCD, everything after bootstrap)

`./deploy.sh --env <env> gitops` applies an ApplicationSet that makes ArgoCD own
cert-manager, external-dns, external-secrets, the monitoring stack, Kyverno,
Reloader, Woodpecker, Headlamp, Homepage and Velero — reconciled from this
repository, with
drift self-healed.

Developer apps are discovered automatically: a matrix of Forgejo repositories in
the `devhub` organisation × clusters labelled `devhub.io/role=workload`.

### Secrets

Vault is the source of truth (`secret/platform/*`), delivered into namespaces by
External Secrets. Unseal keys never live in the cluster and the initial root token
is revoked after setup. Workload clusters authenticate to Vault with JWT auth
against their own OIDC issuer — no static tokens.

## Common Operations

```bash
# Deploy a single service
./devhub deploy --env local keycloak

# Status: pods, Vault seal state, backups, GitOps
./devhub status --env local

# Point your shell at an environment's cluster
eval "$(./devhub kubeconfig --env aws-dev)"

# Static validation — same checks CI runs (no cluster needed)
./devhub validate
./devhub validate --helm local

# Rotate a credential, re-run a Vault action, force an ESO sync
./devhub vault --env aws-dev seed-secrets

# Tear down platform services (leaves infrastructure alone)
./devhub deploy --env local all delete
```

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

## Documentation

- [k8s/docs/CLOUD_CAPABILITIES.md](k8s/docs/CLOUD_CAPABILITIES.md) — What each cloud actually delivers, and the gaps
- [k8s/docs/ADDING_A_CLOUD.md](k8s/docs/ADDING_A_CLOUD.md) — Adding a provider (worked example: Scaleway)
- [k8s/docs/OPERATIONS.md](k8s/docs/OPERATIONS.md) — Day two: state, secrets, backups/restore, GitOps, access, alerting, cost
- [k8s/docs/LOCAL_SETUP.md](k8s/docs/LOCAL_SETUP.md) — Local development setup guide
- [k8s/docs/UPCLOUD_SETUP.md](k8s/docs/UPCLOUD_SETUP.md) — UpCloud deployment guide
- [k8s/docs/AZURE_SETUP.md](k8s/docs/AZURE_SETUP.md) — Azure deployment guide
- [k8s/docs/AWS_SETUP.md](k8s/docs/AWS_SETUP.md) — AWS deployment guide
- [k8s/docs/GCP_SETUP.md](k8s/docs/GCP_SETUP.md) — GCP deployment guide
- [k8s/docs/KEYCLOAK_SSO.md](k8s/docs/KEYCLOAK_SSO.md) — Keycloak SSO configuration
- [k8s/docs/SSO_TESTING_GUIDE.md](k8s/docs/SSO_TESTING_GUIDE.md) — SSO testing guide
- [k8s/argocd/README.md](k8s/argocd/README.md) — ArgoCD app-of-apps patterns
