# Operations Guide

Day-two operations for the DevHub platform: state, secrets, backups and restore,
the GitOps handover, upgrades, keeping a handed-over environment current, access
and alerting. Setup walkthroughs live in the per-cloud guides (`AWS_SETUP.md`,
`AZURE_SETUP.md`, `GCP_SETUP.md`, `UPCLOUD_SETUP.md`).

---

## 1. OpenTofu state

Every root module uses a remote backend with locking. State holds database
passwords, IdP client secrets and object-storage keys, so it must never sit on a
laptop.

Bootstrap the backend store once per account, then initialise with a partial
config:

```bash
cd tofu/aws/dev
cp backend.hcl.example backend.hcl     # gitignored; fill in bucket/table names
tofu init -backend-config=backend.hcl
```

`backend.hcl.example` in each module documents the exact bootstrap commands for
that cloud (S3 + DynamoDB, Azure Blob, GCS, or UpCloud Object Storage).

### Required variables

`api_allowed_cidrs` has no default, on purpose — an internet-facing Kubernetes API
server should be a written-down decision:

```bash
cp terraform.tfvars.example terraform.tfvars
# api_allowed_cidrs = ["203.0.113.4/32"]   # office egress
# api_allowed_cidrs = []                   # no public endpoint at all
```

With `[]` the control plane is private: reach it over VPN, a bastion, `az aks
command invoke`, or an SSM session. On Azure, also set
`aad_admin_group_object_ids` — doing so disables the AKS local admin account, a
permanent cluster-admin certificate that cannot be attributed to a person.

---

## 2. Configuration flow

```
tofu apply
   ↓  (tofu outputs)
sync-tofu-outputs.sh --env <env>
   ↓  writes, gitignored, mode 600:
   _setup/<env>/tofu-outputs.env    hosts, bucket names, role ARNs, KMS keys
   _setup/<env>/secrets.env         database passwords, Redis auth, IdP secrets
   _setup/<env>/manual-secrets.env  values tofu cannot create (Google OAuth)
   _setup/<env>/kubeconfig          cluster credentials
   ↓
deploy.sh --env <env>
```

`overlays/<env>/config.yaml` stays human-owned: domain, TLS mode, data-service
type, GitOps repo. Nothing rewrites it, so `tofu apply` produces no git diff.

Check what a script will read:

```bash
k8s/scripts/validate-overlays.sh            # config keys, YAML, placeholders
k8s/scripts/validate-overlays.sh --helm local   # also render every chart
```

---

## 3. Secrets

Vault is the source of truth. `secret/platform/*` holds the platform's own
credentials and External Secrets Operator projects them into namespaces.

```bash
./setup-vault.sh --env <env>                 # init, unseal, policies, seed, revoke root
./deploy.sh --env <env> platform-secrets     # switch K8s secrets over to ESO
```

### Rotation

**`kv patch`, never `kv put`.** `secret/platform/postgres` is one secret holding a
property per platform database user (`forgejo-password`, `keycloak-password`,
`woodpecker-password`, …), and `vault kv put` writes a *new version of the whole
secret* containing only the keys on the command line. The other properties are
gone — silently, because the write succeeds and the running pods still hold their
old Kubernetes Secret. The failure surfaces at the next ExternalSecret refresh (up
to an hour later), as several unrelated components losing their database password
at once. `vault kv patch` merges instead.

```bash
# 1. New value in Vault — patch, so the sibling properties survive
vault kv patch secret/platform/postgres forgejo-password=<new>

# 2. Change it in the database too
kubectl run pg -it --rm --image=postgres:16 -- \
  psql -h <pg-host> -U pgadmin -c "ALTER ROLE forgejo WITH PASSWORD '<new>';"

# 3. ESO refreshes within refreshInterval (1h); force it if you are in a hurry.
#    Reloader restarts the affected workloads automatically once the Secret changes.
kubectl annotate externalsecret forgejo-db-secret -n forgejo \
  force-sync="$(date +%s)" --overwrite

# Check what you are about to touch first — and what you left behind after
vault kv get secret/platform/postgres
```

`kv put` is correct only for a single-property secret written whole
(`secret/platform/alertmanager`, for instance). If you did use `put` on a combined
secret, the previous version is still there: `vault kv rollback -version=<n>
secret/platform/postgres`, then re-apply the one change with `patch`.

Keycloak is the exception to step 3: its StatefulSet belongs to the Keycloak
Operator, which reverts foreign annotations, so Reloader cannot drive it. Restart it
by hand after the Secret changes:

```bash
kubectl delete pod keycloak-0 -n keycloak
```

The seeding side of this is `./devhub vault --env <env> seed-secrets --force`, which
reads the current values out of `data-services/postgresql-credentials` (local) or
`secrets.env` (managed) and refuses to write a partially-populated
`secret/platform/postgres` — an empty password syncs cleanly and then fails at the
database, which is a much harder failure to read.

### Vault key material

- **With cloud KMS auto-unseal** (provisioned by tofu): Vault unseals itself on
  restart. Only *recovery* keys exist, printed once at init.
- **Without KMS**: unseal keys are written to
  `_setup/<env>/vault-init-keys.json` (mode 600).

Move that file to offline storage. It is deliberately **not** copied into a
Kubernetes secret — unseal keys plus a root token stored inside the cluster Vault
protects would make read access to one namespace equivalent to Vault root.

Setup creates a long-lived `platform-admin` token, stores it in the same keys file,
and then revokes the initial root token. Every admin action the scripts take uses
that token.

