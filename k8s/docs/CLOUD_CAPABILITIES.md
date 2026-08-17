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
| Kubernetes | UCS | AKS | GKE | EKS | Rancher Desktop / k3s |
| PostgreSQL | Managed PG | Flexible Server | Cloud SQL | RDS | StatefulSet |
| Cache | Valkey | Cache for Redis | Memorystore | ElastiCache | StatefulSet |
| Object storage | S3-compatible | Blob | GCS | S3 | MinIO |
| Cache TLS + auth | ✓ | ✓ | ✓ (auth) | ✓ | auth only |
| DB users created by tofu | ✓ | — (`devhub db-users`) | — (`devhub db-users`) | — (`devhub db-users`) | init SQL |

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
| Loki chunks in object storage | **—** local PVC | ✓ | ✓ | ✓ | — local PVC |
| Velero cluster backups | **—** | ✓ | ✓ | ✓ | — |
| Vault raft snapshots (CronJob) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Forgejo state (repos, packages, registry) | PVC + Velero | PVC + Velero | PVC + Velero | PVC + Velero | PVC only |
| Node autoscaling | fixed pool | ✓ built-in | ✓ built-in | ✓ cluster-autoscaler | n/a |
| Spot/preemptible CI pool | ✓ (on-demand) | ✓ Spot | ✓ Spot | ✓ Spot | n/a |
| Default StorageClass | provider | provider | provider | ✓ gp3 (installed here) | provider |
| external-dns provider | Cloudflare | Azure DNS | Cloud DNS | Route53 | — |
| Gateway API (Envoy Gateway) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Wildcard app certificates (DNS-01) | — Cloudflare solver, manual | ✓ | ✓ | ✓ | n/a (local CA) |
| Kyverno policy enforcement | ✓ | ✓ | ✓ | ✓ | ✓ |
| Managed DNS used directly | — | ✓ | ✓ | ✓ | — |

---

## Known gaps and what to do about them

### UpCloud: no Loki object storage, no Velero, no Vault auto-unseal

The UpCloud module provisions object storage but not the Loki or Velero buckets,
and UpCloud has no Vault seal type. Consequences and mitigations:

- **Logs** live on a 10Gi PVC and are lost when the Loki pod is replaced. Mitigate
  by adding a Loki bucket + access key to `tofu/upcloud/modules/cluster` and an
  `overlays/upcloud/devops/monitoring/loki-values.yaml` using the S3 backend with a
  custom endpoint (the AWS overlay is the template; credentials come from a key, not
  a role).
- **No cluster-object backups.** Managed PostgreSQL has its own backups, and Vault
  snapshots run, but Kubernetes objects and PVCs are not backed up. Same fix
  shape: a Velero bucket + key, then `overlays/upcloud/devops/velero/values.yaml`.
- **Vault needs 3 of 5 unseal keys after every restart.** `setup-vault.sh` prints
  the keys once and writes them to a mode-600 gitignored file; move that file to
  offline storage. Watch the `VaultSealed` alert — on this cloud it is not
  theoretical.

Until those exist, `deploy.sh` skips Velero and the Loki overlay with a warning
rather than failing, so the platform still comes up.

### Forgejo keeps its state on a volume, not in object storage

Forgejo supports local disk or S3-compatible object storage only — Azure Blob and
GCS have no S3 API. Running two storage models (S3 on AWS/UpCloud, volume on
Azure/GCP) would double the failure modes for no real gain, so every cloud uses the
PersistentVolume. Durability comes from Velero (daily full + hourly platform state,
which includes the `forgejo` namespace) and the managed PostgreSQL's own PITR.

If a cluster grows a very large registry, the alternatives are a bigger volume or
introducing a dedicated registry (zot or Harbor) with an S3 backend.

### UpCloud: no DNS-01 solver for wildcard certificates

cert-manager has no UpCloud DNS solver, and UpCloud has no DNS product — the
platform expects Cloudflare. Platform hostnames still work (HTTP-01 per listener),
but the workload cluster's wildcard certificate needs a Cloudflare solver and an API
token secret, created by hand.

### Clouds without keyless credentials

Where a provider cannot federate a ServiceAccount token into its IAM, four service
accounts need API keys: `monitoring/loki`, `velero/velero`, `vault/vault` and
`external-dns/external-dns`. The required handling:

1. one scoped IAM identity + key per service, created by tofu
2. keys written to `k8s/scripts/<env>/secrets.env` (mode 600, gitignored)
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
- **Lowest cost / EU-only footprint** — UpCloud, accepting the three gaps above.
- **Fastest to try** — local.

Adding a cloud, or closing one of the gaps above, follows the same checklist:
[ADDING_A_CLOUD.md](ADDING_A_CLOUD.md).
