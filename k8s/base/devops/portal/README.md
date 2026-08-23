# Portal — the platform's developer wizard

A small internal-developer-platform front door, three views behind one nav:

- **New application** — the wizard: one form turns "I need a new service" into
  everything the platform already knows how to run
- **Your applications** — the signed-in user's admin repos, with deprovisioning
- **Add-ons** — optional organisation-wide features (dependency-update bot, …),
  enabled and disabled as git operations (see `k8s/docs/ADDONS.md`)

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

## Deprovisioning

The portal is growing into an orchestrator of curated platform actions;
scaffolding is one, deprovisioning is the second. The signed-in user (the
gateway forwards the Keycloak access token — `forwardAccessToken` on the
SecurityPolicy) sees a "Your applications" list: every `devhub`-org repo they
hold **admin** on. Scaffolding records this automatically — the creator is
added as repository admin — and any admin a repo gains later may deprovision
it too. Deleting stays git-shaped: the portal deletes the *repository*, the
ApplicationSets stop generating the Application, ArgoCD prunes the workloads.

What survives, on purpose (the undo window): the `devhub-*` namespace and its
volumes — swept by `deploy.sh --env <env> cleanup-apps` (dry-run; add `apply`)
or `deploy-workload.sh --env <env> cleanup-apps [apply]` on workload clusters
— plus the container images under the org's packages, and Velero backups
until retention expires.

## Add-ons

The third curated action. A template repo named `addon-*` in
`devhub-templates` is offered on the Add-ons view instead of the wizard's
template picker; enabling it copies the template into the `devhub` org under
the same name, so `forgejo-appset` deploys it to every registered workload
cluster like any app — Kyverno guardrails included. The enabling user becomes
repository admin (that authorises disabling), the template's `SETUP.md` is
opened as an issue carrying the remaining manual steps, and CI is only
activated when the template ships a `.woodpecker.yml` — most add-ons run a
stock upstream image. Disable = the same repo deletion as deprovisioning.
The `addon-` name prefix is reserved: the wizard rejects it for apps.
Convention, authoring guide and the retrofit story for handed-over
environments: `k8s/docs/ADDONS.md`.

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

## CI secrets: `ci-secrets` (automatic)

Woodpecker mints user API tokens only for a signed-in browser session — so
`ci-secrets` signs in: with no `WOODPECKER_TOKEN` provided it drives the SSO
chain (Keycloak → Forgejo → Woodpecker) headlessly as platform-admin with the
e2e suite's Playwright and asks Woodpecker's own token endpoint
(`mint-woodpecker-token.sh`). `setup-all.sh` runs it during bootstrap and
quickstart shows it as a checked step, so a fresh environment gets
scaffold-time repo activation with no manual step.

```bash
./deploy.sh --env <env> ci-secrets                      # mints the token itself
WOODPECKER_TOKEN=<token> ./deploy.sh --env <env> ci-secrets   # or bring your own
```

That stores the token for the portal (repo auto-activation before the scaffold
commit, so the first push already builds) and sets the org-level registry
secrets. Until it has run, activation falls back to a starter issue.
