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
nginx-ingress (TLS via cert-manager / Let's Encrypt)
    |
    +---> Keycloak (SSO)
    +---> GitLab (source control, CI/CD)
    +---> ArgoCD (GitOps)
    +---> Grafana / Prometheus (monitoring)
    +---> Vault (secrets)
    |
    v (private VPC network)
    +---> Cloud SQL PostgreSQL (Keycloak DB, GitLab DB)
    +---> Memorystore Redis (GitLab cache/sessions)
    +---> Google Cloud Storage (GitLab artifacts, registry, backups)
```

## Step-by-Step Setup

### Step 1: Provision Infrastructure with OpenTofu

```bash
# Authenticate with Google Cloud
gcloud auth application-default login

# Set your GCP project
export TF_VAR_project_id=your-gcp-project-id
export TF_VAR_region=us-central1  # or your preferred region

# For dev environment:
cd tofu/gcp/dev
tofu init
tofu plan     # Review what will be created
tofu apply    # Provision (takes 15-20 min)

# For prod environment:
cd tofu/gcp/prod
tofu init && tofu apply
```

This provisions:
- VPC network with subnet for GKE cluster
- Managed Kubernetes cluster (GKE) with private worker nodes
- Cloud SQL PostgreSQL instance (databases: `keycloak`, `gitlabhq_production`)
- Memorystore for Redis instance
- Google Cloud Storage buckets for GitLab artifacts, registry, uploads, and backups
- Google Service Account for GitLab to access GCS via Workload Identity
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

After tofu apply and deploying nginx-ingress, the GKE cluster gets a LoadBalancer IP. Find it:

```bash
export KUBECONFIG=k8s/scripts/gcp-dev/kubeconfig
kubectl get svc -n ingress-nginx
```

Create wildcard DNS A record:
```
*.dev.yourdomain.com  A  <LoadBalancer IP>
```

Or individual records for each service (keycloak, gitlab, argocd, grafana, etc.)

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

# Deploy everything
./deploy.sh --env gcp-dev

# Configure Keycloak SSO
./setup-keycloak.sh --env gcp-dev

# Initialize Vault
./setup-vault.sh --env gcp-dev

# Bootstrap ArgoCD GitOps
./deploy.sh --env gcp-dev bootstrap
```

### Step 6: Verify

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

After deploying with managed data services, `deploy.sh` checks for required K8s secrets. Create them using tofu outputs:

```bash
cd tofu/gcp/dev

# Get passwords and connection info
tofu output pg_keycloak_password
tofu output pg_gitlab_password
tofu output redis_auth_string
tofu output gcs_gitlab_artifacts_bucket

# Create K8s secrets (see deploy.sh configure_managed_data_services for required keys)
kubectl create secret generic keycloak-db-secret -n keycloak \
    --from-literal=password="$(tofu output -raw pg_keycloak_password)"

kubectl create secret generic gitlab-postgresql-secret -n gitlab \
    --from-literal=password="$(tofu output -raw pg_gitlab_password)"

kubectl create secret generic gitlab-redis-secret -n gitlab \
    --from-literal=password="$(tofu output -raw redis_auth_string)"
```

## Workload Identity for GitLab GCS Access

GitLab uses GCP Workload Identity to access GCS buckets without storing service account keys. The tofu module:
1. Creates a Google Service Account (GSA) with GCS permissions
2. Binds it to the GitLab Kubernetes Service Account (KSA) via IAM policy

The GSA email is written to config.yaml by `sync-tofu-outputs.sh` and used to annotate the GitLab KSA.

## TLS Certificates

cert-manager automatically provisions Let's Encrypt certificates. For initial testing, use the staging issuer to avoid rate limits:

```yaml
# In config.yaml
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
kubectl get svc -n ingress-nginx -w
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
Verify that the GitLab service account is annotated with the GSA email and that Workload Identity is enabled on the GKE cluster.

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
