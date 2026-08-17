# UpCloud Deployment Guide

Deploy the DevOps platform to UpCloud Managed Kubernetes with managed data services and automatic Let's Encrypt TLS.

## Prerequisites

- **UpCloud account** with API credentials (`UPCLOUD_USERNAME`, `UPCLOUD_PASSWORD`)
- **OpenTofu** installed (`tofu` CLI)
- **upctl** installed (UpCloud CLI, for kubeconfig fetch)
- **kubectl**, **helm**, **jq** installed
- **Domain name** you control (for DNS configuration)

## Architecture

```
Internet
    |
    v
DNS (*.yourdomain.com) --> UpCloud LoadBalancer
    |
    v
Envoy Gateway / Gateway API (TLS via cert-manager / Let's Encrypt)
    |
    +---> Keycloak (SSO)
    +---> Forgejo (source control, CI/CD)
    +---> ArgoCD (GitOps)
    +---> Grafana / Prometheus (monitoring)
    +---> Vault (secrets)
    |
    v (private SDN network)
    +---> Managed PostgreSQL (Keycloak DB, Forgejo DB)
    +---> Managed Valkey (Forgejo cache/sessions)
    +---> Managed Object Storage (Forgejo artifacts, registry, backups)
```

## Guided path

```bash
./devhub quickstart --env upcloud-dev
```

Detects what is already done, shows a checklist, and runs the next step — including
everything described below. Safe to re-run; use `--status` for just the checklist.

The rest of this guide is the same sequence, step by step, for when you want to
drive it yourself or need to understand a specific step.

## Step-by-Step Setup

### Step 0a: External prerequisites

```bash
./devhub preflight --env upcloud-dev
```

Prints what the platform assumes about the outside world, verifies what it can
(CLI authentication, DNS zone, registrar delegation) and asks about the rest.

The one that catches people: **the DNS zone must exist in the cloud, and the
registrar must delegate to it.** On AWS and Azure the tofu module looks the zone up
with a data source, so `tofu apply` fails outright without it. Everywhere else,
missing delegation means certificates stay pending — cert-manager cannot complete an
HTTP-01 challenge for a name the internet cannot resolve.

Re-check DNS alone at any time with `./devhub preflight --env upcloud-dev --dns`.

### Step 0b: Configure the environment (wizard)

```bash
./devhub setup --env upcloud-dev
```

Asks for:
  - your domain and the ACME contact address
  - which CIDRs may reach the Kubernetes API (offers your current public IP,
    specific CIDRs, or no public endpoint at all)
#   - the Managed Object Storage S3 endpoint
  - where tofu state lives

Then writes `tofu/upcloud/dev/backend.hcl` and `terraform.tfvars`, sets
`domain` / `acmeEmail` / `gitops.repoUrl` in `k8s/overlays/upcloud-dev/config.yaml`, and offers
to create the state bucket (tofu cannot create its own backend).

Add `--dry-run` to preview, or drive it non-interactively with
`--non-interactive --yes --domain ... --acme-email ... --api-cidrs ...`.

Skip this step only if you prefer to copy the `.example` files by hand.

### Step 1: Provision Infrastructure with OpenTofu

```bash
# Set UpCloud credentials
export UPCLOUD_USERNAME=your-username
export UPCLOUD_PASSWORD=your-password

# For dev environment:
cd tofu/upcloud/dev

# Remote state (partial backend config). State holds database passwords and IdP
# client secrets, so it lives in the Managed Object Storage bucket, never on a laptop.
cp backend.hcl.example backend.hcl     # fill in your bucket/container names
tofu init -backend-config=backend.hcl

# Required variable: who may reach the Kubernetes API server. There is no
# default — an internet-facing control plane should be a deliberate choice.
cp terraform.tfvars.example terraform.tfvars
#   api_allowed_cidrs = ["203.0.113.4/32"]   # office egress
#   api_allowed_cidrs = []                   # private endpoint only
tofu plan     # Review what will be created
tofu apply    # Provision (takes 10-15 min)

# For prod environment:
cd tofu/upcloud/prod
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
tofu init -backend-config=backend.hcl && tofu apply
```

This provisions:
- Private SDN network with router and NAT gateway
- Managed Kubernetes cluster with private worker nodes
- Managed PostgreSQL (databases: `keycloak`, `forgejo`)
- Managed Valkey (Redis-compatible)
- Managed Object Storage with Forgejo S3 buckets

Review environment-specific settings in `tofu/upcloud/dev/main.tf` or `tofu/upcloud/prod/main.tf`.

