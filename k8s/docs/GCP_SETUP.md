# GCP Deployment Guide

Deploy the DevOps platform to Google Kubernetes Engine (GKE) with managed data services and automatic Let's Encrypt TLS.

## Prerequisites

- **Google Cloud account** with a project and appropriate IAM permissions
- **gcloud CLI** installed and configured
- **OpenTofu** installed (`tofu` CLI)
- **kubectl**, **helm**, **jq** installed
- **Domain name** you control (for DNS configuration)

## Architecture

```
Internet
    |
    v
DNS (*.yourdomain.com) --> GCP LoadBalancer
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
    v (private VPC network)
    +---> Cloud SQL PostgreSQL (Keycloak DB, Forgejo DB)
    +---> Memorystore Redis (Forgejo cache/sessions)
    +---> Google Cloud Storage (Forgejo artifacts, registry, backups)
```

## Guided path

```bash
./devhub quickstart --env gcp-dev
```

Detects what is already done, shows a checklist, and runs the next step — including
everything described below. Safe to re-run; use `--status` for just the checklist.

The rest of this guide is the same sequence, step by step, for when you want to
drive it yourself or need to understand a specific step.

## Step-by-Step Setup

### Step 0a: External prerequisites

```bash
./devhub preflight --env gcp-dev
```

Prints what the platform assumes about the outside world, verifies what it can
(CLI authentication, DNS zone, registrar delegation) and asks about the rest.

The one that catches people: **the DNS zone must exist in the cloud, and the
registrar must delegate to it.** On AWS and Azure the tofu module looks the zone up
with a data source, so `tofu apply` fails outright without it. Everywhere else,
missing delegation means certificates stay pending — cert-manager cannot complete an
HTTP-01 challenge for a name the internet cannot resolve.

Re-check DNS alone at any time with `./devhub preflight --env gcp-dev --dns`.

### Step 0b: Configure the environment (wizard)

```bash
./devhub setup --env gcp-dev
```

Asks for:
  - your domain and the ACME contact address
  - which CIDRs may reach the Kubernetes API (offers your current public IP,
    specific CIDRs, or no public endpoint at all)
#   - the GCP project id
  - where tofu state lives

Then writes `tofu/gcp/dev/backend.hcl` and `terraform.tfvars`, sets
`domain` / `acmeEmail` / `gitops.repoUrl` in `k8s/overlays/gcp-dev/config.yaml`, and offers
to create the state bucket (tofu cannot create its own backend).

Add `--dry-run` to preview, or drive it non-interactively with
`--non-interactive --yes --domain ... --acme-email ... --api-cidrs ...`.

Skip this step only if you prefer to copy the `.example` files by hand.

### Step 1: Provision Infrastructure with OpenTofu

```bash
# Authenticate with Google Cloud
gcloud auth application-default login

# Set your GCP project
export TF_VAR_project_id=your-gcp-project-id
export TF_VAR_region=us-central1  # or your preferred region

# For dev environment:
cd tofu/gcp/dev

# Remote state (partial backend config). State holds database passwords and IdP
# client secrets, so it lives in the GCS bucket, never on a laptop.
cp backend.hcl.example backend.hcl     # fill in your bucket/container names
tofu init -backend-config=backend.hcl

# Required variable: who may reach the Kubernetes API server. There is no
# default — an internet-facing control plane should be a deliberate choice.
cp terraform.tfvars.example terraform.tfvars
#   api_allowed_cidrs = ["203.0.113.4/32"]   # office egress
#   api_allowed_cidrs = []                   # private endpoint only
tofu plan     # Review what will be created
tofu apply    # Provision (takes 15-20 min)

# For prod environment:
cd tofu/gcp/prod
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
tofu init -backend-config=backend.hcl && tofu apply
```

This provisions:
- VPC network with subnet for GKE cluster
- Managed Kubernetes cluster (GKE) with private worker nodes
- Cloud SQL PostgreSQL instance (databases: `keycloak`, `forgejo`)
- Memorystore for Redis instance
- Google Cloud Storage buckets for Loki log chunks and Velero backups
- Google Service Account for Forgejo to access GCS via Workload Identity
- Private Service Connection for Cloud SQL and Memorystore

