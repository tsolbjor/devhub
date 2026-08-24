# Cloud Capabilities

What each target actually delivers. The platform is deliberately uniform where it
can be, but not every cloud offers the same primitives, and pretending otherwise
would mean assuming AWS-level guarantees on a cloud that cannot provide them.

Read this before choosing a target, and update it in the same change as any new
cloud (see [ADDING_A_CLOUD.md](ADDING_A_CLOUD.md)).

Legend: **✓** implemented · **—** not available on this cloud · **n/a** not applicable

---

## Managed services

| | UpCloud | Azure | GCP | AWS | local |
|---|---|---|---|---|---|
| Kubernetes | UCS | AKS (`patch` upgrade channel) | GKE (`STABLE` channel) | EKS 1.33 (explicit) | Rancher Desktop / k3s |
| PostgreSQL | Managed PG | Flexible Server | Cloud SQL | RDS | StatefulSet |
| PostgreSQL PITR | provider backups | ✓ | ✓ `point_in_time_recovery_enabled` | ✓ | — |
| PostgreSQL TLS required | ✓ | ✓ | ✓ `ssl_mode = ENCRYPTED_ONLY` | ✓ | — |
| Cache | Valkey (**opt-in**) | Managed Redis (**opt-in**) | Memorystore (**opt-in**) | ElastiCache (**opt-in**) | StatefulSet |
| Object storage | S3-compatible | Blob | GCS | S3 | MinIO |
| Cache TLS + auth | ✓ | ✓ (Entra-only) | ✓ auth + transit encryption | ✓ | auth only |
| DB users created by tofu | ✓ | — (`devhub db-users`) | — (`devhub db-users`) | — (`devhub db-users`) | init SQL |

### The managed cache is opt-in, and off by default

Nothing on the platform consumes a Redis/Valkey cache — Keycloak, Forgejo,
Woodpecker and ArgoCD all use PostgreSQL or their own storage. It was being
provisioned anyway, which is a standing cost and a standing attack surface for a
service with no client. On **all four clouds** it is now behind `enable_cache`,
which defaults to `false`:

```hcl
enable_cache = true      # only if your workloads actually need it
```

With it off, the cache outputs (`redis_host` / `redis_port` on AWS, Azure and
GCP; `valkey_host` / `valkey_port` / `valkey_password` on UpCloud) are `null`
and `sync-tofu-outputs.sh` leaves `REDIS_HOST` / `VALKEY_HOST` empty. Nothing on
the platform notices — no script, base manifest or overlay reads them.

Note that developer apps are unaffected either way: the `devhub-app` chart gives
each app its own in-cluster Redis, and apps run on the workload cluster, which
has no network path to the platform VPC's managed cache.

### Node counts on GKE are cluster totals

GKE node pools use `total_min_node_count` / `total_max_node_count`, so the
`node_count` / `node_min_count` / `node_max_count` numbers in
`tofu/gcp/{dev,prod}` are the size of the **whole pool**, not per zone. A
regional cluster no longer silently multiplies them by the number of zones —
worth re-reading your plan once if you set those numbers under the old
behaviour. GKE nodes also run under a dedicated minimal service account rather
than the project's default Compute service account.

---

## Security

| | UpCloud | Azure | GCP | AWS | local |
|---|---|---|---|---|---|
| API server allow-list (`api_allowed_cidrs`) | ✓ control-plane IP filter | ✓ authorized ranges | ✓ authorized networks | ✓ public access CIDRs | n/a |
| Private API endpoint (`api_allowed_cidrs = []`) | — filter only | ✓ private cluster | ✓ private endpoint | ✓ VPC-only | n/a |
| Private nodes | ✓ | ✓ (VNet) | ✓ + Cloud NAT | ✓ private subnets | n/a |
| **Keyless workload credentials** | **— API keys** | ✓ Workload Identity | ✓ Workload Identity | ✓ IRSA | n/a |
| etcd Secret encryption with own key | — | provider-managed | provider-managed | ✓ KMS | — |
| Cluster auth via IdP, local admin disabled | — | ✓ Azure RBAC + `local_account_disabled` | provider IAM | EKS access entries | n/a |
| Control-plane audit logs | provider default | provider default | provider default | ✓ explicit | — |
| **Vault auto-unseal** | **— manual** | ✓ Key Vault | ✓ Cloud KMS | ✓ KMS | — manual |
| Keycloak upstream IdP | — (local users) | ✓ Entra ID, roles → groups | ✓ Google (manual groups) | ✓ Cognito, groups → groups | — |
| MFA on the upstream IdP | — | tenant policy | Google account policy | ✓ `cognito_mfa_configuration` (`OFF`/`OPTIONAL`/`ON`) | — |

Cloud-independent, and identical everywhere: NetworkPolicies with default-deny
ingress per namespace; CI jobs in `woodpecker-ci` on a tainted node pool with the cloud
metadata endpoint and RFC1918 blocked; non-privileged rootless builds; Vault
reachable only from the gateway, External Secrets and Prometheus; Headlamp read-only
without Secret or exec access; Kyverno-generated quotas, limits and
NetworkPolicies per app namespace;
Vault as the source of truth for platform credentials via External Secrets.

