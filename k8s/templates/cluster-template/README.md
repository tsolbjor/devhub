# Cluster Template

Starter template for teams that need their own workload cluster and data services provisioned via Crossplane, plus an application deployed by ArgoCD.

## Usage

1. Create a new repo in GitLab under the `tshub` group
2. Copy this template into the repo root
3. Replace placeholders:
   - `CLUSTER_NAME` — name for the workload cluster (e.g., `team-alpha`)
   - `TEAM_NAME` — team identifier, used for namespacing and labeling
   - `APP_NAME` — application name (e.g., `my-service`)
   - `DOMAIN` — cluster domain
4. Push to GitLab

ArgoCD auto-discovers the repo via two ApplicationSets:
- **`gitlab-infrastructure`** — detects `infrastructure/` and applies Crossplane CRs to the management cluster
- **`gitlab-workloads`** — detects `k8s/` and deploys your app manifests

## Directory Structure

```
infrastructure/
  cluster.yaml        # Crossplane UpCloud K8s cluster
  data-services.yaml  # Crossplane PostgreSQL + Valkey + Object Storage
k8s/
  deployment.yaml     # Main workload
  service.yaml        # ClusterIP service
  ingress.yaml        # nginx-ingress rule
.gitlab-ci.yml        # CI pipeline
```

## Notes

- `infrastructure/` CRs are applied to the management cluster where Crossplane runs.
- The Crossplane CRD API groups used here are based on the UpCloud provider conventions.
  After the provider is installed, verify actual CRDs: `kubectl get crds | grep upcloud`
- The `upcloud-api-credentials` Secret must exist in `crossplane-system` for provisioning to work.
