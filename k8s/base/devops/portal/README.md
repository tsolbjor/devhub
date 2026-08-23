# Portal — the platform's developer wizard

A small internal-developer-platform front door: one form that turns "I need a
new service" into everything the platform already knows how to run.

## What one wizard run produces

| Step | Mechanism |
|------|-----------|
| Name validation | live in the form (`/api/validate-name`): DNS-1123 label, not one of the platform's own hostnames (`grafana`, `vault`, …; extend via `RESERVED_NAMES`), not an already-taken repo |
| Git repository | Forgejo API, copied from `devhub-templates/app-template` with `APP_NAME`/`DOMAIN`/`POSTGRES_ENABLED`/`REDIS_ENABLED` substituted. The repo carries **one** deployment file, `k8s/values.yaml` — the manifests live in the `devhub-app` chart |
| CI pipeline | `.woodpecker.yml` ships in the template; the portal activates the repo in Woodpecker **before the first commit** when it holds a token (see `ci-secrets` below), so the scaffold commit itself builds and publishes the first image. Otherwise activation is a starter issue |
| Registry credentials | none per repo — `deploy.sh <env> ci-secrets` sets `registry_user`/`registry_token` as Woodpecker **org** secrets (push events only, so PR builds from untrusted code cannot read them) |
| Container publishing | the template's rootless BuildKit pipeline pushes to Forgejo's registry |
| Deployment | nothing to do — the chart-based ApplicationSet (`forgejo-workloads-chart`) renders every `devhub`-org repo's `k8s/values.yaml` through `devhub-templates/devhub-app-chart` on each registered workload cluster; repos with raw `k8s/` manifests keep the original `forgejo-workloads` set |
| Routing + TLS | nothing to do — the workload gateway's wildcard `apps` listener, external-dns (records from HTTPRoutes) and the DNS-01 wildcard certificate already exist |
| Namespace guardrails | nothing to do — Kyverno generates quota, LimitRange and NetworkPolicies for each `devhub-*` namespace |
| Work items | starter issues via the Forgejo API, grouped under a "Getting started" milestone. A kanban board stays a starter issue: Forgejo has no Projects API yet (forgejo/forgejo#5330) |
| Data services (optional) | `postgres.enabled` / `redis.enabled` in `values.yaml`; the chart runs the dev-grade instance and injects `POSTGRES_*`/`REDIS_*` env vars into the app container; passwords come from an in-cluster ESO `Password` generator, never git |

## Design rules

- **The portal writes git, never the cluster.** It holds one Forgejo token and
  no Kubernetes RBAC. Every provision is a commit: auditable, revertable,
  carried by the push mirror.
- **Templates live in their own org** (`devhub-templates`), because
  `forgejo-appset` deploys every `devhub`-org repo that has `k8s/` — a template
  must never itself land on a workload cluster. `deploy.sh` publishes every
  directory under `k8s/templates/` there (`./deploy.sh --env <env>
  portal-templates`): the scaffolds, and the `devhub-app` chart their
  `values.yaml` renders through. Repos named `*-chart` are hidden from the
  wizard's template picker.
- **Authentication is the gateway's** — same pattern as Homepage: an Envoy
  Gateway `SecurityPolicy` runs the Keycloak OIDC flow, and the NetworkPolicy
  admits only the gateway namespace.
- **No image build.** The app is ~300 lines of dependency-free Node served from
  a ConfigMap on a stock `node:22-alpine` image, so it installs before the
  platform's own registry and CI exist. If it ever outgrows that, it becomes a
  normal built image — scaffolded, fittingly, by itself.

## Lifecycle

`deploy.sh --env <env> portal` installs it imperatively (and seeds the Forgejo
token + template org). After the GitOps handover, `k8s/argocd/apps/portal.yaml`
makes ArgoCD own it from the environment's own repository, like every other
non-bootstrap component.

Republishing after editing anything under `k8s/templates/` (the app template
or the devhub-app chart) is `deploy.sh --env <env> portal-templates` — a
force-push of a fresh single-commit tree per directory, so the Forgejo copy is
exactly this repository's. Teams that prefer to evolve them in Forgejo directly
(the portal and the chart ApplicationSet both read HEAD) just stop re-running
it. Republishing the chart is a fleet-wide change: every chart-based app
renders through HEAD on its next sync.

## The one manual step: `ci-secrets`

Woodpecker mints user API tokens only in its UI. Once per environment:

```bash
# token from https://ci.<domain>/user
WOODPECKER_TOKEN=<token> ./deploy.sh --env <env> ci-secrets
```

That stores the token for the portal (repo auto-activation at scaffold time)
and sets the org-level registry secrets. Everything the wizard does is fully
automatic from then on. Without it, activation and the registry secrets fall
back to starter issues.