---

## Platform components

| | UpCloud | Azure | GCP | AWS | local |
|---|---|---|---|---|---|
| Loki chunks in object storage | ✓ (access key) | ✓ | ✓ | ✓ | — local PVC |
| Velero cluster backups | ✓ (FS backup) | ✓ | ✓ | ✓ | — |
| Vault raft snapshots (CronJob) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Forgejo state (repos, packages, registry) | PVC + Velero | PVC + Velero | PVC + Velero | PVC + Velero | PVC only |
| Node autoscaling | fixed pool | ✓ built-in | ✓ built-in | ✓ cluster-autoscaler | n/a |
| Spot/preemptible CI pool | ✓ (on-demand) | ✓ Spot | ✓ Spot | ✓ Spot | n/a |
| Default StorageClass | provider | provider | provider | ✓ gp3 (installed here) | provider |
| external-dns provider | Cloudflare | Azure DNS | Cloud DNS | Route53 | — |
| Gateway API (Envoy Gateway) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Wildcard app certificates (DNS-01) | — Cloudflare solver, manual | ✓ Workload Identity | ✓ Workload Identity | ✓ IRSA (Route53) | n/a (local CA) |
| cert-manager cloud identity | — (Cloudflare API token secret) | ✓ | ✓ | ✓ | n/a |
| Workload-cluster Vault JWT trust (own OIDC issuer) | **— no issuer output** | ✓ | ✓ | ✓ | n/a |
| Kyverno policy enforcement | ✓ | ✓ | ✓ | ✓ | ✓ |
| Managed DNS used directly | — | ✓ | ✓ | ✓ | — |

---

## Known gaps and what to do about them

### UpCloud: access keys instead of workload identity, no Vault auto-unseal

UpCloud's Managed Object Storage has no workload identity, so Loki and Velero
each get a dedicated object-storage user with a bucket-scoped policy and an
access key (`tofu/upcloud/modules/cluster`). The keys flow through
`secrets.env` into Kubernetes Secrets (`loki-objstore-credentials`,
`velero-objstore-credentials`) — never into values files or git. Remaining
differences from the other clouds:

- **Velero uses file-system backups** (kopia via the node agent) — there is no
  UpCloud volume-snapshot plugin. FS backup only reaches volumes mounted by a
  running pod: an unmounted PVC, such as `vault-snapshots` between CronJob
  runs, is not captured. The Vault raft data itself (mounted by `vault-0`) is.
- **Vault needs 3 of 5 unseal keys after every restart** — UpCloud has no
  Vault seal type. `setup-vault.sh` writes the keys to a mode-600 gitignored
  file and deliberately does *not* print them (the quickstart tees script output
  to a log file, which would have made a second plaintext copy); read them with
  `jq -r '.unseal_keys_b64[]' _setup/<env>/vault-init-keys.json` and move the
  file to offline storage. Watch the `VaultSealed` alert — on this cloud it is
  not theoretical, and it now fires reliably (Vault's metrics endpoint had no
  telemetry stanza, so that alert could never fire before).
- **Key rotation is manual**: taint the
  `upcloud_managed_object_storage_user_access_key` resource, re-apply, re-run
  `sync` and `deploy` for the affected components.

If the tofu outputs lack the buckets or keys (module not yet re-applied),
`deploy.sh` skips Velero and the Loki overlay with a warning rather than
failing, so the platform still comes up.

### Forgejo keeps its state on a volume, not in object storage

Forgejo supports local disk or S3-compatible object storage only — Azure Blob and
GCS have no S3 API. Running two storage models (S3 on AWS/UpCloud, volume on
Azure/GCP) would double the failure modes for no real gain, so every cloud uses the
PersistentVolume. Durability comes from Velero (daily full + hourly platform state,
which includes the `forgejo` namespace) and the managed PostgreSQL's own PITR.

If a cluster grows a very large registry, the alternatives are a bigger volume or
introducing a dedicated registry (zot or Harbor) with an S3 backend.

### DNS-01 wildcard certificates: wired on Azure, GCP and AWS

The `*.{domain}` certificate a workload cluster's Gateway needs can only be issued
over DNS-01, and DNS-01 means cert-manager has to write a TXT record in the
cloud's DNS zone. That identity now exists on all three managed clouds, created by
tofu alongside the external-dns one:

| Cloud | Identity | Grant |
|---|---|---|
| AWS | IAM role + OIDC trust for `cert-manager/cert-manager` (IRSA) | Route53 record changes on the zone |
| GCP | service account + Workload Identity binding | `roles/dns.admin` |
| Azure | user-assigned identity + federated credential | DNS Zone Contributor |