Vault 2.0 made `sys/generate-root` an authenticated endpoint (the fix for
CVE-2026-5807), so a key quorum on its own can no longer mint a new root token — a
valid token is required as well. That makes the keys file the single recovery
artefact: lose it and the only way back is re-initialising Vault.

```bash
./devhub vault --env <env> renew-admin    # extend the admin token (1y, renewable)
./devhub vault --env <env> new-root       # real root, from admin token + key quorum
./devhub vault --env <env> revoke-root    # give it back when you are done
```

The `platform-admin` policy is deliberately not root-equivalent: `sys/audit*` is
denied, so a leaked admin token cannot switch auditing off to cover its tracks.

---

## 4. Backups and restore

| What | Mechanism | Schedule | Retention |
|------|-----------|----------|-----------|
| Cluster objects + PVs | Velero (`velero` namespace) | daily 02:00 full, hourly platform state | 30d / 7d, plus bucket lifecycle |
| Vault storage | `vault-raft-snapshot` CronJob | every 6h | last 28 snapshots on a PVC |
| Forgejo (repos, packages, registry blobs) | Velero snapshots its PVC | daily 02:00 + hourly platform state | 30d / 7d |
| GitOps repository (git refs only) | Forgejo push mirror to an off-cluster remote | on every commit | remote's own |
| Managed PostgreSQL | Cloud-native PITR | continuous | `rds_backup_retention_days` / equivalent |
| Managed Redis/Valkey | Cloud snapshots | daily | `redis_snapshot_retention_days` |

**UpCloud caveat:** Velero uses kopia file-system backup (no volume-snapshot
plugin exists), which only reaches volumes mounted by a running pod. Vault's
raft data (mounted by `vault-0`) is captured; the `vault-snapshots` PVC is
only mounted while the CronJob runs and is usually **not** captured — copy a
snapshot off-cluster (`kubectl cp`) whenever you want a restore point you can
rely on independently of the cluster.

### Verify (do this, do not assume)

```bash
velero backup get
velero backup describe <name> --details
kubectl get cronjob -n vault
kubectl exec -n vault vault-0 -- ls -la /snapshots 2>/dev/null || \
  kubectl get pvc vault-snapshots -n vault
```

**`local` has no backups at all.** Not "reduced" — none. Velero is skipped (no
object storage and no volume-snapshot provider), PostgreSQL and Valkey are
in-cluster StatefulSets with no PITR, and the Vault raft snapshots land on a PVC
on the same machine that would be lost with the cluster. A `docker volume rm` or
a Rancher Desktop factory reset takes the environment with it, Forgejo
repositories included. Push anything you care about to a real remote.

For the same reason there is **no `velero` Application on local at all**:
`platform-appset.yaml` skips it for that environment, because a Velero with no
object storage and no volume-snapshot provider is a component that installs and
then reports nothing useful. Do not go looking for it, and do not add it back to
make the Application list look complete.

### Restore

```bash
# Namespace back to a point in time
velero restore create --from-backup daily-full-20260101020000 \
  --include-namespaces devhub-myapp
```

#### Vault from a raft snapshot

Two things about this are not obvious, and both are the kind of thing you find out
during the incident if you have not rehearsed it.

```bash
kubectl cp vault/vault-0:/snapshots/vault-<stamp>.snap ./vault.snap
kubectl cp ./vault.snap vault/vault-0:/tmp/vault.snap

# Into the SAME cluster (same master key): plain restore.
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore /tmp/vault.snap

# Into a FRESHLY re-initialised cluster: -force is required. Vault refuses a
# snapshot whose cluster identity differs from the running one unless told to.
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore -force /tmp/vault.snap
```

1. **`-force` is required for a rebuilt cluster.** Without it Vault rejects the
   snapshot because its cluster ID does not match. This is the common case: you
   are restoring precisely because the old cluster is gone.
2. **The restored data is encrypted under the OLD master key.** A raft snapshot
   carries the encrypted barrier, not plaintext. Restoring it over a
   freshly-initialised Vault replaces that Vault's keyring with the snapshot's,
   so the new instance's brand-new unseal/recovery keys are worthless from that
   moment on. What unseals it is the **old** key material:

   | Cloud | What must survive the cluster |
   |---|---|
   | AWS / Azure / GCP | the **KMS key** (`tofu` creates it; it must not be destroyed or rotated out of readability). Auto-unseal then works with no keys file. |
   | UpCloud, `local` | the **old `_setup/<env>/vault-init-keys.json`** — 3 of 5 unseal keys. There is no second copy. |

   On UpCloud that file is not optional: without it a raft snapshot is an
   encrypted blob you cannot open. If you are re-running `tofu destroy`/`apply`
   on a KMS cloud, check that the Vault KMS key is not in the destroy plan —
   losing it has exactly the same effect as losing the keys file.

#### Forgejo: the two halves restore to different instants

Forgejo's state is split, and nothing coordinates the two halves:

- **repositories, packages, registry blobs** — its PersistentVolume, captured by
  Velero
- **the database** (users, issues, pull requests, and the *rows that reference
  those blobs*) — managed PostgreSQL, restored by cloud PITR

There is no quiesce hook: Velero snapshots the volume while Forgejo is writing to
it, so the backup is **crash-consistent**, and its instant is whenever the
snapshot ran. Restore the database to "now" and you get rows pointing at package
versions and registry layers that the volume does not contain — a registry that
answers `manifest unknown` for tags the UI lists.

So restore the database to the **Velero backup's timestamp**, not to the latest
recoverable point:

