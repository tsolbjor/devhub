# Router for the private network
resource "upcloud_router" "kubernetes" {
  name = "${var.prefix}-${var.cluster_name}-router"
}

# Gateway for internet connectivity
resource "upcloud_gateway" "kubernetes" {
  name     = "${var.prefix}-${var.cluster_name}-gateway"
  zone     = var.zone
  features = ["nat"]
  router {
    id = upcloud_router.kubernetes.id
  }
}

# Private network for the Kubernetes cluster
resource "upcloud_network" "kubernetes" {
  name   = "${var.prefix}-${var.cluster_name}-network"
  zone   = var.zone
  router = upcloud_router.kubernetes.id

  ip_network {
    address            = var.network_cidr
    dhcp               = true
    dhcp_default_route = true
    family             = "IPv4"
    gateway            = cidrhost(var.network_cidr, 1)
  }

  depends_on = [upcloud_gateway.kubernetes]
}

# Kubernetes cluster
resource "upcloud_kubernetes_cluster" "main" {
  name                    = "${var.prefix}-${var.cluster_name}"
  zone                    = var.zone
  network                 = upcloud_network.kubernetes.id
  control_plane_ip_filter = var.control_plane_ip_filter

  private_node_groups = true
}

# Node group for worker nodes
resource "upcloud_kubernetes_node_group" "workers" {
  cluster       = upcloud_kubernetes_cluster.main.id
  name          = "${var.prefix}-${var.cluster_name}-workers"
  node_count    = var.node_count
  plan          = var.node_plan
  anti_affinity = var.node_count > 1
  labels = {
    prefix  = var.prefix
    cluster = var.cluster_name
    role    = "platform"
    env     = lookup(var.tags, "Environment", "dev")
  }
}

# Tainted node group for CI jobs — keeps build containers off the nodes running
# Vault, Keycloak and PostgreSQL.
resource "upcloud_kubernetes_node_group" "ci" {
  count = var.ci_node_count > 0 ? 1 : 0

  cluster       = upcloud_kubernetes_cluster.main.id
  name          = "${var.prefix}-${var.cluster_name}-ci"
  node_count    = var.ci_node_count
  plan          = var.ci_node_plan
  anti_affinity = var.ci_node_count > 1

  labels = {
    prefix  = var.prefix
    cluster = var.cluster_name
    role    = "ci"
    env     = lookup(var.tags, "Environment", "dev")
  }

  taint {
    effect = "NoSchedule"
    key    = "workload"
    value  = "ci"
  }
}

# ─── Managed PostgreSQL ──────────────────────────────────────────────

resource "upcloud_managed_database_postgresql" "main" {
  name  = "${var.prefix}-postgresql"
  plan  = var.pg_plan
  title = "${var.prefix} PostgreSQL"
  zone  = var.zone

  termination_protection = var.termination_protection

  network {
    family = "IPv4"
    name   = "pg-private"
    type   = "private"
    uuid   = upcloud_network.kubernetes.id
  }

  properties {
    public_access = false
    version       = var.pg_version
  }

  labels = var.tags
}

resource "upcloud_managed_database_logical_database" "keycloak" {
  service = upcloud_managed_database_postgresql.main.id
  name    = "keycloak"
}

resource "upcloud_managed_database_logical_database" "forgejo" {
  service = upcloud_managed_database_postgresql.main.id
  name    = "forgejo"
}

resource "upcloud_managed_database_user" "keycloak" {
  service  = upcloud_managed_database_postgresql.main.id
  username = "keycloak"
}

resource "upcloud_managed_database_user" "forgejo" {
  service  = upcloud_managed_database_postgresql.main.id
  username = "forgejo"
}

# ─── Managed Valkey ──────────────────────────────────────────────────

resource "upcloud_managed_database_valkey" "main" {
  name  = "${var.prefix}-valkey"
  plan  = var.valkey_plan
  title = "${var.prefix} Valkey"
  zone  = var.zone

  termination_protection = var.termination_protection

  network {
    family = "IPv4"
    name   = "valkey-private"
    type   = "private"
    uuid   = upcloud_network.kubernetes.id
  }

  properties {
    public_access = false
  }

  labels = var.tags
}

# ─── Managed Object Storage ─────────────────────────────────────────

resource "upcloud_managed_object_storage" "main" {
  name              = "${var.prefix}-objsto"
  region            = var.objstore_region
  configured_status = "started"

  network {
    family = "IPv4"
    name   = "objsto-private"
    type   = "private"
    uuid   = upcloud_network.kubernetes.id
  }

  labels = var.tags
}

# NOTE: Forgejo keeps repositories, LFS objects, packages and container registry
# blobs on its PersistentVolume. Forgejo supports local disk or S3-compatible
# storage only — Azure Blob and GCS have no S3 API — so rather than run two
# storage models, every cloud uses the volume, and Velero backs it up alongside
# the managed PostgreSQL PITR.

# Buckets and scoped credentials for the platform services that use object
# storage: Loki (log chunks) and Velero (backups). UpCloud has no workload
# identity for Managed Object Storage, so each service gets its own user, a
# policy limited to its bucket, and an access key. The keys land in the
# gitignored secrets.env via sync-tofu-outputs.sh and become Kubernetes
# Secrets; they never enter values files or git.
locals {
  objsto_services = toset(["loki", "velero"])
}

resource "upcloud_managed_object_storage_bucket" "platform" {
  for_each = local.objsto_services

  service_uuid = upcloud_managed_object_storage.main.id
  name         = "${var.prefix}-${each.key}"
}

resource "upcloud_managed_object_storage_user" "platform" {
  for_each = local.objsto_services

  service_uuid = upcloud_managed_object_storage.main.id
  username     = each.key
}

resource "upcloud_managed_object_storage_policy" "platform" {
  for_each = local.objsto_services

  service_uuid = upcloud_managed_object_storage.main.id
  name         = "${each.key}-bucket-rw"
  description  = "Read/write limited to the ${each.key} bucket"
  document = urlencode(jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = "arn:aws:s3:::${upcloud_managed_object_storage_bucket.platform[each.key].name}"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "arn:aws:s3:::${upcloud_managed_object_storage_bucket.platform[each.key].name}/*"
      },
    ]
  }))
}

resource "upcloud_managed_object_storage_user_policy" "platform" {
  for_each = local.objsto_services

  service_uuid = upcloud_managed_object_storage.main.id
  username     = upcloud_managed_object_storage_user.platform[each.key].username
  name         = upcloud_managed_object_storage_policy.platform[each.key].name
}

resource "upcloud_managed_object_storage_user_access_key" "platform" {
  for_each = local.objsto_services

  service_uuid = upcloud_managed_object_storage.main.id
  username     = upcloud_managed_object_storage_user.platform[each.key].username
  status       = "Active"
}

