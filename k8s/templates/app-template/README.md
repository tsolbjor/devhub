# App Template

Starter template for application repos that deploy to the tshub platform via ArgoCD.

## Usage

1. Create a new repo in GitLab under the `tshub` group
2. Copy this template into the repo root
3. Replace placeholders:
   - `APP_NAME` — your application name (e.g., `my-service`)
   - `DOMAIN` — cluster domain (e.g., `localhost` for local, your domain for UpCloud)
4. Push to GitLab

ArgoCD will auto-discover the repo within ~3 minutes (via the `gitlab-workloads` ApplicationSet) and create an Application deploying from the `k8s/` directory.

## Directory Structure

```
k8s/
  deployment.yaml   # Main workload
  service.yaml      # ClusterIP service
  ingress.yaml      # nginx-ingress rule
.gitlab-ci.yml      # CI pipeline (build + push image)
```

## Notes

- The `k8s/` directory is what ArgoCD watches. All K8s manifests go here.
- The namespace `tshub-APP_NAME` is created automatically by ArgoCD (`CreateNamespace=true`).
- Ingress uses `ingressClassName: nginx` — consistent with the platform.