### Step 2: Sync Tofu Outputs to K8s Config

```bash
cd k8s/scripts
./sync-tofu-outputs.sh --env upcloud-dev
```

This script:
- Reads tofu outputs (PG host, Valkey host, S3 endpoint, etc.)
- Writes them into `k8s/overlays/upcloud-dev/config.yaml`
- Fetches the cluster kubeconfig via `upctl`

### Step 3: Configure Domain and Email

Edit `k8s/overlays/upcloud-dev/config.yaml`:

```yaml
domain: dev.yourdomain.com
acmeEmail: admin@yourdomain.com
```

### Step 4: Configure DNS

After tofu apply, the K8s cluster gets a LoadBalancer IP. Find it:

```bash
export KUBECONFIG=k8s/scripts/upcloud-dev/kubeconfig
kubectl get svc -n envoy-gateway-system   # the Envoy data-plane LoadBalancer
```

Create wildcard DNS A record:
```
*.dev.yourdomain.com  A  <LoadBalancer IP>
```

Or individual records for each service (keycloak, git, ci, argocd, grafana, etc.)

### Step 5: Deploy Platform Services

```bash
cd k8s/scripts
export KUBECONFIG=upcloud-dev/kubeconfig

# (UpCloud's provider creates the database users itself — no db-users step.)

# Deploy the platform
./deploy.sh --env upcloud-dev

# Initialise Vault (auto-unseals via cloud KMS; root token is revoked at the end)
./setup-vault.sh --env upcloud-dev

# Realm, groups and OIDC clients
./setup-keycloak.sh --env upcloud-dev

# Move platform credentials into Vault; External Secrets delivers them from now on
./deploy.sh --env upcloud-dev platform-secrets

# GitOps: app-of-apps, then hand the platform components to ArgoCD
./deploy.sh --env upcloud-dev bootstrap
./deploy.sh --env upcloud-dev gitops
```

After the handover, change cert-manager, external-dns, external-secrets, the
monitoring stack, Kyverno, Reloader, Headlamp and Velero **through git** — ArgoCD
self-heals manual `helm upgrade`s away. See [OPERATIONS.md](OPERATIONS.md).

### Step 6: Verify

```bash
# Check all services
./deploy.sh --env upcloud-dev all status

# Check certificate issuance
kubectl get certificate -A
kubectl describe certificate -n <namespace>

# Access services
open https://keycloak.dev.yourdomain.com
open https://argocd.dev.yourdomain.com
open https://grafana.dev.yourdomain.com
```

## Environment Differences

| Setting | Dev (`tofu/upcloud/dev`) | Prod (`tofu/upcloud/prod`) |
|---------|--------------------------|----------------------------|
| Prefix | `devhub-dev` | `devhub` |
| Zone | `no-svg1` | `de-fra1` |
| Worker nodes | 2x `DEV-1xCPU-2GB` | 3x `4xCPU-8GB` |
| PostgreSQL | `1x1xCPU-2GB-25GB` | `2x2xCPU-4GB-100GB` |
| Termination protection | off | on |

## Data Service Secrets

`deploy.sh` creates the K8s secrets the charts expect directly from
`secrets.env`, so there is no manual `kubectl create secret` step. On AWS, GCP and
Azure the object-storage secrets carry no credentials at all — access comes from
IRSA / Workload Identity.

## TLS Certificates

cert-manager automatically provisions Let's Encrypt certificates. For initial testing, use the staging issuer to avoid rate limits:

```yaml
# In tofu-outputs.env (generated)
tls:
  clusterIssuer: letsencrypt-staging   # Switch to letsencrypt-prod when verified
```

## Troubleshooting

### Certificate not issuing
```bash
kubectl get certificaterequest -A
kubectl describe challenges -A
kubectl logs -n cert-manager deploy/cert-manager
```
Common causes: DNS not pointing to LoadBalancer, rate limited (use staging)

### LoadBalancer stuck in Pending
```bash
kubectl get svc -n envoy-gateway-system -w   # the Envoy data-plane LoadBalancer
```
UpCloud may take a few minutes. Check quota limits if it persists.

### Cannot connect to managed databases
Managed services are on the private network. Verify the K8s pods can reach them:
```bash
kubectl run debug --rm -it --image=busybox -- nslookup <pg-host>
```

### Tofu state issues
```bash
cd tofu/upcloud/dev
tofu refresh          # Sync state with actual resources
tofu state list       # List managed resources
```
