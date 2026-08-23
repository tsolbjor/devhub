# Platform add-ons

Optional, organisation-wide features — a dependency-update bot, an AI pull
request reviewer, anything that serves every application rather than one —
delivered through the machinery the platform already has, not new machinery.

## The convention

An add-on is a template repository named `addon-<name>` in the
`devhub-templates` org. Its source of truth in this repository is a directory
`k8s/templates/addon-<name>/`, published (like every template) by:

```bash
./deploy.sh --env <env> portal-templates
```

The portal's **Add-ons** view lists every `addon-*` template. Enabling one
copies it into the `devhub` org under the same name — and from there, existing
conventions do all the work:

| Convention | What it gives the add-on |
|---|---|
| `forgejo-appset` | deployment to every registered workload cluster (raw `k8s/` manifests, or `k8s/values.yaml` through the devhub-app chart) |
| Kyverno namespace generation | quota, LimitRange, NetworkPolicies for `devhub-addon-<name>` |
| ClusterSecretStore `vault-backend` | secrets from Vault `secret/apps/addon-<name>` via ExternalSecret |
| Registry allow-list | stock upstream images from `ghcr.io`, `quay.io`, `docker.io/library`, `registry.k8s.io` |
| Portal deprovision path | disable = delete the repo; ArgoCD prunes the workloads |

The portal stays git-only: enable is a repository creation plus one commit,
disable is a repository deletion. It never touches the cluster.

## Writing an add-on

1. Create `k8s/templates/addon-<name>/` with:
   - `README.md` — what it is and how it deploys
   - `SETUP.md` — the manual steps a human still owes (tokens into Vault,
     upstream accounts). The portal opens this file as an issue on the enabled
     repository, so write it as a checklist someone can follow and close.
   - `k8s/` — raw manifests (or a `k8s/values.yaml` for chart-shaped add-ons).
     No `metadata.namespace`: ArgoCD deploys into `devhub-addon-<name>`.
2. The scaffold substitution applies: the literal tokens `APP_NAME` and
   `DOMAIN` are replaced on enable (`APP_NAME` becomes `addon-<name>`).
   Add-ons have no wizard options, so `optional/` files never ship and
   `POSTGRES_ENABLED`/`REDIS_ENABLED` substitute to `false`.
3. Add a one-line description in `deploy.sh`'s `publish_app_templates` case
   table — the portal catalog shows it.
4. Constraints the manifests must meet (Kyverno enforces them):
   - every container has CPU/memory requests **and** limits
   - images come from the platform registry or the allow-listed public ones
   - no privileged containers
5. Ship a `.woodpecker.yml` only if the add-on builds its own image; the
   portal activates CI on enable only when that file exists. Most add-ons run
   a stock upstream image and need no pipeline.
6. Add coverage: the portal e2e spec asserts the catalog renders; an add-on
   with its own surface deserves its own read-only assertions.

Things an add-on can rely on: egress to the internet (minus the cloud metadata
endpoint), DNS, and the platform's public hostnames (`git.<domain>` etc.).
Things it cannot: platform-cluster Service URLs (it runs on workload
clusters), cluster RBAC beyond its namespace, and Vault paths outside
`apps/*`.

Add-ons that genuinely need platform privileges (gateway listeners, cluster
RBAC, webhooks into ArgoCD) are not add-ons — they are platform components:
base values + overlay values + `platform-appset.yaml` entry, as in CLAUDE.md.

## Existing environments (after gitops handover)

A generated environment repo has no upstream to pull from — that is by design
(see the Lifecycle section of CLAUDE.md). Adopting an add-on there is still
cheap, because add-ons live *behind* the handover boundary:

1. Copy `k8s/templates/addon-<name>/` from a current devhub checkout into the
   environment repo's `k8s/templates/`
2. Run `./deploy.sh --env <env> portal-templates` there to publish it
3. Enable it in the portal

To see everything a newer devhub would generate differently, stage a fresh
tree and diff it against the environment repo:

```bash
./devhub gitops-repo --env <env> --stage-only /tmp/fresh
```

Merging what you want from that diff is manual and stays manual — there is no
supported in-place upgrade.

## Shipped add-ons

| Add-on | What it does | Manual setup |
|---|---|---|
| `addon-renovate` | Renovate bot: dependency-update PRs for every `devhub`-org repo, daily | one Forgejo token into Vault (`secret/apps/addon-renovate`) |