```bash
velero backup describe <daily-full> | grep -i completed   # the instant to target
# then a cloud PITR restore of the managed PostgreSQL to that timestamp
#   AWS:   aws rds restore-db-instance-to-point-in-time --restore-time <ts>
#   Azure: az postgres flexible-server restore --restore-time <ts>
#   GCP:   gcloud sql instances clone --point-in-time <ts>

velero restore create --from-backup <daily-full> --include-namespaces forgejo

# Then reconcile what is left over, before anyone trusts the registry again
kubectl exec -n forgejo deploy/forgejo -- forgejo doctor check --all
kubectl exec -n forgejo deploy/forgejo -- forgejo doctor check --all --fix   # if it reports fixables
```

`forgejo doctor` is what finds the orphaned rows, broken LFS pointers and stale
repository paths. Run it after *any* Forgejo restore, including one where the two
timestamps looked close enough.

### Restore drills

An untested backup is a belief, not a control. Do this quarterly, and after any
change to the storage layer — it costs one namespace and about fifteen minutes:

```bash
# 1. Restore yesterday's app namespace under a different name, so nothing live
#    is touched and the two can be compared side by side.
velero restore create drill-$(date +%Y%m%d) \
  --from-backup <daily-full> \
  --include-namespaces devhub-myapp \
  --namespace-mappings devhub-myapp:devhub-myapp-drill

# 2. Did it actually come back?
velero restore describe drill-$(date +%Y%m%d) --details
kubectl get pod,pvc,secret -n devhub-myapp-drill
kubectl logs -n devhub-myapp-drill deploy/myapp | tail

# 3. Tear it down. Kyverno will have generated the quota/limits/policies for the
#    new namespace; deleting the namespace removes them with it.
kubectl delete namespace devhub-myapp-drill
```

Note what the drill proves and what it does not: it proves Velero can write
objects and volumes back. It says nothing about Vault or Forgejo, whose restores
have the caveats above — rehearse those separately, on a throwaway environment,
before you need them.

Alerts fire when this stops working: `VeleroBackupFailed`,
`VeleroNoRecentBackup`, `VaultSnapshotJobFailed` (a run that failed) and
`VaultSnapshotStale` (no recent snapshot at all — the case a suspended or deleted
CronJob produces, where "no failures" and "no backups" look identical). Nothing
alerts on a restore never having been attempted, which is why the drill above is
a calendar item and not a dashboard.

### The GitOps repository is inside the cluster it manages

This is deliberate — the platform hosts its own tooling — but it means the
repository describing the environment dies with the environment. Two things
cover that, and they cover different halves:

- **The push mirror** (`GITOPS_MIRROR_URL`, configured by `setup-gitops-repo.sh`)
  syncs on every commit, so git history is seconds behind at worst. It carries
  **refs only**: no issues, pull requests, releases, packages or registry blobs.
  It force-overwrites the remote, so never commit directly there — those commits
  are destroyed on the next sync. Check that it is still working: mirror failures
  are silent (section 13, "Is the push mirror still pushing?").
- **Velero** captures Forgejo's PVC, which is where everything the mirror omits
  actually lives.

An environment with neither has exactly one copy of its own definition.

### Rebuilding an environment from nothing

Order matters, and it is not circular the way it first appears: Forgejo is part
of the imperative bootstrap set, so it comes back before ArgoCD needs it.

```bash
# 1. Infrastructure
cd tofu/<cloud>/<tier> && tofu init -backend-config=backend.hcl && tofu apply

# 2. Platform, imperatively — this installs Forgejo itself
./devhub sync   --env <env>
./devhub deploy --env <env>

# 3. Vault, from a raft snapshot: `restore -force` into the fresh cluster, then
#    unseal with the OLD key material — the KMS key, or the old
#    vault-init-keys.json on UpCloud. See "Vault from a raft snapshot" above;
#    this is the step that fails if that file was never moved offline.

# 4. Forgejo's content: restore the PVC, which brings back repositories,
#    packages and the registry in one step — and restore the managed PostgreSQL
#    to the *same instant* (see "the two halves restore to different instants"),
#    then run `forgejo doctor check --all`.
velero restore create --from-backup <daily-full> --include-namespaces forgejo

#    If the PVC is unrecoverable, push the mirror back into the fresh Forgejo
#    instead and accept losing issues, packages and registry blobs:
#      git clone --mirror <GITOPS_MIRROR_URL> && cd <repo>.git
#      git push --mirror https://git.<domain>/<org>/<repo>.git

# 5. Point ArgoCD at the repository again and let it reconcile the rest
./devhub deploy --env <env> bootstrap
./devhub deploy --env <env> gitops
```

Step 5 is where the platform starts healing itself: everything ArgoCD owns comes
back from git without further intervention.

---

## 5. GitOps

```bash
./deploy.sh --env <env> bootstrap   # app-of-apps → k8s/argocd/apps
./deploy.sh --env <env> gitops      # ApplicationSet owns platform components
```

After the handover ArgoCD reconciles cert-manager, external-dns, external-secrets,
the monitoring stack, Loki, Tempo, Alloy, Kyverno, Reloader, Woodpecker,
Headlamp, Homepage and Velero from this repository — Velero everywhere except
`local`, where the ApplicationSet skips it. Change them with a commit; a manual
`helm upgrade` is reverted by self-heal.

Bootstrap-critical components stay imperative because GitOps cannot install
itself: Envoy Gateway, Keycloak, Vault, Forgejo, and ArgoCD.

### What reconciles what

