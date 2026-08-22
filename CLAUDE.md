# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kubernetes DevOps platform with three layers:
1. **Infrastructure (OpenTofu)** — provisions K8s clusters and managed data services on UpCloud, Azure, GCP, or AWS
2. **Platform cluster (Helm/K8s + ArgoCD)** — DevOps services (Keycloak, Vault, Forgejo, Woodpecker CI, ArgoCD, Prometheus/Grafana/Loki/Tempo/Alloy, Envoy Gateway, cert-manager, External-DNS, Kyverno, Reloader, Velero, Headlamp,
   Homepage, Portal)
3. **Workload cluster** — lean K8s cluster running developer apps, managed by platform ArgoCD via ApplicationSets

Platform environments: `local` (Rancher Desktop/WSL2), `upcloud-dev`, `upcloud-prod`, `azure-dev`, `azure-prod`, `gcp-dev`, `gcp-prod`, `aws-dev`, `aws-prod`.
Workload environments: `upcloud-workload`, `azure-workload`, `gcp-workload`, `aws-workload`.

## Lifecycle: devhub is an installer, not a runtime dependency

devhub sets an environment up and then gets out of the way. The last step,
`./devhub gitops-repo --env <env>`, publishes a **standalone** copy of the
platform into that environment's own Forgejo and points its ArgoCD at it. From
then on the environment owns its own history and can diverge freely — there is no
upstream to pull from and no upgrade path back.

What follows from that:

- `setup-gitops-repo.sh` prunes as it copies: other clouds and environments are
  cut away, and the overlay's `devops/` symlink is dereferenced into real files
