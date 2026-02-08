# UpCloud Kubernetes Production Setup Guide

This guide walks you through deploying to UpCloud Managed Kubernetes with automatic Let's Encrypt TLS certificates.

## Prerequisites

- **UpCloud account** with Managed Kubernetes cluster created
- **kubectl** configured with UpCloud cluster credentials
- **helm** installed
- **Domain name** you control (for DNS configuration)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Internet                              │
│                           │                                  │
│                           ▼                                  │
│               ┌───────────────────┐                         │
│               │  app.yourdomain.com                         │
│               │  api.yourdomain.com                         │
│               │      (DNS A records)                        │
│               └───────────┬───────┘                         │
│                           │                                  │
│                           ▼                                  │
│  ┌─────────────────────────────────────────────────────────┐│
│  │               UpCloud Managed Kubernetes                 ││
│  │                                                          ││
│  │  ┌──────────────────────────────────────────────────┐   ││
│  │  │              LoadBalancer (UpCloud)               │   ││
│  │  │                   External IP                     │   ││
│  │  └────────────────────┬─────────────────────────────┘   ││
│  │                       │                                  ││
│  │  ┌────────────────────▼─────────────────────────────┐   ││
│  │  │              nginx-ingress controller             │   ││
│  │  │          (TLS termination with cert-manager)      │   ││
│  │  └────────────────────┬─────────────────────────────┘   ││
│  │                       │                                  ││
│  │         ┌─────────────┴─────────────┐                   ││
│  │         │                           │                    ││
│  │  ┌──────▼──────┐           ┌───────▼───────┐           ││
│  │  │  frontend   │           │     api       │           ││
│  │  │  service    │           │   service     │           ││
│  │  └─────────────┘           └───────────────┘           ││
│  │                                                          ││
│  │  ┌───────────────────────────────────────────────────┐  ││
│  │  │                   cert-manager                     │  ││
│  │  │  (auto-issues Let's Encrypt certificates)         │  ││
│  │  └───────────────────────────────────────────────────┘  ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

## Step-by-Step Setup

### Step 1: Get UpCloud Kubernetes Credentials

1. Log in to UpCloud Control Panel
2. Go to your Managed Kubernetes cluster
3. Download the kubeconfig file
4. Configure kubectl:

```bash
export KUBECONFIG=/path/to/downloaded-kubeconfig.yaml
# Or merge with existing config
```

5. Verify connection:
```bash
kubectl cluster-info
kubectl get nodes
```

### Step 2: Configure Your Domains

Edit [overlays/upcloud/ingress.yaml](../overlays/upcloud/ingress.yaml):

```yaml
spec:
  tls:
    - hosts:
        - app.yourdomain.com  # ← Change this
        - api.yourdomain.com  # ← Change this
      secretName: tshub-tls-secret
  rules:
    - host: app.yourdomain.com  # ← Change this
      # ...
    - host: api.yourdomain.com  # ← Change this
      # ...
```

### Step 3: Configure cert-manager Email

Edit [overlays/upcloud/cert-manager/cluster-issuer.yaml](../overlays/upcloud/cert-manager/cluster-issuer.yaml):

```yaml
spec:
  acme:
    email: your-actual-email@example.com  # ← Change this
```

This email receives certificate expiry notifications from Let's Encrypt.

### Step 4: Run Cluster Setup

```bash
cd k8s/scripts/upcloud
./setup-cluster.sh
```

This:
- Installs cert-manager for automatic TLS certificates
- Installs nginx-ingress controller
- Creates ClusterIssuers for Let's Encrypt (staging and production)
- Creates the application namespace

### Step 5: Configure DNS

After setup, you'll see the LoadBalancer external IP:
```
LoadBalancer external IP: 94.xxx.xxx.xxx
```

Create DNS A records pointing your domains to this IP:
```
app.yourdomain.com  A  94.xxx.xxx.xxx
api.yourdomain.com  A  94.xxx.xxx.xxx
```

Wait for DNS propagation (can take up to 24 hours, usually minutes).

Verify:
```bash
dig app.yourdomain.com +short
```

### Step 6: Deploy Services

```bash
cd k8s/scripts/upcloud
./deploy.sh
```

### Step 7: Verify Certificate Issuance

cert-manager will automatically request a Let's Encrypt certificate:

```bash
# Check certificate status
kubectl get certificate -n tshub

# Check certificate details
kubectl describe certificate -n tshub

# Check cert-manager logs if issues
kubectl logs -n cert-manager -l app=cert-manager
```

## Production Considerations

### Use Staging First

For initial testing, use the staging ClusterIssuer to avoid Let's Encrypt rate limits:

In your ingress, change:
```yaml
annotations:
  cert-manager.io/cluster-issuer: "letsencrypt-staging"  # for testing
```

Staging certificates are NOT trusted by browsers but have no rate limits.

Once verified working, switch to:
```yaml
annotations:
  cert-manager.io/cluster-issuer: "letsencrypt-prod"  # for production
```

### Resource Limits

Update resource requests/limits in your deployments for production workloads.

### Monitoring

Consider adding:
- Prometheus for metrics
- Grafana for dashboards
- Loki for log aggregation

### Secrets Management

For production secrets:
- Use External Secrets Operator with UpCloud or cloud secret managers
- Or use Sealed Secrets for GitOps

## Troubleshooting

### Certificate not issuing

1. Check cert-manager logs:
```bash
kubectl logs -n cert-manager deploy/cert-manager
```

2. Check certificate request:
```bash
kubectl get certificaterequest -n tshub
kubectl describe certificaterequest -n tshub
```

3. Check challenges:
```bash
kubectl get challenges -n tshub
kubectl describe challenges -n tshub
```

Common issues:
- DNS not pointing to LoadBalancer IP
- ClusterIssuer email not configured
- Rate limited (use staging issuer)

### 502 Bad Gateway

1. Check if pods are running:
```bash
kubectl get pods -n tshub
```

2. Check service endpoints:
```bash
kubectl get endpoints -n tshub
```

3. Check ingress controller logs:
```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller
```

### LoadBalancer stuck in Pending

UpCloud may take a few minutes to provision the LoadBalancer. If it stays pending:

1. Check UpCloud quota limits
2. Verify the cluster has the cloud-controller-manager running

```bash
kubectl get svc -n ingress-nginx -w
```

## Updating Certificates

cert-manager automatically renews certificates before expiry.

To force renewal:
```bash
kubectl delete secret tshub-tls-secret -n tshub
```

cert-manager will detect the missing secret and request a new certificate.

## Multiple Environments

For staging/production environments, create additional overlays:

```
overlays/
├── upcloud-staging/
│   ├── kustomization.yaml
│   └── ingress.yaml (staging.yourdomain.com)
└── upcloud-production/
    ├── kustomization.yaml
    └── ingress.yaml (app.yourdomain.com)
```