| Object | Applied by | Reconciled by |
|---|---|---|
| `k8s/argocd/apps/app-of-apps.yaml` | `deploy.sh bootstrap`, after `template_values()` | itself |
| everything else in `k8s/argocd/apps/` | app-of-apps (`recurse: false`) | app-of-apps |
| `k8s/argocd/platform-appset.yaml` | `deploy.sh gitops`, after `template_values()` | `platform-config`, in a published repo (see below) |
| `k8s/argocd/projects/*.yaml` | `deploy.sh gitops`, **verbatim** | `platform-config`, in a published repo |
| the platform components themselves | — | the ApplicationSet |

`projects/*.yaml` gets no `template_values()` pass, which is why
`projects/platform.yaml` matches source repositories with a **repo-URL prefix
glob** rather than `${GITOPS_REPO_URL_INTERNAL}` — an unsubstituted placeholder in
an AppProject would silently deny every Application in it. The platform
Applications (`app-of-apps`, `platform-appset`, `portal`) all run in that
`platform` project rather than `default`.

### The repository is the environment's own

The repository ArgoCD reads is **this environment's own**, published by
`./devhub gitops-repo --env <env>` into the environment's Forgejo. devhub
generated it and is not referenced again: there is no upstream to pull from and
no upgrade path back, by design. `renovate.json` ships with the environment so
chart pins keep moving anyway.

A published repository also gets a generated `k8s/argocd/apps/platform-config.yaml`
Application. That is what closes the loop: without it `platform-appset.yaml` and
`projects/` are applied only by `deploy.sh gitops` — once, imperatively — so a
merged chart-pin commit would change git and nothing else. With it, the commit is
the whole procedure. It syncs with `prune: false` and no finalizer, deliberately:
this is the Application that owns the ApplicationSet that owns every GitOps
component, and a bad include pattern must not be able to delete the platform.
Section 7 has the rest.

On a local environment ArgoCD clones Forgejo's in-cluster Service
(`http://forgejo-http.forgejo.svc.cluster.local:3000/...`) rather than
`https://git.localhost`. glibc answers `*.localhost` with 127.0.0.1 inside
`getaddrinfo`, before `/etc/hosts` is read, so a pod cloning the public hostname
dials itself and a hostAlias cannot override it. `GITOPS_REPO_URL_INTERNAL` in
`lib/common.sh` is that distinction; everywhere else the two URLs are identical.

Developer apps are discovered by the `forgejo-workloads` ApplicationSet: a matrix
of Forgejo repositories in the `devhub` organisation × clusters labelled
`devhub.io/role=workload`. Forgejo implements the Gitea API, so ArgoCD's `gitea`
SCM provider is the right one. Registering a workload cluster is therefore all it
takes to start receiving apps — no manifest edit.

---

## 6. Upgrades

Three separate things get upgraded, on three different mechanisms, and confusing
them is how a cluster ends up with a control plane four minor versions ahead of
its charts.

### Kubernetes itself — through tofu

The cluster version is an input variable, not something to click in a console:
changing it in a console leaves tofu's next plan wanting to change it back.

```bash
cd tofu/<cloud>/<tier>
# aws:     kubernetes_version     = "1.34"   (module default tracks a supported EKS version)
# azure:   aks_kubernetes_version = "1.34"
# gcp:     managed by the STABLE release channel — see below
tofu plan -var-file=terraform.tfvars     # read this plan properly
tofu apply
```

One minor version at a time, control plane before nodes, and read the provider's
plan: on every cloud the node pool change is a **replacement**, not an in-place
edit. What that means in practice:

- Nodes are cordoned and drained one at a time (cloud-managed surge on AKS/GKE/EKS
  managed node groups). Pods are evicted subject to their PodDisruptionBudgets —
  `k8s/base/devops/policy/` defines those for the platform, and Kyverno generates
  none for app namespaces, so a single-replica app *will* have a gap.
- Anything with a single replica on RWO storage is down for the length of a
  reschedule: Vault (per pod), Keycloak, Forgejo, the in-cluster data services on
  local.
- Budget the whole node pool: with `node_count = 3` and one surge node, expect
  three drain cycles.

Per-cloud posture, and it is not uniform:

| Cloud | Patch upgrades | Minor upgrades |
|---|---|---|
| GCP | automatic — the cluster is on the **`STABLE` release channel** (`tofu/gcp/modules/cluster/main.tf`), so GKE moves patches, and eventually minors, on Google's schedule | channel-driven; pin with an exclusion window if you need to hold |
| AWS | **explicit only** — `kubernetes_version` in the root module (`1.33` today). Nothing moves unless you move it, including patches. EKS end-of-support dates are the clock to watch | explicit |
| Azure | automatic — `automatic_upgrade_channel` defaults to **`patch`** with a Sunday 02:00 UTC maintenance window (`aks_upgrade_channel` to change it, `none` to opt out), so AKS takes security patches within the current minor. `kubernetes_version` is in `ignore_changes`, or every plan would try to roll a patch upgrade back | explicit (`aks_kubernetes_version`) |
| UpCloud | explicit, on UpCloud's supported-version list | explicit |

After any cluster upgrade, check the API deprecations you just walked into
(`kubectl get events -A | grep -i deprecat`, and the chart release notes for
removed API versions) — a chart pinned a year ago can render `policy/v1beta1`
objects that a new control plane no longer serves. `validate --helm` catches that
only if the chart itself was bumped.

### Bootstrap components — by re-running deploy.sh

The five components GitOps cannot install itself are upgraded by bumping their
pin at the top of `k8s/scripts/deploy.sh` and re-running that one component. The
command is idempotent; what differs is what a rollout costs:

