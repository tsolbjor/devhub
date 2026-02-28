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
nginx-ingress (TLS via cert-manager / Let's Encrypt)
    |
    +---> Keycloak (SSO)
    +---> GitLab (source control, CI/CD)
    +---> ArgoCD (GitOps)
    +---> Grafana / Prometheus (monitoring)
    +---> Vault (secrets)
    |
    v (private SDN network)
    +---> Managed PostgreSQL (Keycloak DB, GitLab DB)
    +---> Managed Valkey (GitLab cache/sessions)
    +---> Managed Object Storage (GitLab artifacts, registry, backups)
```

## Step-by-Step Setup

### Step 1: Provision Infrastructure with OpenTofu

```bash
# Set UpCloud credentials
export UPCLOUD_USERNAME=your-username
export UPCLOUD_PASSWORD=your-password

# For dev environment:
cd tofu/upcloud/dev
tofu init
tofu plan     # Review what will be created
tofu apply    # Provision (takes 10-15 min)

# For prod environment:
cd tofu/upcloud/prod
tofu init && tofu apply
```

This provisions:
- Private SDN network with router and NAT gateway
- Managed Kubernetes cluster with private worker nodes
- Managed PostgreSQL (databases: `keycloak`, `gitlabhq_production`)
- Managed Valkey (Redis-compatible)
- Managed Object Storage with GitLab S3 buckets

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
kubectl get svc -n ingress-nginx
```

Create wildcard DNS A record:
```
*.dev.yourdomain.com  A  <LoadBalancer IP>
```

Or individual records for each service (keycloak, gitlab, argocd, grafana, etc.)

### Step 5: Deploy Platform Services

```bash
cd k8s/scripts
export KUBECONFIG=upcloud-dev/kubeconfig

# Deploy everything
./deploy.sh --env upcloud-dev

# Configure Keycloak SSO
./setup-keycloak.sh --env upcloud-dev

# Initialize Vault
./setup-vault.sh --env upcloud-dev

# Bootstrap ArgoCD GitOps
./deploy.sh --env upcloud-dev bootstrap
```

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

After deploying with managed data services, `deploy.sh` checks for required K8s secrets. Create them using tofu outputs:

```bash
cd tofu/upcloud/dev

# Get passwords
tofu output pg_keycloak_password
tofu output pg_gitlab_password
tofu output valkey_password
tofu output s3_access_key
tofu output -raw s3_secret_key

# Create K8s secrets (see deploy.sh configure_managed_data_services for required keys)
kubectl create secret generic keycloak-db-secret -n keycloak \
    --from-literal=password="$(tofu output -raw pg_keycloak_password)"

kubectl create secret generic gitlab-postgresql-secret -n gitlab \
    --from-literal=password="$(tofu output -raw pg_gitlab_password)"

kubectl create secret generic gitlab-redis-secret -n gitlab \
    --from-literal=password="$(tofu output -raw valkey_password)"
```

## TLS Certificates

cert-manager automatically provisions Let's Encrypt certificates. For initial testing, use the staging issuer to avoid rate limits:

```yaml
# In config.yaml
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
kubectl get svc -n ingress-nginx -w
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
