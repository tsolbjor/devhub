# AWS Deployment Guide

Deploy the DevOps platform to Amazon Elastic Kubernetes Service (EKS) with managed data services and automatic Let's Encrypt TLS.

## Prerequisites

- **AWS account** with appropriate IAM permissions
- **AWS CLI** installed and configured (`aws` command)
- **OpenTofu** installed (`tofu` CLI)
- **kubectl**, **helm**, **jq** installed
- **Domain name** you control (for DNS configuration)

## Architecture

```
Internet
    |
    v
DNS (*.yourdomain.com) --> AWS Network LoadBalancer
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
    v (private VPC subnets)
    +---> Amazon RDS PostgreSQL (Keycloak DB, Forgejo DB)
    +---> Amazon ElastiCache Redis (Forgejo cache/sessions)
    +---> Amazon S3 (Forgejo artifacts, registry, backups)
```

## Guided path

```bash
./devhub quickstart --env aws-dev
```

Detects what is already done, shows a checklist, and runs the next step — including
everything described below. Safe to re-run; use `--status` for just the checklist.

The rest of this guide is the same sequence, step by step, for when you want to
drive it yourself or need to understand a specific step.

## Step-by-Step Setup

### Step 0a: External prerequisites

```bash
./devhub preflight --env aws-dev
```

Prints what the platform assumes about the outside world, verifies what it can
(CLI authentication, DNS zone, registrar delegation) and asks about the rest.

The one that catches people: **the DNS zone must exist in the cloud, and the
registrar must delegate to it.** On AWS and Azure the tofu module looks the zone up
with a data source, so `tofu apply` fails outright without it. Everywhere else,
missing delegation means certificates stay pending — cert-manager cannot complete an
HTTP-01 challenge for a name the internet cannot resolve.

Re-check DNS alone at any time with `./devhub preflight --env aws-dev --dns`.

### Step 0b: Configure the environment (wizard)

```bash
./devhub setup --env aws-dev
```

Asks for:
  - your domain and the ACME contact address
  - which CIDRs may reach the Kubernetes API (offers your current public IP,
    specific CIDRs, or no public endpoint at all)
  - where tofu state lives

Then writes `tofu/aws/dev/backend.hcl` and `terraform.tfvars`, sets
`domain` / `acmeEmail` / `gitops.repoUrl` in `k8s/overlays/aws-dev/config.yaml`, and offers
to create the state bucket (tofu cannot create its own backend).

Add `--dry-run` to preview, or drive it non-interactively with
`--non-interactive --yes --domain ... --acme-email ... --api-cidrs ...`.

Skip this step only if you prefer to copy the `.example` files by hand.

### Step 1: Provision Infrastructure with OpenTofu

```bash
# Configure AWS credentials
export AWS_REGION=us-east-1  # or your preferred region
aws configure

# For dev environment:
cd tofu/aws/dev

# Remote state (partial backend config). State holds database passwords and IdP
# client secrets, so it lives in the S3 bucket + DynamoDB lock table, never on a laptop.
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
cd tofu/aws/prod
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
tofu init -backend-config=backend.hcl && tofu apply
```

This provisions:
- VPC with public and private subnets across multiple Availability Zones
- Managed Kubernetes cluster (EKS) with private worker nodes
- Amazon RDS PostgreSQL (databases: `keycloak`, `forgejo`)
- Amazon ElastiCache Redis cluster
- S3 buckets for Loki log chunks and Velero backups
- IAM roles for service accounts (IRSA) for Loki, Velero and Vault
- Cognito User Pool for optional Keycloak federation

Review environment-specific settings in `tofu/aws/dev/main.tf` or `tofu/aws/prod/main.tf`.

### Step 2: Sync Tofu Outputs to K8s Config

```bash
cd k8s/scripts
./sync-tofu-outputs.sh --env aws-dev
```

This script writes four gitignored files under `k8s/scripts/aws-dev/`:

| File | Contents |
|------|----------|
| `tofu-outputs.env` | hosts, bucket names, IAM role ARNs, KMS key ids |
| `secrets.env` | database passwords, cache auth token, IdP client secret |
| `manual-secrets.env` | values tofu cannot create (created once, never overwritten) |
| `kubeconfig` | cluster credentials for this environment |

`config.yaml` is **not** modified — it stays human-owned (domain, TLS, GitOps
repo), so `tofu apply` produces no git diff and Helm templating no longer depends
on parsing YAML with `sed`.

### Step 3: Configure Domain and Email

Edit `k8s/overlays/aws-dev/config.yaml`:

```yaml
domain: dev.yourdomain.com
acmeEmail: admin@yourdomain.com
```

### Step 4: Configure DNS

After tofu apply and deploying Envoy Gateway, the EKS cluster gets a Network LoadBalancer. Find its hostname:

```bash
export KUBECONFIG=k8s/scripts/aws-dev/kubeconfig
kubectl get svc -n envoy-gateway-system   # the Envoy data-plane LoadBalancer
```

Create DNS records pointing to the LoadBalancer hostname:

**Option 1: CNAME wildcard (recommended for Route53)**
```
*.dev.yourdomain.com  CNAME  <LoadBalancer DNS name>
```

**Option 2: A records with alias (Route53)**
```
*.dev.yourdomain.com  ALIAS  <LoadBalancer DNS name>
```

Or individual records for each service (keycloak, git, ci, argocd, grafana, etc.)

### Step 5: Deploy Platform Services