```bash
./deploy.sh --env <env> gateway     # Envoy Gateway
./deploy.sh --env <env> keycloak    # Keycloak (operator + CR)
./deploy.sh --env <env> vault
./deploy.sh --env <env> forgejo
./deploy.sh --env <env> argocd
```

| Component | What a re-run does | Watch for |
|---|---|---|
| Envoy Gateway | `helm upgrade`, then the data-plane Deployment rolls | the whole platform's ingress. Gateway API CRDs are upgraded first; a chart that ships a newer Gateway API version can invalidate an existing `Gateway` — check the listeners are `Programmed` afterwards |
| Keycloak | the **operator** is upgraded; it then reconciles `keycloak-0` itself | operator major versions perform a realm/database migration on first start. Take a PostgreSQL snapshot first, and expect sign-in to be down for the restart. Reloader cannot drive this StatefulSet (the operator reverts foreign annotations) |
| Vault | `helm upgrade` and a StatefulSet rollout — **one pod at a time, and each restarted pod comes back sealed** | see the caveat below |
| Forgejo | `helm upgrade`, `Recreate` strategy on RWO storage — the old pod terminates before the new one starts | git, the container registry, packages and therefore every CI pipeline are down for the duration. Forgejo runs its own database migration on start; do not interrupt it |
| ArgoCD | `helm upgrade`; the controllers restart | reconciliation pauses, nothing is pruned or self-healed meanwhile. Applications may show `Unknown` until the repo-server is back |

**Forgejo is a single pod on a ReadWriteOnce volume with a `Recreate` strategy.**
That is not an upgrade artefact — it is the steady state, and the accepted
trade-off: two replicas would need shared RWX storage that no target cloud offers
Forgejo through an S3 API, and running two storage models would double the failure
modes (see `k8s/docs/CLOUD_CAPABILITIES.md`). The consequence is real, so plan
around it: **any** node drain that moves the Forgejo pod — a cluster upgrade, a
node pool resize, a spot reclaim, a `kubectl drain` — takes git hosting, the
registry, packages and all of CI down platform-wide for a reschedule plus volume
reattach. Drain during quiet hours, drain the Forgejo node deliberately rather
than last, and tell people first. If that window is unacceptable for your
environment, the answer is a dedicated registry (zot/Harbor with an S3 backend)
rather than a second Forgejo.

**Vault HA raft on UpCloud needs a manual unseal per pod.** With cloud KMS
auto-unseal (AWS/Azure/GCP) a rolling restart is unattended: each pod unseals
itself. UpCloud has no Vault seal type, so **every** restarted pod comes back
sealed and waits for 3 of 5 unseal keys — and a rolling StatefulSet update does
not proceed until the pod is Ready, so an unattended `helm upgrade` stalls
half-done with Vault unavailable. Have the keys file open before you start:

```bash
for i in 0 1 2; do
  for k in 1 2 3; do
    kubectl exec -n vault vault-$i -- vault operator unseal <key-$k>
  done
done
kubectl exec -n vault vault-0 -- vault status      # Sealed: false, HA mode: active
```

### GitOps components — by commit

Everything else (cert-manager, external-dns, external-secrets, monitoring, Loki,
Tempo, Alloy, Kyverno, Reloader, Woodpecker, Headlamp, Homepage, Velero) is a
chart version in `k8s/argocd/platform-appset.yaml`. Change it, commit, and ArgoCD
does the upgrade. In a published environment repo the commit is the whole
procedure — that is what the generated `platform-config` Application is for.

### Then prove it

```bash
./deploy.sh --env <env> all status
./validate-e2e.sh --env <env>            # one real Keycloak sign-in, then every service
kubectl get applications -n argocd       # Synced/Healthy?
kubectl get certificate -A               # still Ready after a gateway upgrade?
```

`validate-e2e.sh` is the post-upgrade smoke test and the reason to keep the suite
shipped with the environment: it drives a browser through the actual SSO chain, so
it catches the failures an upgrade produces that no `kubectl get` shows — a
redirect URI the new chart changed, a gateway listener that came back without its
certificate, Grafana's OIDC login silently falling back to a login form. Run it
before you declare the upgrade done, and `--grep <service>` on whatever you
touched.

---

## 7. Keeping the platform up to date

Read the Lifecycle note first: `./devhub gitops-repo` cuts the link, and the
environment repository is then standalone. That is deliberate, and it has a cost
this section is about — improvements made to devhub afterwards do not arrive on
their own.

### What Renovate covers

`renovate.json` ships with the environment repository, and its custom managers
read the pins where they actually live:

- **Helm chart versions** — `CHART_*="1.2.3" # renovate: helm depName=<chart>
  registryUrl=<url>` in the deploy scripts, and the same pins in
  `k8s/argocd/platform-appset.yaml`. `groupName: helm chart {{depName}}` merges
  both into one pull request, so the imperative and GitOps halves cannot drift
  apart.
- **Container images** in manifests and values files.
- **OpenTofu providers and modules**, against the committed `.terraform.lock.hcl`.
- **GitHub-release-versioned tools** pinned as `VAR="1.2.3" # renovate:
  github-releases depName=owner/repo`.

A merged chart-pin PR now takes effect on its own: `platform-config` reconciles
`platform-appset.yaml` and `projects/`, and `.woodpecker.yml` renders every chart
against this environment's values before the merge. Bumps in the deploy scripts
still need `./deploy.sh --env <env> <component>` to be run — Renovate cannot
restart Vault for you.

### What Renovate cannot cover

This is the honest list, and every item on it is a change a human has to make:

