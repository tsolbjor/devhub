# Operations Guide

Day-two operations for the DevHub platform: state, secrets, backups, access,
alerting and the GitOps handover. Setup walkthroughs live in the per-cloud guides
(`AWS_SETUP.md`, `AZURE_SETUP.md`, `GCP_SETUP.md`, `UPCLOUD_SETUP.md`).

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
   k8s/scripts/<env>/tofu-outputs.env    hosts, bucket names, role ARNs, KMS keys
   k8s/scripts/<env>/secrets.env         database passwords, Redis auth, IdP secrets
   k8s/scripts/<env>/manual-secrets.env  values tofu cannot create (Google OAuth)
   k8s/scripts/<env>/kubeconfig          cluster credentials
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

```bash
# 1. New value in Vault
vault kv put secret/platform/postgres forgejo-password=<new>

# 2. Change it in the database too
kubectl run pg -it --rm --image=postgres:16 -- \
  psql -h <pg-host> -U pgadmin -c "ALTER ROLE forgejo WITH PASSWORD '<new>';"

# 3. ESO refreshes within refreshInterval (1h); force it if you are in a hurry.
#    Reloader restarts the affected workloads automatically once the Secret changes.
kubectl annotate externalsecret forgejo-db-secret -n forgejo \
  force-sync="$(date +%s)" --overwrite
```

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
  `k8s/scripts/<env>/vault-init-keys.json` (mode 600).

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
| Managed PostgreSQL | Cloud-native PITR | continuous | `rds_backup_retention_days` / equivalent |
| Managed Redis/Valkey | Cloud snapshots | daily | `redis_snapshot_retention_days` |

### Verify (do this, do not assume)

```bash
velero backup get
velero backup describe <name> --details
kubectl get cronjob -n vault
kubectl exec -n vault vault-0 -- ls -la /snapshots 2>/dev/null || \
  kubectl get pvc vault-snapshots -n vault
```

### Restore sketches

```bash
# Namespace back to a point in time
velero restore create --from-backup daily-full-20260101020000 \
  --include-namespaces devhub-myapp

# Vault from a raft snapshot (cluster must be initialised and unsealed)
kubectl cp vault/vault-0:/snapshots/vault-<stamp>.snap ./vault.snap
kubectl cp ./vault.snap vault/vault-0:/tmp/vault.snap
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore /tmp/vault.snap
```

Alerts fire when this stops working: `VeleroBackupFailed`,
`VeleroNoRecentBackup`, `VaultSnapshotJobFailed`.

---

## 5. GitOps

```bash
./deploy.sh --env <env> bootstrap   # app-of-apps → k8s/argocd/apps
./deploy.sh --env <env> gitops      # ApplicationSet owns platform components
```

After the handover ArgoCD reconciles cert-manager, external-dns, external-secrets,
the monitoring stack, Kyverno, Reloader, Woodpecker, Headlamp and Velero from this
repository. Change them with a commit; a manual `helm upgrade` is reverted by
self-heal.

Bootstrap-critical components stay imperative because GitOps cannot install
itself: Envoy Gateway, Keycloak, Vault, Forgejo, and ArgoCD.

Developer apps are discovered by the `forgejo-workloads` ApplicationSet: a matrix
of Forgejo repositories in the `devhub` organisation × clusters labelled
`devhub.io/role=workload`. Forgejo implements the Gitea API, so ArgoCD's `gitea`
SCM provider is the right one. Registering a workload cluster is therefore all it
takes to start receiving apps — no manifest edit.

---

## 6. Workload clusters

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

## 7. Network and access model

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

---

## 8. Routing (Gateway API)

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

## 9. Alerting

Alertmanager routes to Slack via a webhook stored in Vault:

```bash
vault kv put secret/platform/alertmanager webhook-url=https://hooks.slack.com/services/...
kubectl annotate externalsecret alertmanager-slack -n monitoring \
  force-sync="$(date +%s)" --overwrite
```

With an empty webhook the config still loads and alerts remain visible in the
Alertmanager UI — but nothing is delivered, so set it.

Platform rules (`k8s/base/devops/monitoring/platform-alerts.yaml`) cover a sealed
Vault, certificates that stopped renewing, stuck or degraded ArgoCD apps, failed
or missing backups, filling PVCs and crash-looping platform pods.

Metrics retention is 30 days on a local PVC. For anything longer, set
`prometheus.prometheusSpec.remoteWrite` in the cloud overlay (Amazon Managed
Prometheus, Azure Monitor, Google Cloud Managed Prometheus, Grafana Cloud).

Logs go to Loki, which runs multi-tenant (`auth_enabled: true`): the platform
cluster writes tenant `platform`, each workload cluster writes its environment
name. Grafana queries with `X-Scope-OrgID`. On managed clouds Loki stores chunks
in object storage; without the cloud identity it falls back to a local PVC and
loses history on pod recycle — the deploy log says which mode is active.

---

## 10. Cost controls

- Node pools autoscale (EKS cluster-autoscaler, AKS/GKE built-in).
- CI runs on a **spot/preemptible, scale-to-zero** pool (`role=ci`, taint
  `workload=ci`).
- Dev environments use a single NAT gateway; prod uses one per AZ
  (`nat_gateway_per_az`).
- Loki chunks and Velero backups expire via bucket lifecycle rules
  (`log_retention_days`, `backup_retention_days`).

---

## 11. Routine checks

```bash
./deploy.sh --env <env> all status     # pods, Vault seal state, backups, GitOps
velero backup get
kubectl get externalsecrets -A          # SecretSynced?
kubectl get certificates -A             # Ready?
kubectl get gateway,httproute -A        # Programmed / Accepted?
kubectl get clusterpolicy               # Kyverno policies Ready?
kubectl get applications -n argocd      # Synced/Healthy?
```

## 12. Known deprecations

Things upstream has flagged, with the plan for each. Check this list when bumping
chart versions.

| Component | Status | Plan |
|---|---|---|
| `grafana/tempo` (single binary) | Chart deprecated in favour of `grafana/tempo-distributed` | Kept: tempo-distributed splits into 5–6 deployments for a trace volume that fits in one pod. Migrate when the chart stops tracking Tempo releases — same buckets, same OTLP endpoint, only `tempo-values.yaml` and the chart name change. |
| Forgejo state on a PersistentVolume | Not deprecated, but the only option | Forgejo speaks S3 or local disk; Azure Blob and GCS have no S3 API. Durability comes from Velero plus managed-PostgreSQL PITR. A very large registry means a bigger volume or a dedicated registry (zot/Harbor). |
