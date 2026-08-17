# Azure Deployment Guide

Deploy the DevOps platform to Azure Kubernetes Service (AKS) with managed data services and automatic Let's Encrypt TLS.

## Prerequisites

- **Azure account** with appropriate permissions
- **Azure CLI** installed (`az` command)
- **OpenTofu** installed (`tofu` CLI)
- **kubectl**, **helm**, **jq** installed
- **Domain name** you control (for DNS configuration)

## Architecture

```
Internet
    |
    v
DNS (*.yourdomain.com) --> Azure LoadBalancer
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
    v (private VNet)
    +---> Azure PostgreSQL Flexible Server (Keycloak DB, Forgejo DB)
    +---> Azure Cache for Redis (Forgejo cache/sessions)
    +---> Azure Blob Storage (Forgejo artifacts, registry, backups)
```

## Guided path

```bash
./devhub quickstart --env azure-dev
```

Detects what is already done, shows a checklist, and runs the next step — including
everything described below. Safe to re-run; use `--status` for just the checklist.

The rest of this guide is the same sequence, step by step, for when you want to
drive it yourself or need to understand a specific step.

## Step-by-Step Setup

### Step 0a: External prerequisites

```bash
./devhub preflight --env azure-dev
```

Prints what the platform assumes about the outside world, verifies what it can
(CLI authentication, DNS zone, registrar delegation) and asks about the rest.

The one that catches people: **the DNS zone must exist in the cloud, and the
registrar must delegate to it.** On AWS and Azure the tofu module looks the zone up
with a data source, so `tofu apply` fails outright without it. Everywhere else,
missing delegation means certificates stay pending — cert-manager cannot complete an
HTTP-01 challenge for a name the internet cannot resolve.

Re-check DNS alone at any time with `./devhub preflight --env azure-dev --dns`.

### Step 0b: Configure the environment (wizard)

```bash
./devhub setup --env azure-dev
```

Asks for:
  - your domain and the ACME contact address
  - which CIDRs may reach the Kubernetes API (offers your current public IP,
    specific CIDRs, or no public endpoint at all)
#   - Entra group object ids for cluster-admin (optional)
  - where tofu state lives

Then writes `tofu/azure/dev/backend.hcl` and `terraform.tfvars`, sets
`domain` / `acmeEmail` / `gitops.repoUrl` in `k8s/overlays/azure-dev/config.yaml`, and offers
to create the state bucket (tofu cannot create its own backend).

Add `--dry-run` to preview, or drive it non-interactively with
`--non-interactive --yes --domain ... --acme-email ... --api-cidrs ...`.

Skip this step only if you prefer to copy the `.example` files by hand.

### Step 1: Provision Infrastructure with OpenTofu

```bash
# Authenticate with Azure
az login

# For dev environment:
cd tofu/azure/dev

# Remote state (partial backend config). State holds database passwords and IdP
# client secrets, so it lives in the Storage Account container, never on a laptop.
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
cd tofu/azure/prod
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
tofu init -backend-config=backend.hcl && tofu apply
```

This provisions:
- Virtual Network with subnets for AKS, PostgreSQL, and Redis
- Managed Kubernetes cluster (AKS) with private worker nodes
- Azure PostgreSQL Flexible Server (databases: `keycloak`, `forgejo`)
- Azure Cache for Redis
- Azure Storage Account with Blob containers for Forgejo
- Managed Identity for Keycloak to authenticate with Entra ID

Review environment-specific settings in `tofu/azure/dev/main.tf` or `tofu/azure/prod/main.tf`.

### Step 2: Sync Tofu Outputs to K8s Config

```bash
cd k8s/scripts
./sync-tofu-outputs.sh --env azure-dev
```

This script:
- Reads tofu outputs (PG host, Redis host, Storage account, etc.)
- Writes them into `k8s/overlays/azure-dev/config.yaml`
- Fetches the AKS cluster credentials via `az aks get-credentials`

### Step 3: Configure Domain and Email

Edit `k8s/overlays/azure-dev/config.yaml`:

```yaml
domain: dev.yourdomain.com
acmeEmail: admin@yourdomain.com
```

### Step 4: Configure DNS