| Not covered | Why, and what it looks like when it bites |
|---|---|
| **Values-schema migrations on a major chart bump** | Renovate changes a number. If the chart moved `persistence.enabled` to `storage.persistence.enabled`, the old key is silently ignored — the chart renders, deploys, and quietly runs on the default. `.woodpecker.yml`'s `--helm` step catches a key the chart now *rejects*, not one it merely stopped reading. Read the upgrade notes for every major. |
| **Brand-new platform components** | A component added to devhub after the handover does not exist in this repository. It is base values + a per-cloud overlay + an appset entry + possibly a `deploy.sh` install function — five files Renovate will never write. |
| **Fixes to the ~20 shipped operational scripts** | `deploy.sh`, `setup-vault.sh`, `setup-keycloak.sh`, `sync-tofu-outputs.sh`, `lib/common.sh` and the rest were copied at publish time. Every bug fixed in them upstream since is still present here. |
| **Kubernetes version bumps and API deprecations** | Section 6. Nothing tells this repository that its `kubernetes_version` is approaching end of support. |
| **Keycloak realm and Vault policy logic** | Client scopes, mappers, IdP federation, ESO's policy paths, the workload-cluster JWT role — imperative logic in the setup scripts, not data. A tightened Vault policy or a new client scope upstream is a script change, i.e. the row above. |
| **Anything in `tofu/` that is not a version** | New IAM permissions, a new managed-service setting, a new output that `sync-tofu-outputs.sh` expects. |

### The re-sync recipe

There is no upgrade command, and there will not be one — but there is a
repeatable procedure, built from two things that already exist:

- `.devhub-origin` in the environment repository records the devhub **commit**
  that generated it
- `./devhub gitops-repo --env <env> --stage-only <dir>` builds the staged tree
  and stops, without touching a cluster or a remote

Stage the same environment twice — once at the recorded origin commit, once at
latest — and the diff between the two staged trees is exactly "what devhub changed
for this environment", with no unrelated clouds, no other environments and no
placeholder noise. Three-way merge that onto the environment repository:

```bash
# 0. In the environment repository: what generated it, and a branch to land on
git clone https://git.<domain>/<org>/<repo>.git env-repo
ORIGIN=$(awk -F': ' '/^commit:/{print $2}' env-repo/.devhub-origin)
git -C env-repo switch -c resync-$(date +%Y%m%d)

# 1. Two checkouts of devhub: the version that generated this environment, and latest
git clone https://github.com/<you>/devhub.git devhub-old && git -C devhub-old checkout "$ORIGIN"
git clone https://github.com/<you>/devhub.git devhub-new

# 2. Stage the SAME environment from both. Both checkouts need this
#    environment's _setup/<env>/ (the wizard's answers + tofu-outputs.env, from
#    the machine you operate the environment from, or regenerated with
#    `./devhub sync --env <env>`), or the two staged trees differ in every
#    hostname instead of only where devhub changed.
cp -r /path/to/_setup/<env> devhub-old/_setup/<env>
cp -r /path/to/_setup/<env> devhub-new/_setup/<env>
(cd devhub-old && ./devhub gitops-repo --env <env> --stage-only /tmp/stage-old)
(cd devhub-new && ./devhub gitops-repo --env <env> --stage-only /tmp/stage-new)

# 3. The upstream change, isolated
diff -ru /tmp/stage-old /tmp/stage-new > /tmp/devhub.patch
$PAGER /tmp/devhub.patch          # read it. This is the whole point of the exercise.

# 4. Apply it to the environment repository as a 3-way merge, so local
#    divergence conflicts loudly instead of being overwritten
git -C env-repo apply -3 --directory=. /tmp/devhub.patch
git -C env-repo status            # resolve conflicts by hand; local changes win
                                  # unless you decide otherwise, one file at a time

# 5. The generated files are regenerated, not merged — take the new ones
cp /tmp/stage-new/.devhub-origin env-repo/.devhub-origin
cp /tmp/stage-new/.woodpecker.yml env-repo/.woodpecker.yml
cp /tmp/stage-new/k8s/argocd/apps/platform-config.yaml \
   env-repo/k8s/argocd/apps/platform-config.yaml

# 6. Validate before ArgoCD sees it, then let CI do it again on the PR
(cd env-repo && k8s/scripts/validate-overlays.sh --helm <env>)
git -C env-repo commit -am "Re-sync with devhub $(git -C devhub-new rev-parse --short HEAD)"
```

Then open it as a pull request in the environment's Forgejo so `.woodpecker.yml`
runs, merge, let ArgoCD reconcile, and finish with
`./validate-e2e.sh --env <env>`. Re-run any bootstrap component whose pin the
patch moved (section 6). Expect to do this once or twice a year, not weekly — and
expect the first one after a long gap to be the expensive one.

### Say it plainly

This converts "no upstream dependency" into **merge-based updates**, and that is
the honest description of the lifecycle. The environment does not *depend* on
devhub — it boots, runs, backs itself up and reconciles with devhub deleted, which
is the property the handover buys. But "improvements arrive by someone diffing two
staged trees and merging" is not the same as "there is no upgrade path", and
pretending otherwise is how an environment ends up three years behind with nobody
having decided that.

If you want the cost lower, keep local divergence small and deliberate: put
environment-specific choices in `k8s/overlays/<env>/` and `terraform.tfvars`,
where devhub barely writes, rather than editing `k8s/base/` or the scripts. Every
line you change in a shipped file is a line you will merge by hand later.

---

## 8. Workload clusters

