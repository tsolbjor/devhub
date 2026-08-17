# App Template

Starter template for application repositories that deploy to the DevHub platform
via ArgoCD.

Includes a minimal .NET 8 API, a multi-stage Dockerfile, Kubernetes manifests, and
a Woodpecker CI pipeline that builds the image with rootless BuildKit and publishes
it to Forgejo's container registry.

## Usage

1. Create a repository in Forgejo under the `devhub` organisation
2. Copy this template into the repository root
3. Replace the placeholders:
   - `APP_NAME` — your application name (e.g. `my-service`)
   - `DOMAIN` — the platform domain (`localhost` locally, your domain otherwise)
4. In Woodpecker (`https://ci.<domain>`), enable the repository and add two secrets:
   - `registry_user` / `registry_token` — a Forgejo token with `write:package`
5. Push

ArgoCD discovers the repository within a few minutes (the `forgejo-workloads`
ApplicationSet scans the `devhub` organisation for repos containing `k8s/`) and
creates an Application that deploys from the `k8s/` directory to the workload
cluster, in namespace `devhub-APP_NAME`.

## Directory structure

```
Dockerfile          # Multi-stage build (dotnet SDK → ASP.NET runtime Alpine)
Program.cs          # Minimal API with health endpoints
APP_NAME.csproj     # .NET 8 project file (rename to match your app)
appsettings.json    # Logging configuration
k8s/
  deployment.yaml            # Main workload: port 8080, health probes, hardened securityContext
  service.yaml               # ClusterIP service
  httproute.yaml             # Gateway API route (replaces Ingress)
  registry-pull-secret.yaml  # ExternalSecret pulling registry credentials from Vault
  networkpolicy.yaml         # Baseline isolation for the namespace
  poddisruptionbudget.yaml   # Keeps one replica during drains
.woodpecker.yml     # CI: lint → test → build → deploy
```

## CI pipeline

| Step | What it does |
|------|--------------|
| **lint-manifests** | `kubectl apply --dry-run=client` over `k8s/` |
| **test** | `dotnet test` |
| **build** | Rootless BuildKit build; pushes to `git.<domain>/devhub/APP_NAME` on the default branch, build-only on pull requests |
| **deploy** | Commits the new image tag into `k8s/deployment.yaml` so ArgoCD syncs it |

Every step runs as an unprivileged pod on the platform's tainted CI node pool.
There is no Docker daemon and no privileged container: a build cannot reach the
node's kubelet credentials or the cloud metadata endpoint.

## What the platform enforces

Kyverno validates every pod in `devhub-*` namespaces at admission, so these are not
suggestions:

- CPU and memory **requests and limits** on every container
- no privileged containers, no host namespaces, no privilege escalation
- images only from `git.<domain>` or an allow-listed public registry

Kyverno also generates the namespace's ResourceQuota (4 CPU / 8 GiB requests),
LimitRange and NetworkPolicies when ArgoCD creates it — the copies in `k8s/` are
there so the behaviour is visible in your repository, not because it depends on them.

## Secrets

Application secrets come from Vault via External Secrets. Write them under
`secret/apps/<app-name>/` on the platform cluster, then reference them with an
`ExternalSecret` (see `k8s/registry-pull-secret.yaml` for the shape). The workload
cluster authenticates to Vault with its own identity — no static tokens.

## Routing

`k8s/httproute.yaml` attaches to the platform Gateway's wildcard `apps` listener,
so `APP_NAME.<domain>` works without any platform-side change. TLS is terminated by
the Gateway using a wildcard certificate.
