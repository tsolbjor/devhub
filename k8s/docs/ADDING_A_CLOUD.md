# Adding a Cloud

Everything cloud-specific in this repo sits behind the same few seams: one tofu
module, one overlay directory, and a `case "$CLOUD"` arm in four scripts. Adding a
fifth provider is additive — no existing cloud's code changes.

Read [CLOUD_CAPABILITIES.md](CLOUD_CAPABILITIES.md) first. It records which security
properties each cloud actually delivers, and the answers you give in section 1
below decide which row your new cloud lands on.

---

## 1. Decide four things before writing code

These are design decisions, not typing. Getting them wrong is the only expensive
part of adding a cloud.

**a) How do workloads get cloud credentials?**

Four service accounts need cloud access: `monitoring/loki` (log chunks),
`velero/velero` (backups), `vault/vault` (unseal key) and
`external-dns/external-dns` (DNS records). Forgejo needs none — it keeps its state
on a PersistentVolume.

- *Best case* — the provider federates an OIDC/ServiceAccount token into its own
  IAM (AWS IRSA, GCP/Azure Workload Identity). No secrets exist. Mirror the
  existing pattern: a role/identity per service account, annotated on the SA.
- *Fallback* — API keys. Then create one scoped key per service in tofu, write
  them to `secrets.env`, push them into Vault (`secret/platform/*`), and deliver
  them with ExternalSecrets. Never put them in an overlay values file, and record
  the regression in CLOUD_CAPABILITIES.md.

**b) Can Vault auto-unseal?**

Vault supports `awskms`, `azurekeyvault`, `gcpckms`, `alicloudkms`, `ocikms`,
`transit` and `pkcs11`. A provider having a KMS product is not enough — Vault needs
a matching seal type. If there is none, the options are manual unseal (already
supported, and `setup-vault.sh` warns about it) or a `transit` seal against another
Vault. Say which one in the docs; do not leave it implied.

**c) How is the API server restricted?**

`api_allowed_cidrs` is a required variable with no default, and every cloud must
honour it: `[]` means no public endpoint, a non-empty list means allow-listed. Find
the provider's equivalent (allow-list resource, private-endpoint flag, cluster ACL)
before you start — if there is none, the cloud cannot meet the repo's baseline and
that belongs in the capability matrix, loudly.

**d) Where does tofu state live, and does it lock?**

S3-compatible object storage works with the `s3` backend plus the skip-flags the
UpCloud module uses (`tofu/upcloud/dev/backend.hcl.example` is the template).
Locking needs either DynamoDB (AWS), native leases (Azure/GCS), or
`use_lockfile = true` for S3-compatible stores.

---

## 2. Infrastructure module

```
tofu/<cloud>/
├── modules/cluster/
│   ├── main.tf        network, cluster, node pools, PostgreSQL, cache, object storage
│   ├── platform.tf    Loki storage, Velero storage, Vault unseal key + identities
│   ├── variables.tf   sizing, retention, api_allowed_cidrs, ci_node_*
│   ├── outputs.tf     everything sync-tofu-outputs.sh reads
│   └── providers.tf   required_providers
├── dev/  prod/  workload/
│   ├── main.tf                    module call with per-tier sizing
│   ├── outputs.tf                 re-export of the module outputs
│   ├── providers.tf               provider config + region variable
│   ├── backend.tf                 partial backend block
│   ├── backend.hcl.example        bootstrap commands in comments
│   ├── variables-api-access.tf    api_allowed_cidrs (no default, on purpose)
│   └── terraform.tfvars.example
```

Copy the closest existing cloud: **AWS** if the provider has IAM-role federation,
**UpCloud** if it uses API keys and S3-compatible storage.

### Outputs the scripts expect

Required for every cloud:

