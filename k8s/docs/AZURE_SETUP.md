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
nginx-ingress (TLS via cert-manager / Let's Encrypt)
    |
    +---> Keycloak (SSO)
    +---> GitLab (source control, CI/CD)
    +---> ArgoCD (GitOps)
    +---> Grafana / Prometheus (monitoring)
    +---> Vault (secrets)
    |
    v (private VNet)
    +---> Azure PostgreSQL Flexible Server (Keycloak DB, GitLab DB)
    +---> Azure Cache for Redis (GitLab cache/sessions)
    +---> Azure Blob Storage (GitLab artifacts, registry, backups)
```

## Step-by-Step Setup

### Step 1: Provision Infrastructure with OpenTofu

```bash
# Authenticate with Azure
az login

# For dev environment:
cd tofu/azure/dev
tofu init
tofu plan     # Review what will be created
tofu apply    # Provision (takes 10-15 min)

# For prod environment:
cd tofu/azure/prod
tofu init && tofu apply
```

This provisions:
- Virtual Network with subnets for AKS, PostgreSQL, and Redis
- Managed Kubernetes cluster (AKS) with private worker nodes
- Azure PostgreSQL Flexible Server (databases: `keycloak`, `gitlabhq_production`)
- Azure Cache for Redis
- Azure Storage Account with Blob containers for GitLab
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
export KUBECONFIG=azure-dev/kubeconfig

# Deploy everything
./deploy.sh --env azure-dev

# Configure Keycloak SSO
./setup-keycloak.sh --env azure-dev

# Initialize Vault
./setup-vault.sh --env azure-dev

# Bootstrap ArgoCD GitOps
./deploy.sh --env azure-dev bootstrap
```

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

After deploying with managed data services, `deploy.sh` checks for required K8s secrets. Create them using tofu outputs:

```bash
cd tofu/azure/dev

# Get passwords and connection info
tofu output pg_keycloak_password
tofu output pg_gitlab_password
tofu output redis_primary_access_key
tofu output storage_account_name
tofu output storage_primary_access_key

# Create K8s secrets (see deploy.sh configure_managed_data_services for required keys)
kubectl create secret generic keycloak-db-secret -n keycloak \
    --from-literal=password="$(tofu output -raw pg_keycloak_password)"

kubectl create secret generic gitlab-postgresql-secret -n gitlab \
    --from-literal=password="$(tofu output -raw pg_gitlab_password)"

kubectl create secret generic gitlab-redis-secret -n gitlab \
    --from-literal=password="$(tofu output -raw redis_primary_access_key)"

kubectl create secret generic gitlab-azure-storage-secret -n gitlab \
    --from-literal=account-name="$(tofu output -raw storage_account_name)" \
    --from-literal=account-key="$(tofu output -raw storage_primary_access_key)"
```

## TLS Certificates

cert-manager automatically provisions Let's Encrypt certificates. For initial testing, use the staging issuer to avoid rate limits:

```yaml
# In config.yaml
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
kubectl get svc -n ingress-nginx -w
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