Exported as `cert_manager_role_arn` / `cert_manager_gsa_email` /
`cert_manager_identity_client_id`, reaching the ClusterIssuer through
`${CERT_MANAGER_ROLE_ARN}` and friends. Before this the table claimed DNS-01 and
there was no identity behind it: issuance failed at the DNS challenge with a
permission error, on a code path nothing exercises until an app is deployed to a
workload cluster.

### UpCloud: no DNS-01 solver for wildcard certificates

cert-manager has no UpCloud DNS solver, and UpCloud has no DNS product — the
platform expects Cloudflare. Platform hostnames still work (HTTP-01 per listener),
but the workload cluster's wildcard certificate needs a Cloudflare solver and an API
token secret, created by hand.

### UpCloud prod is single-zone, and its Valkey is a single node

`tofu/upcloud/prod` sets `zone = "de-fra1"` — one zone, for the cluster and for
the managed data services. UpCloud Managed Kubernetes has no multi-zone control
plane to spread across, so a zone outage is a full outage of a prod environment,
not a degraded one. The Valkey plan is `1x1xCPU-2GB`: a single node, no replica,
no failover — a restart is a cache outage (harmless today, since nothing on the
platform uses it; see "the managed cache is opt-in" above).

Neither is a bug, but neither should be discovered from a status page. If
single-zone prod is not acceptable, that is an argument for one of the other three
clouds rather than something to configure here.

### `upcloud-workload` has no Vault JWT trust

`register-workload-cluster.sh` normally creates a Vault JWT auth mount that trusts
the workload cluster's **own OIDC issuer**, so the cluster's ServiceAccount tokens
authenticate to the platform Vault with no static credential to leak or rotate.
That needs the cluster's issuer URL, and the UpCloud provider does not expose one:
`upcloud_kubernetes_cluster` (checked at v5.43.0) has no OIDC issuer or JWKS
attribute, so `tofu/upcloud/workload/outputs.tf` deliberately has no
`oidc_issuer_url` output and `sync-tofu-outputs.sh` leaves `OIDC_ISSUER_URL`
empty. AWS, Azure and GCP all export it.

The consequence: **External Secrets on an `upcloud-workload` cluster has no
keyless path to the platform Vault.** The `ClusterSecretStore` cannot authenticate,
its ExternalSecrets do not sync, and apps that expect `secret/apps/*` — including
the shared OIDC gateway secret and the registry pull token — come up without them.

What to do instead, in order of preference:

1. **Put workload apps on a cloud that exports an issuer.** A workload cluster is
   the cheap, disposable half of the platform; this is the one gap that is easier
   to move away from than to work around.
2. **A Kubernetes auth mount instead of JWT.** Vault's `kubernetes` auth method
   validates tokens by calling the cluster's TokenReview API rather than by
   verifying a JWT against a public issuer, so it needs no issuer URL — but it
   does need the platform Vault to reach the workload cluster's API server, and a
   reviewer JWT + CA cert configured by hand. Still no long-lived app credential.
3. **A scoped AppRole or a static token**, delivered as a Kubernetes Secret in the
   workload cluster. This is what the platform was built to avoid: it is a
   credential that must be rotated by someone, and it is worth the same as the
   Vault policy behind it. Scope it to `apps/*` only, set a TTL, and write down
   who rotates it.

Do not simply leave it: the failure mode is apps starting with missing secrets,
which reads as an application bug rather than a platform gap.

### Clouds without keyless credentials

Where a provider cannot federate a ServiceAccount token into its IAM, four service
accounts need API keys: `monitoring/loki`, `velero/velero`, `vault/vault` and
`external-dns/external-dns`. The required handling:

1. one scoped IAM identity + key per service, created by tofu
2. keys written to `_setup/<env>/secrets.env` (mode 600, gitignored)
3. pushed into Vault under `secret/platform/*`
4. delivered to namespaces by ExternalSecrets

Never in an overlay values file, never in git. Rotation is then `vault kv put` plus a
rollout restart, and the key's blast radius is one service.

### local

No cloud services by design: in-cluster PostgreSQL, Valkey and MinIO, a local CA
instead of Let's Encrypt, no external-dns, no Velero. It is for developing against
the platform, not for testing its cloud behaviour.

---

## Choosing a target

- **Strictest security posture** — AWS: keyless access for every service, etcd
  Secrets encrypted with your own KMS key, Vault auto-unseal, explicit audit logs.
- **Best identity story** — Azure: Entra ID both as the cluster's own RBAC provider
  (with the local admin account disabled) and as Keycloak's upstream IdP.
- **Simplest private networking** — GCP: private nodes plus Cloud NAT, private
  Cloud SQL and Memorystore, one Workload Identity mechanism throughout.
- **Lowest cost / EU-only footprint** — UpCloud, accepting manual Vault unseal,
  access keys instead of workload identity, and Cloudflare for DNS.
- **Fastest to try** — local.

Adding a cloud, or closing one of the gaps above, follows the same checklist:
[ADDING_A_CLOUD.md](ADDING_A_CLOUD.md).
