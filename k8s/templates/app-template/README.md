# App Template

Starter template for application repositories that deploy to the DevHub platform
via ArgoCD.

Includes a minimal .NET 8 API, a multi-stage Dockerfile, a Woodpecker CI pipeline
that builds the image with rootless BuildKit and publishes it to Forgejo's
container registry — and exactly **one** deployment file: `k8s/values.yaml`.

The manifests live in the platform's `devhub-app` chart
(`devhub-templates/devhub-app-chart`); this repository only states what is
app-specific: name, hostname, port, image, and whether it wants PostgreSQL or
Redis. Commit to `main` → CI builds and publishes the container, bumps the image
tag in `values.yaml`, and ArgoCD deploys it to every registered workload cluster
at `https://APP_NAME.<domain>`.

## Usage

The portal (`https://portal.<domain>`) scaffolds all of this for you — repo,
CI activation, work items. By hand:

1. Create a repository in Forgejo under the `devhub` organisation
2. Copy this template into the repository root
3. Replace the placeholders (a global, literal string swap over every file name
   and file content — see `TEMPLATE-AUTHORING.md` in the platform repo's
   `k8s/templates/`, and treat all four as reserved words if you edit this
   template):
   - `APP_NAME` — your application name (e.g. `my-service`)
   - `DOMAIN` — the platform domain (`localhost` locally, your domain otherwise)
   - `POSTGRES_ENABLED` / `REDIS_ENABLED` — `true` or `false`
4. Enable the repository in Woodpecker (`https://ci.<domain>`). Registry
   credentials are devhub org-level secrets — nothing to add per repo
5. Push

ArgoCD discovers the repository within a few minutes (the chart-based
ApplicationSet scans the `devhub` organisation for repos containing
`k8s/values.yaml`) and deploys it to the workload cluster, in namespace
`devhub-APP_NAME`.

## Directory structure

```
Dockerfile          # Multi-stage build (dotnet SDK → ASP.NET runtime Alpine)
Program.cs          # Minimal API with health endpoints
APP_NAME.csproj     # .NET 8 project file (rename to match your app)
appsettings.json    # Logging configuration
k8s/
  values.yaml       # The whole deployment: name, host, port, image, data services
.woodpecker.yml     # CI: lint → test → build → deploy
```

## CI pipeline

| Step | What it does |
|------|--------------|
| **lint** | Renders `k8s/values.yaml` through the platform's devhub-app chart — a broken values file fails before anything deploys |
| **test** | `dotnet test` |
| **build** | Rootless BuildKit build; pushes to `git.<domain>/devhub/APP_NAME` on the default branch, build-only on pull requests |
| **deploy** | Commits the new image tag into `k8s/values.yaml` so ArgoCD syncs it |

Every step runs as an unprivileged pod on the platform's tainted CI node pool.
There is no Docker daemon and no privileged container: a build cannot reach the
node's kubelet credentials or the cloud metadata endpoint.

The `registry_token` org secret is a repo-write Forgejo token, so it is
requested per step and only where a step cannot work without it — the **test**
step gets no credential at all. See the credential map at the top of
`.woodpecker.yml`.

Deployment is always by immutable `:$CI_COMMIT_SHA` tag; the `:latest` tag
exists only as the BuildKit cache pointer. **Rollback is `git revert` of the
`[skip ci] deploy <sha>` commit** — the older image is still in the registry, so
no rebuild is needed. That `[skip ci]` marker is load-bearing: the tag bump is
itself a push to `main`, and without it CI would trigger itself forever.

## Deployment concerns you can turn on

Both are opt-in in `k8s/values.yaml` and off by default:

- `autoscaling.enabled` — a CPU-based HPA. While on, the chart stops declaring
  `replicas` so the HPA owns the count. Keep `maxReplicas × requests` inside the
  namespace quota (4 CPU / 8 GiB)
- `initContainers` — the migration hook: runs to completion before the app
  container starts, on every pod, so you need not migrate in-process. Must be
  idempotent, concurrency-safe and backward compatible with the release still
  serving. The chart's README has a worked example

## Data services

Set `postgres.enabled: true` and/or `redis.enabled: true` in `k8s/values.yaml`.
The chart runs a dev-grade instance in this app's namespace (password generated
in-cluster, nothing committed) and injects the connection into the app container:

- PostgreSQL: `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
- Redis: `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`

Production data belongs on the managed services the platform provisions per cloud.

## Sign-in (optional)

Set `auth.enabled: true` in `k8s/values.yaml` to put the whole app behind the
platform's Keycloak sign-in — the gateway runs the OIDC flow, the app stays
auth-unaware. `auth.exceptPaths` flips the rule for specific path prefixes:
public exceptions on a protected app (`/healthz`, webhooks), or
sign-in-required exceptions on an otherwise public app (`/admin`).

## What the platform enforces

Kyverno validates every pod in `devhub-*` namespaces at admission, so these are not
suggestions:

- CPU and memory **requests and limits** on every container
- no privileged containers, no host namespaces, no privilege escalation
- images only from `git.<domain>` or an allow-listed public registry

Kyverno also generates the namespace's ResourceQuota (4 CPU / 8 GiB requests),
LimitRange and NetworkPolicies when ArgoCD creates it. The chart renders
equivalent policies so the behaviour is visible, not because it depends on them.

## Secrets

Application secrets come from Vault via External Secrets. Write them under
`secret/apps/<app-name>/` on the platform cluster, then reference them with an
`ExternalSecret` under `extraManifests` in `k8s/values.yaml` (the chart's own
registry-pull-secret template shows the shape). The workload cluster
authenticates to Vault with its own identity — no static tokens.

## Routing

The chart's HTTPRoute attaches to the platform Gateway's wildcard `apps`
listener, so `APP_NAME.<domain>` works without any platform-side change. TLS is
terminated by the Gateway using a wildcard certificate; the app itself only ever
speaks plain HTTP on `app.port`.

## Escape hatch

Outgrown the chart? Two levels:

1. `extraManifests:` in `values.yaml` — additional resources rendered verbatim
2. Eject: delete `k8s/values.yaml`, commit raw manifests to `k8s/` — the raw
   ApplicationSet deploys the directory as-is and the chart is out of the picture