- the generated repo **commits** `backend.hcl` and `*.tfvars` (inverting this
  repo's `.gitignore`) — without them nobody can `tofu init` the environment
- `renovate.json` ships, so chart pins keep moving after the link is cut
- installer-only scripts (`quickstart.sh`, `setup-env.sh`, `preflight.sh`,
  `setup-gitops-repo.sh`) do not ship; `devhub` reports that rather than failing
  on a missing file
- the staged tree is scanned for credentials and key material before any commit;
  publishing aborts rather than warns
- `.devhub-origin` records the generating version. Provenance only — nothing
  reads it

The environment's Forgejo is the source of truth; an off-cluster **push mirror**
(`GITOPS_MIRROR_URL`) is the copy that survives losing the cluster. It carries git
refs only — issues, packages and registry blobs are Velero's job.

## Common Commands

### Entry point: `./devhub`

`./devhub` at the repo root is a thin dispatcher over `k8s/scripts/` and `tofu/`.
It holds no deployment logic — only the routing knowledge (env → tofu module,
platform vs workload deploy script, `-backend-config=backend.hcl`, which
kubeconfig). Prefer it in docs and examples; the underlying scripts stay usable
directly and are the place to make behavioural changes.

`./devhub quickstart` is the guided front door: it detects which steps are already
done (files on disk, tofu state, live cluster objects), prints a checklist, and runs
the next one. Re-runnable at any point; `--status`, `--run-remaining-steps` and
`--auto` make it usable from scripts. Prefer pointing people at it; the individual commands below are what
it calls.

Standard flow from a fresh clone:

```bash
./devhub preflight --env aws-dev  # external prerequisites: cloud auth, domain, DNS
./devhub setup --env aws-dev      # wizard → backend.hcl, terraform.tfvars, config.yaml
                                  # (+ optionally creates the state bucket/lock table)
./devhub init  --env aws-dev      # tofu init (aliases of `infra init|plan|apply`)
./devhub plan  --env aws-dev
./devhub apply --env aws-dev
# set domain + acmeEmail in k8s/overlays/aws-dev/config.yaml
./devhub bootstrap --env aws-dev  # sync → db-users → deploy → vault → keycloak
                                  # → secrets → app-of-apps → gitops handover

# local: no infrastructure layer
./devhub bootstrap --env local
```

```bash
./devhub quickstart               # guided, resumable
#   --status                 checklist only
#   --run-remaining-steps    run all pending steps (still confirms apply)
#   --auto                   as above, unattended
./devhub help                     # command list
./devhub doctor                   # required/optional tooling present?
./devhub envs                     # per-environment state (tofu init? outputs? kubeconfig?)
./devhub validate [--helm] [env]  # static checks, no cluster needed
./devhub validate --e2e --env <env>  # browser end-to-end against the live environment
source <(./devhub completion)     # bash completion

./devhub preflight --env <env> [--dns|--recheck]          # external prerequisites
./devhub setup --env <env> [--dry-run|--non-interactive]  # per-env config files
./devhub infra init|plan|apply --env <env>   # tofu, correct module, backend wired
./devhub sync --env <env>                    # tofu outputs → generated env files
./devhub deploy --env <env> [component]      # deploy.sh or deploy-workload.sh
./devhub bootstrap --env <env>               # setup-all.sh
./devhub vault|keycloak|ca|cluster --env <env>
./devhub db-users|secrets|gitops --env <env>
./devhub gitops-repo --env <env>             # publish the standalone env repo
                                             #   --stage-only <dir>  build and inspect
                                             #   --no-mirror         skip the mirror
./devhub register --env <workload> [--platform-env <env>]
./devhub status --env <env>
eval "$(./devhub kubeconfig --env <env>)"
```

When adding a script or a new `deploy.sh` action, add a matching `devhub`
command (or leave it reachable via `deploy --env <env> <action>`) so the entry
point stays complete.

### OpenTofu (infrastructure)

Every root module uses a **remote backend with locking** (partial config) and requires
an explicit `api_allowed_cidrs`:

```bash
cd tofu/aws/dev                          # or azure|gcp|upcloud, dev|prod|workload
cp backend.hcl.example backend.hcl       # gitignored; bootstrap steps are in the file
cp terraform.tfvars.example terraform.tfvars
tofu init -backend-config=backend.hcl
tofu plan && tofu apply
```

`api_allowed_cidrs` has no default on purpose: `[]` = private API endpoint,
`["1.2.3.4/32"]` = allow-listed public endpoint. On Azure also set
`aad_admin_group_object_ids` to enable Azure RBAC and disable the AKS local admin account.

### K8s Scripts

All scripts are in `k8s/scripts/`. Run from that directory. Each targets the
cluster in `_setup/<env>/kubeconfig` and refuses to run if the active context
does not match the environment.

```bash
# Full local automated setup (20-40 min, zero manual steps)
./setup-all.sh --env local

# Bridge tofu → k8s: writes generated env files + kubeconfig (does NOT touch config.yaml)
./sync-tofu-outputs.sh --env aws-dev

# Platform deployment
./deploy.sh --env aws-dev                     # everything
./deploy.sh --env aws-dev keycloak            # one component
./deploy.sh --env aws-dev all status          # pods, Vault seal state, backups, GitOps
./deploy.sh --env aws-dev all delete

# Platform lifecycle actions
./deploy.sh --env aws-dev db-users            # create managed-PostgreSQL users (once)
./deploy.sh --env aws-dev platform-secrets    # credentials → Vault + ExternalSecrets
./deploy.sh --env aws-dev loki-auth           # (re)generate Loki ingest credentials
./deploy.sh --env aws-dev bootstrap           # ArgoCD app-of-apps
./deploy.sh --env aws-dev gitops              # hand platform components to ArgoCD

# Setup scripts
./setup-ca.sh --env local                     # local CA + TLS certs
./setup-cluster.sh --env local                # cluster prerequisites (Gateway comes from deploy.sh)
./setup-keycloak.sh --env local               # realm, groups, OIDC clients, IdP federation
./setup-vault.sh --env local                  # init, unseal, policies, seed secrets, revoke root

# Static validation (no cluster, no credentials — same checks CI runs)
./validate-overlays.sh
./validate-overlays.sh --helm local

# End-to-end validation of a *deployed* environment (browser, real SSO login)
./validate-e2e.sh --env local
./validate-e2e.sh --env local --grep grafana     # one service
./validate-e2e.sh --env local --headed --report  # watch it, then open the report
```

### Workload Cluster

```bash
cd tofu/aws/workload && tofu init -backend-config=backend.hcl && tofu apply
./sync-tofu-outputs.sh --env aws-workload
./deploy-workload.sh --env aws-workload
./register-workload-cluster.sh --env aws-workload --platform-env aws-dev

# Re-apply namespace guardrails after new apps appear
./deploy-workload.sh --env aws-workload namespace-defaults
```

## Architecture

### Deployment Workflow

```
tofu apply
    → K8s cluster + managed data services + platform IAM/KMS/buckets
    ↓
sync-tofu-outputs.sh --env <env>
    → _setup/<env>/tofu-outputs.env    (hosts, ARNs, buckets, KMS keys)
    → _setup/<env>/secrets.env         (DB/cache passwords, IdP secrets)
    → _setup/<env>/manual-secrets.env  (values tofu cannot create)
    → _setup/<env>/kubeconfig
    ↓
deploy.sh --env <env>
    → reads config.yaml (human-owned) + the generated env files
    → templates Helm values, installs bootstrap components
    ↓
deploy.sh --env <env> gitops
    → ArgoCD ApplicationSet takes over the non-bootstrap components
```

### Configuration Model

Three files, one owner each:

| File | Owner | Contents |
|------|-------|----------|
| `k8s/overlays/<env>/config.yaml` | humans, committed | sample/fallback: TLS mode, `dataServices.type`, service subdomains — and the defaults for everything below |
| `_setup/<env>/config.yaml` | `setup-env.sh`, gitignored | the interview's answers: domain, `acmeEmail`, `gitops.repoUrl`, workload `platformVaultUrl`/`platformLokiUrl` |
| `_setup/<env>/*.env` | `sync-tofu-outputs.sh`, gitignored | everything tofu knows |

Reads are layered through `cfg_get` in `lib/common.sh`: the answers file wins,
the committed overlay is the fallback — so no script ever edits a committed
file and `git status` stays clean through setup, while the overlay keeps
working as a sample (and as the whole config for anyone who prefers editing it
by hand). `setup-gitops-repo.sh` bakes the effective values into the published
repo's committed `config.yaml`, because a standalone environment has no wizard.
Underneath, `yaml_get` is indentation-aware awk, so a nested `host:` cannot be
picked up from the wrong parent — the previous `grep -A1` / `sed -i`
round-trip was order-dependent and silently wrong.

`template_values()` substitutes an explicit allow-list (`TEMPLATE_VARS` in
`lib/common.sh`) so ArgoCD's own `$oidc.keycloak.clientSecret` placeholders
survive. `validate-overlays.sh` fails if any `${VAR}` in a values file is missing
from that list.

### GitOps Boundary

| Owner | Components | Why |
|-------|-----------|-----|
| `deploy.sh` (imperative) | Envoy Gateway, Keycloak (operator), Vault, Forgejo, ArgoCD | GitOps cannot install itself; these hold the bootstrap credentials and the ingress path |
| ArgoCD (`k8s/argocd/platform-appset.yaml`) | cert-manager, external-dns, external-secrets, monitoring, loki, tempo, alloy, kyverno, reloader, woodpecker, headlamp, homepage, velero | reconciled from git; drift self-heals |
| ArgoCD (`k8s/argocd/apps/portal.yaml`) | portal (kustomize, not a chart, so it cannot ride the appset) | reconciled from git; drift self-heals |
| ArgoCD (`k8s/argocd/apps/forgejo-appset.yaml`) | developer apps | matrix of Forgejo repos × clusters labelled `devhub.io/role=workload` |

Registering a workload cluster is enough to start receiving apps — no manifest edit.

### Portal (internal developer platform)

`https://portal.<domain>` is a wizard that scaffolds a new application: Forgejo
repo copied from `devhub-templates/app-template` (with `APP_NAME`/`DOMAIN`
substituted), starter issues, optional dev-grade PostgreSQL/Redis manifests.
Everything downstream is existing convention — the repo landing in the `devhub`
org is what makes `forgejo-appset` deploy it, and the `devhub-*` namespace is
what makes Kyverno fence it. Design rule: **the portal writes git, never the
cluster** — one Forgejo token, no Kubernetes RBAC. Templates live in the
`devhub-templates` org because every `devhub`-org repo with `k8s/` gets
deployed. `deploy.sh --env <env> portal` installs it (and publishes the
template + mints the token); `portal-templates` republishes the template after
an edit (force-push of a fresh tree); `WOODPECKER_TOKEN=<ui-token> deploy.sh
--env <env> ci-secrets` — the one manual step — stores the Woodpecker token so
the portal auto-activates repos, and sets `registry_user`/`registry_token` as
Woodpecker org secrets (push events only). See
`k8s/base/devops/portal/README.md`.

### Cloud-Specific Managed Services

| Cloud   | K8s  | PostgreSQL                | Cache                       | Object Storage |
|---------|------|---------------------------|-----------------------------|----------------|
| UpCloud | UCS  | Managed PG                | Valkey (TLS + auth)         | S3-compatible  |
| Azure   | AKS  | PostgreSQL Flexible Server| Managed Redis (Entra-only)  | Azure Blob     |
| GCP     | GKE  | Cloud SQL                 | Memorystore (auth)          | GCS            |
| AWS     | EKS  | RDS                       | ElastiCache (TLS + auth)    | S3             |

Per cloud, tofu also provisions: Loki log storage + identity, Velero backup
storage + identity, a Vault auto-unseal KMS key + identity, an external-dns
identity, and a tainted spot/preemptible CI node pool. UpCloud differs: no
workload identity (bucket-scoped access keys for Loki/Velero instead, turned
into Kubernetes Secrets by deploy.sh), no Vault KMS seal (manual 3-of-5
unseal), no DNS product (external-dns uses Cloudflare with a hand-made token
secret), and Velero uses kopia file-system backup — no snapshot plugin.

Forgejo keeps repositories, packages and registry blobs on its **PersistentVolume**
— it supports local disk or S3-compatible storage only, and Azure Blob and GCS have
no S3 API, so one storage model beats two. Velero backs the volume up; the database
is the managed PostgreSQL with its own PITR.

### Keyless Storage Access

- **Azure**: Workload Identity — user-assigned identity + federated credential per SA
- **GCP**: Workload Identity — service account + IAM binding per SA
- **AWS**: IRSA — IAM role + OIDC trust policy + SA annotation

Wired for: `monitoring/loki`, `velero/velero`, `vault/vault`,
`external-dns/external-dns`, and (AWS) `kube-system/ebs-csi-controller-sa`,
`kube-system/cluster-autoscaler`.

### Keycloak IdP Federation

Keycloak is the universal OIDC broker. Upstream IdPs: Entra ID (Azure, App Roles →
groups), Google (GCP, manual group assignment), Cognito (AWS, `cognito:groups` →
groups). Client secrets come from `secrets.env` / `manual-secrets.env`.

### Security Model

- **API server**: allow-listed CIDRs or private-only; control-plane audit logs on;
  EKS Secrets envelope-encrypted with KMS; AKS Azure RBAC with the local admin
  account disabled; GKE private nodes + Cloud NAT.
- **Vault**: KMS auto-unseal where available. Unseal/recovery keys are written to
  one gitignored file and **never** stored in the cluster; the initial root token
  is revoked at the end of setup (`vault operator generate-root` to get another).
- **Secrets**: Vault is the source of truth (`secret/platform/*`), delivered by
  External Secrets. ESO's policy covers `platform/*` and `apps/*` only.
- **Workload clusters**: authenticate to Vault via JWT auth against their own OIDC
  issuer (no static token), with a policy limited to `apps/*` and the registry token.
- **CI**: non-privileged rootless BuildKit; Woodpecker runs each pipeline step as
  an ordinary pod in `woodpecker-ci`, pinned to the tainted CI node pool by a
  Kyverno mutation, with a NetworkPolicy blocking the cloud metadata endpoint and
  all RFC1918 ranges.
- **Policy**: Kyverno enforces resource limits, no-privileged and an image-registry
  allow-list for application namespaces, and *generates* each `devhub-*`
  namespace's quota, LimitRange and NetworkPolicies as ArgoCD creates it.
- **NetworkPolicies**: default-deny ingress in every platform namespace; Vault
  reachable only from the gateway, ESO and Prometheus.
- **Headlamp**: curated read-only ClusterRole — no Secrets, no pod exec.
- **Homepage**: links only, no service API tokens, no cluster RBAC. It has no
  authentication of its own — an Envoy Gateway `SecurityPolicy` runs the Keycloak
  OIDC flow at the gateway, so the page never serves an anonymous request.
- **Portal**: same gateway-OIDC pattern as Homepage, and the NetworkPolicy that
  admits only the gateway is what makes it enforcement — the pod holds a Forgejo
  token that can create repositories. No Kubernetes RBAC at all.
- **Ingress**: Envoy Gateway (Gateway API). One `Gateway` owns listeners and TLS;
  each service owns an `HTTPRoute` in its own namespace. cert-manager issues one
  certificate per listener through the gateway shim.
- **PriorityClasses** keep apps and CI from evicting platform services.

### Backups

| What | Mechanism | Schedule |
|------|-----------|----------|
| Cluster objects + PVs | Velero | daily full 02:00, hourly platform state |
| Vault storage | `vault-raft-snapshot` CronJob | every 6h (auth via its own K8s role) |
| Forgejo (repos, packages, registry) | its PVC, captured by Velero | daily + hourly |
| Managed PG / cache | cloud PITR + snapshots | continuous / daily |

Alerts exist for failed and missing backups. See `k8s/docs/OPERATIONS.md`.

### Directory Layout

```
devhub/
├── devhub                             # Entry point — dispatches to the scripts below
├── .github/workflows/validate.yml     # tofu fmt/validate, tflint, checkov, shellcheck,
│                                      # overlay validation, helm template, kubeconform
├── renovate.json                      # chart/provider/image update automation
├── tofu/
│   ├── {upcloud,azure,gcp,aws}/
│   │   ├── modules/cluster/           #   main.tf, addons.tf (AWS), platform.tf, variables, outputs
│   │   ├── dev/ prod/ workload/       #   root modules: backend.tf + tfvars.example + main + outputs
├── k8s/
│   ├── base/
│   │   ├── devops/                    # per-service Helm values + manifests
│   │   │   ├── policy/                #   network policies, priority classes, PDBs
│   │   │   ├── storage/               #   gp3 default StorageClass (EKS)
│   │   │   ├── monitoring/            #   stack values, alert rules, Loki auth policy
│   │   │   ├── external-secrets/      #   ClusterSecretStore + platform ExternalSecrets
│   │   │   ├── vault/                 #   values + raft snapshot CronJob
│   │   │   ├── keycloak/              #   Keycloak CR for the operator
│   │   │   ├── forgejo/               #   values (git, packages, registry)
│   │   │   ├── woodpecker/            #   values + CI namespace RBAC
│   │   │   ├── homepage/              #   link-portal values + OIDC SecurityPolicy
│   │   │   ├── portal/                #   new-app wizard (ConfigMap-served Node app, kustomize)
│   │   │   ├── gateway/               #   Envoy Gateway values
│   │   │   ├── kyverno/               #   values + platform policies
│   │   │   ├── reloader/              #   values
│   │   │   └── velero/                #   backup schedules
│   │   └── workload/                  # workload-cluster manifests (gateway, alloy, secret store)
│   ├── overlays/
│   │   ├── local/                     # local dev
│   │   ├── {cloud}/devops/            # shared per-cloud Helm overrides
│   │   └── {cloud}-{dev,prod,workload}/  # config.yaml + devops symlink
│   ├── argocd/
│   │   ├── apps/                      # app-of-apps + Forgejo ApplicationSet
│   │   ├── projects/                  # AppProjects (RBAC, destinations)
│   │   └── platform-appset.yaml       # platform components as GitOps
│   ├── scripts/                       # deployment and setup scripts (see above)
│   │   ├── quickstart.sh              #   guided, resumable walkthrough
│   │   ├── preflight.sh               #   external prerequisites (cloud, domain, DNS)
│   │   └── setup-env.sh               #   wizard: backend.hcl + tfvars + config.yaml
│   ├── e2e/                           # Playwright end-to-end validation of a live environment
│   │   ├── lib/                       #   env, SSO helpers, in-browser HTTP, local-noise policy
│   │   └── tests/                     #   one spec per service, numbered to run in order
│   ├── templates/app-template/        # developer app scaffold (rootless CI, hardened manifests)
│   └── docs/                          # guides
```

## Documentation

| File | Contents |
|------|----------|
| `k8s/docs/CLOUD_CAPABILITIES.md` | What each cloud actually delivers, and the known gaps |
| `k8s/docs/ADDING_A_CLOUD.md` | Checklist for adding a provider (worked example: Scaleway) |
| `k8s/docs/OPERATIONS.md` | **Day two**: state, secrets/rotation, backups/restore, GitOps, access, alerting, cost |
| `k8s/docs/LOCAL_SETUP.md` | Local dev with Rancher Desktop / WSL2 |
| `k8s/e2e/README.md` | What `validate --e2e` asserts per service, and how to add a check |
| `k8s/docs/{UPCLOUD,AZURE,GCP,AWS}_SETUP.md` | Per-cloud deployment walkthroughs |
| `k8s/docs/KEYCLOAK_SSO.md` | Realm/client/IdP federation setup |
| `k8s/docs/SSO_TESTING_GUIDE.md` | End-to-end SSO testing |

## Key Conventions

- `./devhub` is routing only; behaviour belongs in `k8s/scripts/*.sh`
- Two validators, two questions: `validate` asks "would this deploy?" (static, no
  cluster, what CI runs); `validate --e2e` asks "does what was deployed work?"
  (Playwright, one Keycloak sign-in, read-only assertions per service). A new
  service needs a spec in `k8s/e2e/tests/` or its breakage is invisible
- The e2e suite drives everything through Chromium, including API calls
  (`lib/http.js`): Node resolves `*.localhost` through glibc and fails, Chromium
  resolves it to loopback itself. Never reach for Playwright's `request` fixture
- New setup steps need three things: the script, a `devhub` command, and a
  detector + row in `quickstart.sh`'s step table (otherwise the checklist lies)
- Bash scripts use `set -euo pipefail` with colored logging (`[INFO]`, `[WARN]`, `[ERROR]`, `[STEP]`, `[PHASE]`)
- Config parsing goes through `yaml_get` in `lib/common.sh` (awk, indentation-aware); no `yq` dependency
- Scripts never edit committed files — no exceptions; generated output (including `setup-env.sh`'s answers file `config.yaml`) goes to `_setup/<env>/` at the repo root (gitignored, mode 600/700). `./devhub reset --env <env>` deletes the regenerable ones to start over; `vault-init-keys.json` and `manual-secrets.env` survive unless `--force` (see `_setup/README.md`)
- Every script calls `use_env_kubeconfig` + `require_cluster_match` before touching a cluster
- Rendered Helm values go to a per-run `mktemp -d` directory, not fixed `/tmp` paths
- Helm chart versions are pinned in three places (deploy scripts, `platform-appset.yaml`, docs) — Renovate groups them into one PR
- `.terraform.lock.hcl` **is** committed; `backend.hcl` and `*.tfvars` are not — in *this* repo. A generated environment repo commits them (see Lifecycle)
- Adding a `${VAR}` to a values file means adding it to `TEMPLATE_VARS` too, or `validate-overlays.sh` fails
- YAML files must not have duplicate keys (silent override) — the validator enforces this
- Cloud overlay envs symlink `devops/` from their shared cloud overlay; only `config.yaml` is per-env
- New platform component: add base values, per-cloud overlay values, an entry in `platform-appset.yaml`, a chart pin at the top of `deploy.sh`, and (if bootstrap-critical) an install function
- Routing is Gateway API: add a listener to `overlays/<env>/devops/gateway.yaml` and an `HTTPRoute` to `httproutes.yaml`; never an Ingress. A new local hostname also needs a line in `k8s/scripts/windows/setup-hosts.ps1`, or it resolves in WSL and 404s in the Windows browser
- ArgoCD clones `${GITOPS_REPO_URL_INTERNAL}`, not `${GITOPS_REPO_URL}`: on local
  the repo is only reachable in-cluster by Forgejo's Service name, because glibc
  answers `*.localhost` in `getaddrinfo` before `/etc/hosts` and a hostAlias
  cannot override it. Elsewhere the two are equal
- Keycloak is the **operator** (`k8s.keycloak.org/v2beta1`), pod `keycloak-0`, service `keycloak-service:8080`
- GCP OAuth client must be created manually (no Terraform resource) → `manual-secrets.env`
- The deployment `prefix` (tfvars, asked by `setup-env.sh`) names every resource and the globally-unique namespaces (buckets, Cognito domain, Azure storage account); one per deployment. `deployed_by` rides along as a tag
- Grafana requires `initChownData: enabled: false` for local k3s/Rancher Desktop
- Keycloak `setup-keycloak.sh` uses `kcadm.sh` via `kubectl exec` — avoid `!` `@` `$` in passwords
- `.localhost` DNS gotcha: glibc resolves `*.localhost` to 127.0.0.1 before DNS, so server-side OIDC endpoints must use internal service URLs (`http://keycloak-service.keycloak.svc.cluster.local:8080`) while browser-facing URLs stay external