| Output | Used for |
|---|---|
| `cluster_name` | kubeconfig fetch, `require_cluster_match` |
| `pg_host`, `pg_port` | Keycloak + Forgejo databases |
| `pg_admin_login`, `pg_admin_password` | `deploy.sh db-users` |
| `pg_keycloak_password`, `pg_forgejo_password` | K8s secrets |
| `oidc_issuer_url` | Vault JWT auth for workload clusters |

Cache and object storage names vary by cloud (`redis_host` / `valkey_host`,
`s3_endpoint` / bucket prefixes). Optional but expected if the capability exists:
`loki_*`, `velero_*`, `vault_kms_*` and `external_dns_*` identities.

Mark every credential output `sensitive = true`.

### Baseline the module must implement

- `api_allowed_cidrs` honoured (see 1c)
- control-plane audit logs enabled if the provider offers them
- database and cache on a private network, TLS + auth on the cache
- backup retention variables (`backup_retention_days`, `log_retention_days`)
- a tainted, scale-to-zero CI node pool (`role=ci`, taint `workload=ci`) — this is
  what keeps untrusted CI containers off the nodes running Vault and Keycloak
- object storage buckets with public access blocked, encryption, and lifecycle
  expiry on backup/log buckets

---

## 3. Script wiring

Four scripts contain `case "$CLOUD"` arms. Add one arm to each; nothing else moves.

**`k8s/scripts/lib/common.sh`**

- add the environments to `PLATFORM_ENVS` and `WORKLOAD_ENVS`
- add any new placeholders to `TEMPLATE_VARS` **and** to the defaults loop in
  `default_infra_vars` — an unlisted `${VAR}` is left as literal text in rendered
  Helm values, and `validate-overlays.sh` fails the build for exactly this reason

`env_cloud()` derives the cloud from the environment name prefix, so no change there.

**`k8s/scripts/sync-tofu-outputs.sh`** — one arm mapping tofu outputs to
`tofu-outputs.env` (public) and `secrets.env` (credentials), plus a `fetch_kubeconfig`
case using the provider CLI.

**`k8s/scripts/setup-env.sh`** — one arm for `render_backend`, the prompts in the
"State storage and cloud settings" block, `render_tfvars`, `state_store_exists` and
`create_state_store`, plus a `load_existing` arm so re-runs prefill.

**`k8s/scripts/deploy.sh`** — the arms are already there, keyed by capability:

| Function | What to add |
|---|---|
| `install_storage_class` | only if the provider ships no usable default StorageClass |
| `create_db_users` | forgejo + keycloak database users, unless the provider's tofu creates them |
| `install_vault` | the `apply_autounseal` case, if there is a Vault seal type |
| `install_monitoring` | the `apply_loki_overlay` case, if Loki can use object storage |
| `install_velero` | the `have_target` case |
| `install_cluster_autoscaler` | only if the autoscaler is not part of the managed control plane |
| `create_db_users` | skip only if the provider's tofu resources create DB users |

**`k8s/scripts/deploy-workload.sh`** — the `install_external_dns` arm (credential
check) and nothing else; it reuses the shared overlay values.

**`k8s/scripts/quickstart.sh`** — one entry in `select_env`. The step table is
cloud-agnostic, but if the new cloud lacks a step (no db-users, say), extend that
detector the way `det_dbusers` already skips local and UpCloud.

`devhub` needs **no** change: `tofu_dir()` derives paths from the environment name.
CI needs **no** change: the workflow globs `tofu/*/dev`, `tofu/*/prod`, `tofu/*/workload`.

---

## 4. Overlays

```
k8s/overlays/<cloud>/devops/          shared Helm overrides for the cloud
k8s/overlays/<cloud>-dev/             config.yaml + devops -> ../<cloud>/devops symlink
k8s/overlays/<cloud>-prod/            same
k8s/overlays/<cloud>-workload/        config.yaml only
```

Copy `k8s/overlays/upcloud/devops/` (API-key clouds) or `aws/devops/` (federated
clouds) and adjust. A cloud overlay holds only what is genuinely per-cloud:
`cert-manager/values.yaml` (the DNS-01 solver), `external-dns/values.yaml` (the
provider), `velero/values.yaml`, `monitoring/loki-values.yaml` and
`vault/vault-autounseal-values.yaml` where the capability exists.

