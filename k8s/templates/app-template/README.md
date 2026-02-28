# App Template

Starter template for application repos that deploy to the devhub platform via ArgoCD.

Includes a minimal .NET 8 API, a multi-stage Dockerfile, K8s manifests, and a GitLab CI pipeline that builds, tests, and publishes the container image to the GitLab registry.

## Usage

1. Create a new repo in GitLab under the `devhub` group
2. Copy this template into the repo root
3. Replace placeholders:
   - `APP_NAME` — your application name (e.g., `my-service`)
   - `DOMAIN` — cluster domain (e.g., `localhost` for local, your domain for UpCloud)
4. Push to GitLab

ArgoCD will auto-discover the repo within ~3 minutes (via the `gitlab-workloads` ApplicationSet) and create an Application deploying from the `k8s/` directory.

## Directory Structure

```
Dockerfile          # Multi-stage build (dotnet SDK → ASP.NET runtime Alpine)
Program.cs          # Minimal API with health endpoints
APP_NAME.csproj     # .NET 8 project file (rename to match your app)
appsettings.json    # Logging configuration
k8s/
  deployment.yaml   # Main workload (port 8080, health probes)
  service.yaml      # ClusterIP service
  ingress.yaml      # nginx-ingress rule
.gitlab-ci.yml      # CI: lint → build → test → deploy
```

## CI Pipeline

The `.gitlab-ci.yml` pipeline runs on every push:

| Stage    | What it does                                                 |
|----------|--------------------------------------------------------------|
| **lint** | `kubectl --dry-run=client` validates K8s manifests           |
| **build**| Builds the Docker image and pushes to GitLab container registry |
| **test** | Runs tests inside the built container                        |
| **deploy** | Updates the image tag in `k8s/deployment.yaml` and commits |

ArgoCD detects the manifest change and rolls out the new image automatically.

## Notes

- The `k8s/` directory is what ArgoCD watches. All K8s manifests go here.
- The namespace `devhub-APP_NAME` is created automatically by ArgoCD (`CreateNamespace=true`).
- Ingress uses `ingressClassName: nginx` — consistent with the platform.
- Rename `APP_NAME.csproj` to match your app name (must match the `ENTRYPOINT` DLL name in the Dockerfile).
- Replace the sample `Program.cs` with your own application code.