```bash
cd tofu/aws/workload && tofu init -backend-config=backend.hcl && tofu apply
./sync-tofu-outputs.sh --env aws-workload
./deploy-workload.sh --env aws-workload
./register-workload-cluster.sh --env aws-workload --platform-env aws-dev
```

`register-workload-cluster.sh` does four things:

1. Registers the cluster with the platform ArgoCD, labelled `devhub.io/role=workload`
2. Creates a Vault JWT auth mount trusting the cluster's OIDC issuer, with a
   policy limited to `secret/data/apps/*` and the registry pull token — no static
   token to leak or rotate
3. Copies the Loki ingest credentials so Alloy can ship logs
4. Creates a Forgejo registry token for image pulls and stores it in Vault

Namespace guardrails (ResourceQuota, LimitRange, NetworkPolicies) are **generated
by Kyverno** as each `devhub-*` namespace appears, and kept in sync if someone
edits them away. There is no sweep to remember:

```bash
kubectl get clusterpolicy devhub-namespace-defaults
kubectl get quota,limitrange,networkpolicy -n devhub-<app>
```

---

## 9. Network and access model

- **Kubernetes API**: allow-listed CIDRs or private-only (`api_allowed_cidrs`).
- **Pod traffic**: every platform namespace defaults to deny-ingress; allowed
  sources are the Envoy data plane, the same namespace, and Prometheus.
  Vault additionally accepts External Secrets; the local data services accept
  only Keycloak, Forgejo and monitoring.
- **CI jobs** run in `woodpecker-ci` on a tainted node pool, non-privileged, with
  egress to the internet but **not** to `169.254.0.0/16` (cloud metadata → node
  IAM credentials) and **not** to RFC1918 ranges (managed databases, control
  planes). A Kyverno mutation pins them to that pool.
- **Developer apps** get the same metadata-endpoint block; cloud access is via
  their own Workload Identity/IRSA service account.
- **Headlamp** reads a curated resource list. It cannot read Secrets and cannot
  exec into pods; use `kubectl` under your own identity for that.
- **Homepage** holds no credentials and talks to nothing: it is a static list of
  links, so there are no service API tokens to leak. It has no login of its own
  either — an Envoy Gateway `SecurityPolicy` runs the Keycloak OIDC flow before
  the request reaches the pod, which is what keeps the platform's hostnames off
  the public internet.