Review environment-specific settings in `tofu/gcp/dev/main.tf` or `tofu/gcp/prod/main.tf`.

### Step 2: Sync Tofu Outputs to K8s Config

```bash
cd k8s/scripts
./sync-tofu-outputs.sh --env gcp-dev
```

This script:
- Reads tofu outputs (Cloud SQL host, Redis host, GCS buckets, etc.)
- Writes them into `k8s/overlays/gcp-dev/config.yaml`
- Fetches GKE cluster credentials via `gcloud container clusters get-credentials`

### Step 3: Configure Domain and Email

Edit `k8s/overlays/gcp-dev/config.yaml`:

```yaml
domain: dev.yourdomain.com
acmeEmail: admin@yourdomain.com
```

### Step 4: Configure DNS

After tofu apply and deploying Envoy Gateway, the GKE cluster gets a LoadBalancer IP. Find it:

```bash
export KUBECONFIG=k8s/scripts/gcp-dev/kubeconfig
kubectl get svc -n envoy-gateway-system   # the Envoy data-plane LoadBalancer
```

Create wildcard DNS A record:
```
*.dev.yourdomain.com  A  <LoadBalancer IP>
```

Or individual records for each service (keycloak, git, ci, argocd, grafana, etc.)

**Using Cloud DNS (optional):**
```bash
# Create a managed zone
gcloud dns managed-zones create dev-zone \
    --dns-name="dev.yourdomain.com." \
    --description="Dev environment zone"

# Add A record
gcloud dns record-sets create "*.dev.yourdomain.com." \
    --zone="dev-zone" \
    --type="A" \
    --ttl="300" \
    --rrdatas="<LoadBalancer IP>"
```

### Step 5: Deploy Platform Services

```bash
cd k8s/scripts
export KUBECONFIG=gcp-dev/kubeconfig

# Managed PostgreSQL has no Terraform resource for local users; create them once
# (idempotent — safe to re-run).
./deploy.sh --env gcp-dev db-users

# Deploy the platform
./deploy.sh --env gcp-dev

# Initialise Vault (auto-unseals via cloud KMS; root token is revoked at the end)
./setup-vault.sh --env gcp-dev

# Realm, groups and OIDC clients
./setup-keycloak.sh --env gcp-dev

# Move platform credentials into Vault; External Secrets delivers them from now on
./deploy.sh --env gcp-dev platform-secrets

# GitOps: app-of-apps, then hand the platform components to ArgoCD
./deploy.sh --env gcp-dev bootstrap
./deploy.sh --env gcp-dev gitops
```

After the handover, change cert-manager, external-dns, external-secrets, the
monitoring stack, Kyverno, Reloader, Headlamp, Homepage and Velero **through
git** — ArgoCD
self-heals manual `helm upgrade`s away. See [OPERATIONS.md](OPERATIONS.md).

### Step 6: Publish the environment's GitOps repository

```bash
./devhub gitops-repo --env gcp-dev
```

Publishes a standalone copy of the platform into this environment's own
Forgejo and points ArgoCD at it. From then on the environment is independent
of this devhub checkout — work on it from its own repository. If you gave
`setup` a mirror URL and token, Forgejo pushes every commit to the
off-cluster mirror.

### Step 7: Verify

```bash
# Browser end-to-end: one Keycloak sign-in, then read-only assertions
# against every service (Grafana datasources, ArgoCD apps, Vault seal state…)
./devhub validate --e2e --env gcp-dev
```

#### Further checks

```bash
# Check all services
./deploy.sh --env gcp-dev all status

# Check certificate issuance
kubectl get certificate -A
kubectl describe certificate -n <namespace>

# Access services
open https://keycloak.dev.yourdomain.com
open https://argocd.dev.yourdomain.com
open https://grafana.dev.yourdomain.com
```

## Environment Differences