```bash
cd k8s/scripts
export KUBECONFIG=aws-dev/kubeconfig

# Managed PostgreSQL has no Terraform resource for local users; create them once
# (idempotent — safe to re-run).
./deploy.sh --env aws-dev db-users

# Deploy the platform
./deploy.sh --env aws-dev

# Initialise Vault (auto-unseals via cloud KMS; root token is revoked at the end)
./setup-vault.sh --env aws-dev

# Realm, groups and OIDC clients
./setup-keycloak.sh --env aws-dev

# Move platform credentials into Vault; External Secrets delivers them from now on
./deploy.sh --env aws-dev platform-secrets

# GitOps: app-of-apps, then hand the platform components to ArgoCD
./deploy.sh --env aws-dev bootstrap
./deploy.sh --env aws-dev gitops
```

After the handover, change cert-manager, external-dns, external-secrets, the
monitoring stack, Kyverno, Reloader, Headlamp, Homepage and Velero **through
git** — ArgoCD
self-heals manual `helm upgrade`s away. See [OPERATIONS.md](OPERATIONS.md).

### Step 6: Publish the environment's GitOps repository

```bash
./devhub gitops-repo --env aws-dev
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
./devhub validate --e2e --env aws-dev
```

#### Further checks

```bash
# Check all services
./deploy.sh --env aws-dev all status

# Check certificate issuance
kubectl get certificate -A
kubectl describe certificate -n <namespace>

# Access services
open https://keycloak.dev.yourdomain.com
open https://argocd.dev.yourdomain.com
open https://grafana.dev.yourdomain.com
```

## Environment Differences

| Setting | Dev (`tofu/aws/dev`) | Prod (`tofu/aws/prod`) |
|---------|--------------------------|----------------------------|
| Prefix | `devhub-dev` | `devhub` |
| Region | Configurable via `var.region` | Configurable via `var.region` |
| Availability Zones | 2 AZs | 3 AZs |
| EKS Node Type | `t3.medium` | `m5.xlarge` |
| EKS Node Count | 2 (min 1, max 4) | 3 (min 3, max 6) |
| Kubernetes Version | 1.30 | 1.30 |
| RDS Instance | `db.t3.micro` | `db.r5.large` |
| RDS Storage | 20 GB | 100 GB |
| RDS Multi-AZ | Disabled | Enabled |
| Redis Node Type | `cache.t3.micro` | `cache.r5.large` |
| Redis Clusters | 1 (no failover) | 2 (automatic failover) |
| Deletion Protection | off | on |

## Data Service Secrets

`deploy.sh` creates the K8s secrets the charts expect directly from
`secrets.env`, so there is no manual `kubectl create secret` step. On AWS, GCP and
Azure the object-storage secrets carry no credentials at all — access comes from
IRSA / Workload Identity.

## IAM Roles for Service Accounts (IRSA)

Forgejo uses IRSA to access S3 buckets without storing AWS credentials. The tofu module creates the necessary IAM role and OIDC provider. The role ARN is written to `tofu-outputs.env` by `sync-tofu-outputs.sh` and used in Forgejo's Helm values.

## TLS Certificates

cert-manager automatically provisions Let's Encrypt certificates. For initial testing, use the staging issuer to avoid rate limits:

```yaml
# In tofu-outputs.env (generated)
tls:
  clusterIssuer: letsencrypt-staging   # Switch to letsencrypt-prod when verified
```

## Cognito Integration (Optional)

The infrastructure provisions an AWS Cognito User Pool. You can optionally configure Keycloak to use Cognito as an external Identity Provider:

```bash
# Get Cognito details from tofu outputs
cd tofu/aws/dev
tofu output cognito_user_pool_id
tofu output cognito_client_id
tofu output cognito_issuer_url

# Configure in Keycloak UI or via setup-keycloak.sh
```

**Note:** The `cognito_domain_prefix` in the tofu configuration must be globally unique across all AWS accounts. Update it in `tofu/aws/dev/main.tf` or `tofu/aws/prod/main.tf` before applying.

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
AWS may take a few minutes. Check service quotas if it persists.

### Cannot connect to RDS or ElastiCache
Managed services are in private subnets. Verify the EKS pods can reach them:
```bash
kubectl run debug --rm -it --image=busybox -- nslookup <rds-endpoint>
```

### RDS connection issues
Ensure that the EKS security group has access to the RDS security group on port 5432.

### S3 access denied
Verify that the Forgejo service account is annotated with the IRSA role ARN and that the IAM role trust policy allows the OIDC provider.

### Tofu state issues
```bash
cd tofu/aws/dev
tofu refresh          # Sync state with actual resources
tofu state list       # List managed resources
```

## Cost Optimization

To reduce costs in development:
- Use `tofu destroy` when not actively developing
- Use smaller instance types in dev (`t3` family)
- Consider using Spot instances for EKS worker nodes
- Use single-AZ RDS without read replicas
- Use single-node ElastiCache without automatic failover
- Set S3 lifecycle policies to expire old objects

## Security Considerations

- EKS worker nodes are deployed in private subnets with NAT Gateway for egress
- RDS and ElastiCache are only accessible from the VPC
- Use AWS Secrets Manager or Parameter Store for storing tofu secrets
- Restrict EKS API server access with CIDR blocks in production
- Enable AWS GuardDuty and Security Hub in production
- Use VPC Flow Logs for network monitoring
- Enable RDS encryption at rest and in transit
- Enable S3 bucket encryption and versioning
- Regularly rotate RDS and Redis passwords using Vault or External Secrets Operator