Everything else is in `k8s/base/devops/` and needs no per-cloud file: the Gateway
and its HTTPRoutes, ArgoCD, the monitoring stack, Vault. Those used to be copied
per cloud and were byte-identical, which is how the `apps` wildcard listener came
to exist in one cloud only. An overlay file still wins where one exists — `local`
uses that for its own Gateway and self-signed CA — so reach for one only when the
value truly differs.

Routing is Gateway API: `k8s/base/devops/gateway.yaml` holds one listener per
platform hostname and `httproutes.yaml` one route per service — shared, so a new
cloud gets both for free. Only override them in the overlay if this cloud's TLS
secret or listener set genuinely differs.

Create the symlinks, not copies:

```bash
cd k8s/overlays/<cloud>-dev && ln -s ../<cloud>/devops devops
```

Use `${CLUSTER_ISSUER}` rather than a hardcoded `letsencrypt-prod`, and reference
bucket/identity values through the placeholders `sync-tofu-outputs.sh` provides.

---

## 5. Verify before claiming it works

```bash
tofu fmt -recursive tofu/
for d in tofu/<cloud>/{dev,prod,workload}; do
  (cd "$d" && tofu init -backend=false && tofu validate)
done

./devhub validate                              # YAML, config keys, placeholders
./devhub validate --helm <cloud>-dev           # every chart renders with these overlays
./devhub quickstart --env <cloud>-dev --status  # checklist reflects reality

# With any cluster reachable, schema-check the manifests the scripts apply:
kubectl apply --dry-run=server -f k8s/base/devops/policy/network-policies.yaml
```

`--helm` substitutes placeholder values for anything tofu would supply, so it
catches an unrendered `${VAR}` or a chart that rejects your overlay without needing
an account.

What none of this proves: that the provider accepts the resource arguments, or that
an apply succeeds. Only `tofu plan` against a real account shows that. Say which of
the two you have done when you hand the work over.

---

## 6. Documentation — part of the change, not a follow-up

- `k8s/docs/<CLOUD>_SETUP.md` — copy the closest existing guide
- `k8s/docs/CLOUD_CAPABILITIES.md` — add the row, including the gaps
- `README.md` — environment table
- `CLAUDE.md` — managed services table, keyless-access section, directory layout
- `k8s/docs/OPERATIONS.md` — only if state or backup handling differs

A cloud whose capability row is missing is worse than no cloud: someone will assume
it has the same guarantees as AWS.

---

## 7. Worked example: Scaleway

Answering section 1 for Scaleway (Kapsule, Managed Database for PostgreSQL, Managed
Redis, Object Storage, Managed DNS):

| Decision | Answer | Consequence |
|---|---|---|
| Workload credentials | No OIDC→IAM federation; scoped IAM applications + API keys | Five services move to static keys held in Vault, delivered by ExternalSecrets. Rotation becomes a documented procedure |
| Vault seal | No `scaleway` seal type in Vault | Manual unseal, or a `transit` seal against another Vault. `VaultSealed` alerting matters more here |
| API restriction | Cluster ACLs in recent provider versions | Verify the resource name against the provider docs, then wire `api_allowed_cidrs` to it |
| State backend | Object Storage is S3-compatible | Copy `tofu/upcloud/*/backend.hcl.example`, keep `use_lockfile = true` |

Everything else transfers: Object Storage is S3-compatible, so the AWS-shaped Loki
and Velero configuration works with an endpoint override; external-dns has a native
`scaleway` provider; cert-manager HTTP01 is unchanged.

Rough effort: half a day for the tofu module, two hours of script wiring, an hour of
overlays, an hour of docs. The static-key handling is the part that deserves review
attention, because it is the one place Scaleway is weaker than the other four.