| Setting | Dev (`tofu/gcp/dev`) | Prod (`tofu/gcp/prod`) |
|---------|--------------------------|----------------------------|
| Prefix | `devhub-dev` | `devhub` |
| Region | Configurable via `var.region` | Configurable via `var.region` |
| GKE Node Type | `e2-standard-2` | `e2-standard-4` |
| GKE Node Count | 2 | 3 |
| Cloud SQL Tier | `db-g1-small` | `db-n1-standard-2` |
| Cloud SQL Storage | 20 GB | 100 GB |
| Cloud SQL Availability | Zonal | Regional (HA) |
| Cloud SQL Deletion Protection | off | on |
| Redis Tier | BASIC (no HA) | STANDARD_HA |
| Redis Memory | 1 GB | 4 GB |
| GCS Storage Class | STANDARD | STANDARD |
| Deletion Protection | off | on |

## Data Service Secrets

`deploy.sh` creates the K8s secrets the charts expect directly from
`secrets.env`, so there is no manual `kubectl create secret` step. On AWS, GCP and
Azure the object-storage secrets carry no credentials at all — access comes from
IRSA / Workload Identity.

## Workload Identity for Forgejo GCS Access

Forgejo uses GCP Workload Identity to access GCS buckets without storing service account keys. The tofu module:
1. Creates a Google Service Account (GSA) with GCS permissions
2. Binds it to the Forgejo Kubernetes Service Account (KSA) via IAM policy

The GSA email is written to config.yaml by `sync-tofu-outputs.sh` and used to annotate the Forgejo KSA.

## TLS Certificates

cert-manager automatically provisions Let's Encrypt certificates. For initial testing, use the staging issuer to avoid rate limits:

```yaml
# In tofu-outputs.env (generated)
tls:
  clusterIssuer: letsencrypt-staging   # Switch to letsencrypt-prod when verified
```

## Google Identity Integration (Optional)

You can configure Keycloak to use Google as an external Identity Provider. This requires manual OAuth client setup in Google Cloud Console:

1. Go to APIs & Services > Credentials
2. Create OAuth 2.0 Client ID
3. Add authorized redirect URI: `https://keycloak.dev.yourdomain.com/realms/devops/broker/google/endpoint`
4. Note the Client ID and Client Secret

Update `k8s/overlays/gcp-dev/config.yaml`:
```yaml
googleIdp:
  clientId: YOUR_CLIENT_ID
```

Then configure the client secret in Keycloak or via `setup-keycloak.sh`.

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
GCP may take a few minutes. Check project quotas if it persists.

### Cannot connect to Cloud SQL or Memorystore
Managed services are on the private service connection. Verify the GKE pods can reach them:
```bash
kubectl run debug --rm -it --image=busybox -- nslookup <cloudsql-host>
```

### Cloud SQL connection issues
Ensure that the GKE cluster VPC has access to Cloud SQL via Private Service Connection and that firewall rules allow traffic.

### GCS access denied
Verify that the Forgejo service account is annotated with the GSA email and that Workload Identity is enabled on the GKE cluster.

### Tofu state issues
```bash
cd tofu/gcp/dev
tofu refresh          # Sync state with actual resources
tofu state list       # List managed resources
```

## Cost Optimization

To reduce costs in development:
- Use `tofu destroy` when not actively developing
- Use smaller machine types in dev (`e2-standard-2` or `e2-medium`)
- Consider using preemptible nodes for non-critical workloads
- Use zonal Cloud SQL without HA
- Use BASIC tier Redis without replication
- Set GCS lifecycle policies to delete old objects
- Use NEARLINE or COLDLINE storage class for infrequent access

## Security Considerations

- GKE worker nodes are deployed with private IPs only
- Cloud SQL and Memorystore are only accessible from the VPC
- Use Secret Manager for storing tofu secrets
- Restrict GKE control plane access with authorized networks in production
- Enable Binary Authorization to enforce signed container images
- Use Workload Identity instead of storing service account keys
- Enable Cloud SQL IAM authentication (requires additional configuration)
- Enable GCS encryption with customer-managed keys (CMEK) if required
- Enable VPC Flow Logs and Cloud Audit Logs for monitoring
- Regularly rotate Cloud SQL and Redis passwords using Vault or External Secrets Operator
- Use Private Google Access to access GCP APIs without egress to the internet
