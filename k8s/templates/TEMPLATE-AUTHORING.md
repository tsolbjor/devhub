# Authoring a portal template

Everything in this directory is published to the platform's Forgejo
`devhub-templates` org by `deploy.sh --env <env> portal-templates` (a force-push
of a fresh tree — the org is a mirror of this directory, not a place to edit).
From there:

| Directory                | What it is |
|--------------------------|------------|
| `app-template/`          | the default scaffold the portal wizard copies for a new app |
| `addon-*/`               | a platform add-on, enabled org-wide from the portal's Add-ons view (see `k8s/docs/ADDONS.md`) |
| `devhub-app-chart/`      | the chart every scaffolded app renders *through* — not a scaffold source |

A new scaffolding template is just a new directory here: the portal offers every
`devhub-templates` repo that is neither `*-chart` nor `addon-*` as a choice in
the wizard.

## Reserved literals

When the portal copies a template it performs a **global, literal string
replacement** over every file — both file *contents* and file *paths*. There is
no word-boundary check, no escaping mechanism and no way to opt a file out.

| Literal            | Replaced with |
|--------------------|---------------|
| `APP_NAME`         | the app name the user typed (a DNS label, e.g. `my-service`) |
| `DOMAIN`           | the platform domain (e.g. `example.com`, or `localhost`) |
| `POSTGRES_ENABLED` | `true` / `false` — the wizard's PostgreSQL checkbox |
| `REDIS_ENABLED`    | `true` / `false` — the wizard's Redis checkbox |

`APP_NAME` is substituted before `DOMAIN`, which is what makes the idiom
`APP_NAME.DOMAIN` resolve to `my-service.example.com`.

**Treat all four as reserved words.** They are replaced everywhere, including
places you did not mean:

- prose in a `README.md` — "set the DOMAIN of your service" becomes "set the
  example.com of your service"
- source code — a C# constant `APP_NAME`, a shell `$DOMAIN`, an env var named
  `DOMAIN` in a `docker-compose.yml`
- CI files, comments, JSON keys, test fixtures
- a file *named* `DOMAIN.md`

In prose write "the platform domain", "the app's name", "your service name"
instead. In code pick any other identifier (`AppDomain`, `SERVICE_DOMAIN`,
`APPNAME`) — the match is literal and case-sensitive, so a different casing is
already safe.

If a template genuinely needs to ship the literal text `DOMAIN` (documentation
about this very mechanism, for instance), it cannot: split it, spell it
differently, or keep that document outside the template.

The substitution lives in `substitute()` in
`k8s/base/devops/portal/server.js`, which carries the same warning.

## Optional files

Paths under `optional/` are copied only when the wizard asked for the matching
data service, and land at a new path:

| Template path            | Copied to        | When |
|--------------------------|------------------|------|
| `optional/postgres.yaml` | `k8s/postgres.yaml` | the user ticked PostgreSQL |
| `optional/redis.yaml`    | `k8s/redis.yaml`    | the user ticked Redis |

Anything else under `optional/` is never copied at all — it is a way to keep
files in the template that must not reach a scaffolded repo.

`app-template` does **not** use this mechanism: it deploys through the
`devhub-app` chart, where data services are the `postgres.enabled` /
`redis.enabled` flags in `k8s/values.yaml` (hence the `POSTGRES_ENABLED` /
`REDIS_ENABLED` literals). `optional/` remains for raw-manifest templates that
have no chart to carry the flag.

## What makes a template deployable

The portal writes git and nothing else; deployment is existing convention:

- the repo lands in the `devhub` org → the `forgejo-appset` ApplicationSet picks
  it up for every cluster labelled `devhub.io/role=workload`
- it contains `k8s/values.yaml` → rendered through `devhub-app-chart`
- it contains a raw `k8s/` directory instead → deployed as-is
- it contains `.woodpecker.yml` → the portal activates the repo in Woodpecker
  *before* the first commit, so the scaffold's own first push builds. A template
  with no pipeline (deploying a stock upstream image) is simply never activated
- its namespace is `devhub-<name>` → Kyverno generates the quota, LimitRange and
  NetworkPolicies, and enforces resource limits, non-root and the registry
  allow-list

So a template needs no registration anywhere. Add the directory, republish, and
it appears in the wizard.

## Checklist

- [ ] no accidental use of `APP_NAME`, `DOMAIN`, `POSTGRES_ENABLED`,
      `REDIS_ENABLED` in prose or code
- [ ] `k8s/values.yaml` (chart-based) or a raw `k8s/` directory, not both
- [ ] every image comes from a Kyverno-allow-listed registry: `git.<domain>`,
      `ghcr.io`, `quay.io`, `docker.io/library`, `registry.k8s.io`
- [ ] every container declares CPU and memory requests *and* limits, runs
      non-root, and does not need privilege escalation
- [ ] no secrets in the tree — the portal's publish path scans for credentials,
      and app secrets belong in Vault (`secret/apps/<app>/`) via External Secrets
- [ ] `helm template <name> devhub-app-chart -f k8s/values.yaml` renders (the
      scaffolded repo's own `lint` CI step does exactly this)
- [ ] build artefacts are gitignored, not committed
