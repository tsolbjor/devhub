# Crossplane & ApplicationSets Guide

This document covers the setup and usage of Crossplane for infrastructure provisioning and ArgoCD ApplicationSets for automatic application discovery.

## Overview

```
GitLab repo (tshub group)
├── k8s/              → ArgoCD "gitlab-workloads" ApplicationSet → deploys app
└── infrastructure/   → ArgoCD "gitlab-infrastructure" ApplicationSet → Crossplane CRs
                           → Crossplane provisions UpCloud resources
```

## Prerequisites

### 1. UpCloud API Credentials (Crossplane)

Create the Secret that the Crossplane UpCloud provider uses to authenticate:

```bash
kubectl create secret generic upcloud-api-credentials \
  -n crossplane-system \
  --from-literal=credentials='{"username":"YOUR_UPCLOUD_USERNAME","password":"YOUR_UPCLOUD_PASSWORD"}'
```

### 2. GitLab SCM Token (ApplicationSets)

Create a GitLab Personal Access Token (PAT) with `read_api` scope, then store it as a Secret:

```bash
kubectl create secret generic argocd-gitlab-scm-token \
  -n argocd \
  --from-literal=token=YOUR_GITLAB_PAT
```

The token must have access to the `tshub` group in GitLab.

## Deploying Crossplane

Crossplane is deployed as part of the full platform deployment:

```bash
./deploy.sh --env local          # full deploy (includes Crossplane)
./deploy.sh --env local crossplane  # deploy Crossplane only
```

This installs:
1. Crossplane core (Helm chart in `crossplane-system` namespace)
2. UpCloud Provider CR (pulls the provider image)
3. ProviderConfig (if `upcloud-api-credentials` Secret exists)

## Bootstrapping ApplicationSets

After ArgoCD is deployed, bootstrap the app-of-apps:

```bash
./deploy.sh --env local bootstrap
```

This applies:
- All ArgoCD Projects (`k8s/argocd/projects/*.yaml`): `tshub`, `workloads`, `infrastructure`
- The app-of-apps Application, which auto-discovers:
  - `gitlab-appset.yaml` — workloads ApplicationSet
  - `infra-appset.yaml` — infrastructure ApplicationSet

## Using the Templates

### App-only Template

For teams that just need to deploy an application:

1. Create a repo in GitLab under `tshub/` group
2. Copy contents of `k8s/templates/app-template/` into the repo
3. Replace `APP_NAME` and `DOMAIN` placeholders
4. Push — ArgoCD creates `workload-<reponame>` Application within ~3 minutes

### Cluster + Infrastructure Template

For teams that need their own cluster and data services:

1. Create a repo in GitLab under `tshub/` group
2. Copy contents of `k8s/templates/cluster-template/` into the repo
3. Replace `CLUSTER_NAME`, `TEAM_NAME`, `APP_NAME`, and `DOMAIN` placeholders
4. Push — ArgoCD creates:
   - `infra-<reponame>` Application (provisions UpCloud resources via Crossplane)
   - `workload-<reponame>` Application (deploys K8s manifests)

## Verification

### Crossplane

```bash
# Check Crossplane pods
kubectl get pods -n crossplane-system

# Check provider status
kubectl get providers

# Check provider health
kubectl get provider provider-upcloud -o jsonpath='{.status.conditions}'

# List available CRDs after provider install
kubectl get crds | grep upcloud
```

### ApplicationSets

```bash
# Check ApplicationSets exist
kubectl get applicationsets -n argocd

# Check generated Applications
kubectl get applications -n argocd

# Watch for new apps after pushing a repo
kubectl get applications -n argocd -w
```

### End-to-End Test

1. Create a test repo in GitLab:
   ```bash
   # In GitLab UI or via API, create tshub/test-app
   ```
2. Add a `k8s/` directory with a simple deployment
3. Wait ~3 minutes for ArgoCD to discover it
4. Verify:
   ```bash
   kubectl get application workload-test-app -n argocd
   kubectl get pods -n tshub-test-app
   ```

## Troubleshooting

### ApplicationSet not discovering repos

- Verify the `argocd-gitlab-scm-token` Secret exists: `kubectl get secret argocd-gitlab-scm-token -n argocd`
- Check ApplicationSet controller logs: `kubectl logs -l app.kubernetes.io/name=argocd-applicationset-controller -n argocd`
- Ensure the GitLab PAT has `read_api` scope and access to the `tshub` group

### Crossplane provider not becoming healthy

- Check provider pod logs: `kubectl logs -l pkg.crossplane.io/revision -n crossplane-system`
- Verify the provider image can be pulled (check for ImagePullBackOff)
- The provider may take several minutes on first install to download

### Crossplane resources stuck in provisioning

- Verify `upcloud-api-credentials` Secret exists: `kubectl get secret upcloud-api-credentials -n crossplane-system`
- Check the managed resource status: `kubectl describe <resource-kind> <resource-name>`
- Ensure the ProviderConfig was applied: `kubectl get providerconfig`
