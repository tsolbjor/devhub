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
  name                = "${var.prefix}-${var.cluster_name}"
  zone                = var.zone
  network             = upcloud_network.kubernetes.id
  control_plane_ip_filter = ["0.0.0.0/0"] # Allow access from anywhere (adjust for production)

  # Private node groups (workers will be in private network)
  private_node_groups = true
}

# Node group for worker nodes
resource "upcloud_kubernetes_node_group" "workers" {
  cluster = upcloud_kubernetes_cluster.main.id
  name    = "${var.prefix}-${var.cluster_name}-workers"
  node_count   = var.node_count
  plan    = var.node_plan
  anti_affinity = true # Spread nodes across different hosts for high availability
  labels = {
    prefix = var.prefix
    cluster = var.cluster_name
    role = "worker"
    env  = lookup(var.tags, "Environment", "dev")
  }

  # Enable auto-scaling (optional)
  # Set min and max to same value for fixed size
  # autoscaling = {
  #   min = var.node_count
  #   max = var.node_count + 2
  # }
}

# ─── Managed PostgreSQL ──────────────────────────────────────────────

resource "upcloud_managed_database_postgresql" "main" {
  name  = "${var.prefix}-postgresql"
  plan  = var.pg_plan
  title = "${var.prefix} PostgreSQL"
  zone  = var.zone

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

resource "upcloud_managed_database_logical_database" "gitlab" {
  service = upcloud_managed_database_postgresql.main.id
  name    = "gitlabhq_production"
}

resource "upcloud_managed_database_user" "keycloak" {
  service  = upcloud_managed_database_postgresql.main.id
  username = "keycloak"
}

resource "upcloud_managed_database_user" "gitlab" {
  service  = upcloud_managed_database_postgresql.main.id
  username = "gitlab"
}

# ─── Managed Valkey ──────────────────────────────────────────────────

resource "upcloud_managed_database_valkey" "main" {
  name  = "${var.prefix}-valkey"
  plan  = var.valkey_plan
  title = "${var.prefix} Valkey"
  zone  = var.zone

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

resource "upcloud_managed_object_storage_user" "gitlab" {
  service_uuid = upcloud_managed_object_storage.main.id
  username     = "${var.prefix}-gitlab"
}

resource "upcloud_managed_object_storage_user_access_key" "gitlab" {
  service_uuid = upcloud_managed_object_storage.main.id
  username     = upcloud_managed_object_storage_user.gitlab.username
  status       = "Active"
}

resource "upcloud_managed_object_storage_policy" "gitlab" {
  service_uuid = upcloud_managed_object_storage.main.id
  name         = "gitlab-full-access"
  description  = "Full S3 access for GitLab"
  document = urlencode(jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = "*"
      }
    ]
  }))
}

resource "upcloud_managed_object_storage_user_policy" "gitlab" {
  service_uuid = upcloud_managed_object_storage.main.id
  username     = upcloud_managed_object_storage_user.gitlab.username
  name         = upcloud_managed_object_storage_policy.gitlab.name
}

resource "upcloud_managed_object_storage_bucket" "gitlab_artifacts" {
  service_uuid = upcloud_managed_object_storage.main.id
  name         = "${var.prefix}-gitlab-artifacts"
}

resource "upcloud_managed_object_storage_bucket" "gitlab_uploads" {
  service_uuid = upcloud_managed_object_storage.main.id
  name         = "${var.prefix}-gitlab-uploads"
}

resource "upcloud_managed_object_storage_bucket" "gitlab_packages" {
  service_uuid = upcloud_managed_object_storage.main.id
  name         = "${var.prefix}-gitlab-packages"
}

resource "upcloud_managed_object_storage_bucket" "gitlab_lfs" {
  service_uuid = upcloud_managed_object_storage.main.id
  name         = "${var.prefix}-gitlab-lfs"
}

resource "upcloud_managed_object_storage_bucket" "gitlab_registry" {
  service_uuid = upcloud_managed_object_storage.main.id
  name         = "${var.prefix}-gitlab-registry"
}

resource "upcloud_managed_object_storage_bucket" "gitlab_backups" {
  service_uuid = upcloud_managed_object_storage.main.id
  name         = "${var.prefix}-gitlab-backups"
}