- **MCP clients** (Claude Code, VS Code) reach an app's `/mcp` endpoint with
  Bearer tokens the gateway validates against Keycloak (`mcp.enabled` in the
  app's `values.yaml`; realm prep is `./devhub keycloak --env <env> mcp`).
  Long-lived connections use **offline tokens** (`offline_access`): they slide
  on a 30-day idle window and — being Keycloak's own — are **not** revoked by
  offboarding the user in Entra/Google/Cognito. To cut one off, delete the
  user's offline sessions in the realm console (Users → Sessions) or disable
  the Keycloak user.

---

## 10. Routing (Gateway API)

Ingress objects are gone. One `Gateway` in the `gateway` namespace owns the
listeners and TLS; each service owns an `HTTPRoute` in its own namespace.

```bash
kubectl get gateway devhub -n gateway                  # address + listener status
kubectl get httproute -A                               # who is attached
kubectl get certificate -n gateway                     # one per listener
kubectl describe gateway devhub -n gateway | tail -30   # listener conflicts
```

Adding a platform hostname takes two edits in
`k8s/overlays/<env>/devops/`: a listener in `gateway.yaml` and a route in
`httproutes.yaml`. cert-manager notices the new listener and issues its
certificate (the "gateway shim"), and external-dns publishes the hostname from
the HTTPRoute.

On workload clusters the Gateway instead has a single wildcard listener
(`*.<domain>`) with a DNS-01 certificate, so an app only needs its own HTTPRoute
with `sectionName: apps` — no platform change per app.

Basic auth for the Loki push endpoint is an Envoy Gateway `SecurityPolicy`
attached to that route; Gateway API itself has no auth primitive.

---

## 11. Alerting

Alertmanager routes to Slack via a webhook stored in Vault:

```bash
vault kv put secret/platform/alertmanager webhook-url=https://hooks.slack.com/services/...
kubectl annotate externalsecret alertmanager-slack -n monitoring \
  force-sync="$(date +%s)" --overwrite
```

With an empty webhook the config still loads and alerts remain visible in the
Alertmanager UI — but nothing is delivered, so set it.

Platform rules (`k8s/base/devops/monitoring/platform-alerts.yaml`) cover a sealed
or leaderless Vault, certificates that stopped renewing or expired
(`CertificateExpiringSoon`, `CertificateRenewalFailing`), a Gateway listener with
no certificate at all (`GatewayCertificateMissing`), stuck or degraded ArgoCD
apps, failed *and* missing backups (`VeleroBackupFailed` /
`VeleroNoRecentBackup`, `VaultSnapshotJobFailed` / `VaultSnapshotStale`), filling
PVCs and crash-looping platform pods.

Several of these are deliberately **absence-based** rather than value-based —
`VaultSealed`, `VaultNoLeader`, `VaultSnapshotStale` and
`GatewayCertificateMissing` fire when the metric they watch stops being reported,
not only when it reports a bad value. A rule that needs `vault_core_unsealed == 0`
to be scraped says nothing when Vault is gone entirely, which is the outage you
most wanted the page for.

Metrics retention is 30 days on a local PVC. For anything longer, set
`prometheus.prometheusSpec.remoteWrite` in the cloud overlay (Amazon Managed
Prometheus, Azure Monitor, Google Cloud Managed Prometheus, Grafana Cloud).

Logs go to Loki, which runs multi-tenant (`auth_enabled: true`): the platform
cluster writes tenant `platform`, each workload cluster writes its environment
name. Grafana queries with `X-Scope-OrgID`. On managed clouds Loki stores chunks
in object storage; without the cloud identity it falls back to a local PVC and
loses history on pod recycle — the deploy log says which mode is active.

---

## 12. Cost controls

- Node pools autoscale (EKS cluster-autoscaler, AKS/GKE built-in).
- CI runs on a **spot/preemptible, scale-to-zero** pool (`role=ci`, taint
  `workload=ci`).
- Dev environments use a single NAT gateway; prod uses one per AZ
  (`nat_gateway_per_az`).
- Loki chunks and Velero backups expire via bucket lifecycle rules
  (`log_retention_days`, `backup_retention_days`).

### Do not undersize the platform pool

Cost control has a floor, and it is higher than it looks. This is a full platform
— Keycloak, Vault, Forgejo, ArgoCD, Envoy Gateway, Prometheus, Grafana, Loki,
Tempo, Alloy, Kyverno, Velero, plus the operators — and it has to fit *with*
headroom for a node to be drained.

Rough minimums for the platform pool (excluding the CI pool, which scales to
zero, and any workloads):

| | vCPU | Memory | Comment |
|---|---|---|---|
| Prometheus alone | 500m request / 2 CPU limit | **2Gi request / 4Gi limit** | `k8s/base/devops/monitoring/prometheus-stack-values.yaml`. It is the single largest consumer, and unschedulable Prometheus is the most common "why is nothing coming up" |
| Rest of the platform | ~2–3 vCPU | ~4–6Gi | Keycloak, Vault, Forgejo, ArgoCD and the gateway are the next tier down |
| **Total, absolute floor** | **~4 vCPU** | **~8Gi allocatable** | across at least 2 nodes |
| **Comfortable, with drain headroom** | 6–8 vCPU | 12–16Gi | 3 nodes of 2 vCPU / 8Gi, or 2 of 4 vCPU / 16Gi |

Read that against the dev defaults before you shrink them: Azure dev is
`Standard_B2s` (2 vCPU / 4Gi) × 2, which is at the floor with nothing to spare —
one 2Gi Prometheus on a 4Gi node leaves very little for kubelet, the CNI and
everything else that has to land there. GCP dev's `e2-standard-2` (2 vCPU / 8Gi)
× 2 is the more realistic shape. Undersizing does not show up as a bill; it shows
up as `Pending` pods with `Insufficient memory`, and on a cluster upgrade as a
drain that cannot complete because the evicted pods have nowhere to go.

Note also that GKE node counts in the root modules are now **cluster totals**
(`total_min_node_count` / `total_max_node_count`), not per-zone — a regional
cluster no longer silently multiplies them by the number of zones.

---

## 13. Routine checks

```bash
./deploy.sh --env <env> all status     # pods, Vault seal state, backups, GitOps
velero backup get
kubectl get externalsecrets -A          # SecretSynced?
kubectl get certificates -A             # Ready?
kubectl get gateway,httproute -A        # Programmed / Accepted?
kubectl get clusterpolicy               # Kyverno policies Ready?
kubectl get applications -n argocd      # Synced/Healthy?
```

### Is the push mirror still pushing?

Add this one to the rotation, because nothing else will tell you. A push mirror
that has stopped working fails **silently**: Forgejo records the error against the
mirror configuration, there is no Kubernetes object to go unhealthy, no
Prometheus alert fires, and the repository keeps accepting commits exactly as
before. An expired mirror token, a rotated GitHub PAT, a renamed remote
repository or a force-push rejection all look identical from the inside — like
nothing at all. You discover it when you reach for the off-cluster copy, which is
by definition the worst moment.

```bash
POD=$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo \
  -o jsonpath='{.items[0].metadata.name}')

# Substitute your GitOps repo's <org>/<repo>. Needs a token with read:repository.
kubectl exec -n forgejo "$POD" -- curl -sS \
  -H "Authorization: token <forgejo-token>" \
  "http://localhost:3000/api/v1/repos/<org>/<repo>/push_mirrors" \
  | jq -r '.[] | "\(.remote_address)  last_update=\(.last_update)  error=\(.last_error // "none")"'
```

What to look for:

- `last_error` non-empty — act now, it is broken
- `last_update` older than the newest commit on `main` — the mirror is behind, and
  since `sync_on_commit: true` means it should be seconds behind, any real gap is
  a failure and not a schedule
- an empty list — there is no mirror at all, and the repository describing this
  environment exists only inside the cluster it manages

After fixing the credential, force a sync from Forgejo → the repository →
Settings → Mirror Settings → **Synchronize Now**, and re-check `last_update`.

## 14. Known deprecations

Things upstream has flagged, with the plan for each. Check this list when bumping
chart versions.

| Component | Status | Plan |
|---|---|---|
| `grafana/tempo` (single binary) | Chart deprecated in favour of `grafana/tempo-distributed` | Kept: tempo-distributed splits into 5–6 deployments for a trace volume that fits in one pod. Migrate when the chart stops tracking Tempo releases — same buckets, same OTLP endpoint, only `tempo-values.yaml` and the chart name change. |
| Forgejo state on a PersistentVolume | Not deprecated, but the only option | Forgejo speaks S3 or local disk; Azure Blob and GCS have no S3 API. Durability comes from Velero plus managed-PostgreSQL PITR. A very large registry means a bigger volume or a dedicated registry (zot/Harbor). |
