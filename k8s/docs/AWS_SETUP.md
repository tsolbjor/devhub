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
nginx-ingress (TLS via cert-manager / Let's Encrypt)
    |
    +---> Keycloak (SSO)
    +---> GitLab (source control, CI/CD)
    +---> ArgoCD (GitOps)
    +---> Grafana / Prometheus (monitoring)
    +---> Vault (secrets)
    |
    v (private VPC subnets)
    +---> Amazon RDS PostgreSQL (Keycloak DB, GitLab DB)
    +---> Amazon ElastiCache Redis (GitLab cache/sessions)
    +---> Amazon S3 (GitLab artifacts, registry, backups)
```

## Step-by-Step Setup

### Step 1: Provision Infrastructure with OpenTofu

```bash
# Configure AWS credentials
export AWS_REGION=us-east-1  # or your preferred region
aws configure

# For dev environment:
cd tofu/aws/dev
tofu init
tofu plan     # Review what will be created
tofu apply    # Provision (takes 15-20 min)

# For prod environment:
cd tofu/aws/prod
tofu init && tofu apply
```

This provisions:
- VPC with public and private subnets across multiple Availability Zones
- Managed Kubernetes cluster (EKS) with private worker nodes
- Amazon RDS PostgreSQL (databases: `keycloak`, `gitlabhq_production`)
- Amazon ElastiCache Redis cluster
- S3 buckets for GitLab artifacts, registry, uploads, and backups
- IAM roles for service accounts (IRSA) for GitLab S3 access
- Cognito User Pool for optional Keycloak federation

Review environment-specific settings in `tofu/aws/dev/main.tf` or `tofu/aws/prod/main.tf`.

### Step 2: Sync Tofu Outputs to K8s Config

```bash
cd k8s/scripts
./sync-tofu-outputs.sh --env aws-dev
```

This script:
- Reads tofu outputs (RDS endpoint, Redis endpoint, S3 buckets, etc.)
- Writes them into `k8s/overlays/aws-dev/config.yaml`
- Updates kubeconfig via `aws eks update-kubeconfig`

### Step 3: Configure Domain and Email

Edit `k8s/overlays/aws-dev/config.yaml`:

```yaml
domain: dev.yourdomain.com
acmeEmail: admin@yourdomain.com
```

### Step 4: Configure DNS

After tofu apply and deploying nginx-ingress, the EKS cluster gets a Network LoadBalancer. Find its hostname:

```bash
export KUBECONFIG=k8s/scripts/aws-dev/kubeconfig
kubectl get svc -n ingress-nginx
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

Or individual records for each service (keycloak, gitlab, argocd, grafana, etc.)

### Step 5: Deploy Platform Services

```bash
cd k8s/scripts
export KUBECONFIG=aws-dev/kubeconfig

# Deploy everything
./deploy.sh --env aws-dev

# Configure Keycloak SSO
./setup-keycloak.sh --env aws-dev

# Initialize Vault
./setup-vault.sh --env aws-dev

# Bootstrap ArgoCD GitOps
./deploy.sh --env aws-dev bootstrap
```

### Step 6: Verify

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

After deploying with managed data services, `deploy.sh` checks for required K8s secrets. Create them using tofu outputs:

```bash
cd tofu/aws/dev

# Get passwords and endpoints
tofu output rds_keycloak_password
tofu output rds_gitlab_password
tofu output redis_auth_token
tofu output s3_gitlab_artifacts_bucket
tofu output gitlab_irsa_role_arn

# Create K8s secrets (see deploy.sh configure_managed_data_services for required keys)
kubectl create secret generic keycloak-db-secret -n keycloak \
    --from-literal=password="$(tofu output -raw rds_keycloak_password)"

kubectl create secret generic gitlab-postgresql-secret -n gitlab \
    --from-literal=password="$(tofu output -raw rds_gitlab_password)"

kubectl create secret generic gitlab-redis-secret -n gitlab \
    --from-literal=password="$(tofu output -raw redis_auth_token)"
```

## IAM Roles for Service Accounts (IRSA)

GitLab uses IRSA to access S3 buckets without storing AWS credentials. The tofu module creates the necessary IAM role and OIDC provider. The role ARN is written to config.yaml by `sync-tofu-outputs.sh` and used in GitLab's Helm values.

## TLS Certificates

cert-manager automatically provisions Let's Encrypt certificates. For initial testing, use the staging issuer to avoid rate limits:

```yaml
# In config.yaml
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
kubectl get svc -n ingress-nginx -w
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
Verify that the GitLab service account is annotated with the IRSA role ARN and that the IAM role trust policy allows the OIDC provider.

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