After tofu apply, the AKS cluster gets a LoadBalancer IP. Find it:

```bash
export KUBECONFIG=k8s/scripts/azure-dev/kubeconfig
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
export KUBECONFIG=azure-dev/kubeconfig

# Managed PostgreSQL has no Terraform resource for local users; create them once
# (idempotent — safe to re-run).
./deploy.sh --env azure-dev db-users

# Deploy the platform
./deploy.sh --env azure-dev

# Initialise Vault (auto-unseals via cloud KMS; root token is revoked at the end)
./setup-vault.sh --env azure-dev

# Realm, groups and OIDC clients
./setup-keycloak.sh --env azure-dev

# Move platform credentials into Vault; External Secrets delivers them from now on
./deploy.sh --env azure-dev platform-secrets

# GitOps: app-of-apps, then hand the platform components to ArgoCD
./deploy.sh --env azure-dev bootstrap
./deploy.sh --env azure-dev gitops
```

After the handover, change cert-manager, external-dns, external-secrets, the
monitoring stack, Kyverno, Reloader, Headlamp, Homepage and Velero **through
git** — ArgoCD
self-heals manual `helm upgrade`s away. See [OPERATIONS.md](OPERATIONS.md).

### Step 6: Verify

```bash
# Check all services
./deploy.sh --env azure-dev all status

# Check certificate issuance
kubectl get certificate -A
kubectl describe certificate -n <namespace>

# Access services
open https://keycloak.dev.yourdomain.com
open https://argocd.dev.yourdomain.com
open https://grafana.dev.yourdomain.com
```

## Environment Differences

| Setting | Dev (`tofu/azure/dev`) | Prod (`tofu/azure/prod`) |
|---------|--------------------------|----------------------------|
| Prefix | `devhub-dev` | `devhub` |
| Location | `norwayeast` | `westeurope` |
| Resource Group | `devhub-dev-rg` | `devhub-prod-rg` |
| AKS Node Size | `Standard_B2s` | `Standard_D4s_v3` |
| AKS Node Count | 2 | 3 |
| PostgreSQL SKU | `B_Standard_B1ms` | `GP_Standard_D2s_v3` |
| PostgreSQL Storage | 32 GB | 100 GB |
| PostgreSQL HA | Disabled | Zone-redundant |
| Redis SKU | Basic C0 (250 MB) | Standard C1 (1 GB) |
| Storage Replication | LRS (locally redundant) | GRS (geo-redundant) |
| Delete Lock | off | on |

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

## Entra ID Integration (Optional)

The infrastructure provisions an Azure Managed Identity for Keycloak. You can optionally configure Keycloak to use Entra ID as an external Identity Provider:

```bash
# Get Entra ID details from tofu outputs
cd tofu/azure/dev
tofu output entra_client_id
tofu output entra_tenant_id

# Configure in Keycloak UI or via setup-keycloak.sh
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
Azure may take a few minutes. Check subscription quota limits if it persists.

### Cannot connect to managed databases
Managed services are on the private VNet. Verify the AKS pods can reach them:
```bash
kubectl run debug --rm -it --image=busybox -- nslookup <pg-host>
```

### PostgreSQL connection issues
Ensure that the AKS subnet has access to the PostgreSQL delegated subnet and firewall rules allow VNet access.

### Tofu state issues
```bash
cd tofu/azure/dev
tofu refresh          # Sync state with actual resources
tofu state list       # List managed resources
```

## Cost Optimization

To reduce costs in development:
- Use `tofu destroy` when not actively developing
- Consider smaller VM SKUs in dev (`B2s` instead of `D4s_v3`)
- Use Basic tier for Redis in dev
- Use Zone-redundant storage (ZRS) instead of Geo-redundant (GRS) if not needed

## Security Considerations

- AKS worker nodes are deployed in a private subnet
- PostgreSQL and Redis are only accessible from the VNet
- Enable Azure Policy for additional compliance controls
- Use Azure Key Vault for storing tofu secrets (e.g., database passwords)
- Restrict API server access with `api_server_authorized_ip_ranges` in production
- Enable Azure Defender for AKS, SQL, and Storage in production
