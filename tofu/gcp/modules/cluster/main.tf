# ─── Required APIs ────────────────────────────────────────────────────

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "container" {
  project            = var.project_id
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sqladmin" {
  project            = var.project_id
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "servicenetworking" {
  project            = var.project_id
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

# ─── Networking ───────────────────────────────────────────────────────

resource "google_compute_network" "main" {
  project                 = var.project_id
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "main" {
  project       = var.project_id
  name          = "${var.prefix}-subnet"
  ip_cidr_range = "10.100.0.0/22"
  region        = var.region
  network       = google_compute_network.main.id

  # Secondary ranges required for GKE VPC-native cluster
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.200.0.0/14" # /14 = ~262k pod IPs
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.204.0.0/20" # /20 = ~4k service IPs
  }
}

# Private IP range for Cloud SQL VPC peering
resource "google_compute_global_address" "private_ip_range" {
  project       = var.project_id
  name          = "${var.prefix}-private-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.main.id

  depends_on = [google_project_service.compute]
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]

  depends_on = [google_project_service.servicenetworking]
}

# ─── GKE Cluster ──────────────────────────────────────────────────────
#
# Regional cluster (3 control-plane replicas) for HA.
# Workload Identity enabled — allows K8s service accounts to impersonate
# Google Service Accounts for keyless GCS access.

resource "google_container_cluster" "main" {
  project  = var.project_id
  name     = "${var.prefix}-gke"
  location = var.region # regional cluster

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  # VPC-native cluster with alias IP ranges
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Workload Identity pool — enables OIDC token projection for pods
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Private nodes: workers get no public IPs and egress via Cloud NAT.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = length(var.api_allowed_cidrs) == 0
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  # Who may reach the control plane. With an empty allow-list the endpoint is
  # private-only and no public block is emitted.
  dynamic "master_authorized_networks_config" {
    for_each = length(var.api_allowed_cidrs) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.api_allowed_cidrs
        content {
          cidr_block   = cidr_blocks.value
          display_name = "allowed-${cidr_blocks.key}"
        }
      }
    }
  }

  # Remove default node pool — we manage our own below
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.deletion_protection

  # Minimum version when pinned; the STABLE channel keeps auto-upgrades on
  # either way (the pin must be a version available in that channel).
  min_master_version = var.kubernetes_version

  release_channel {
    channel = "STABLE"
  }

  resource_labels = var.labels

  depends_on = [google_project_service.container]
}

# Minimal dedicated node service account — logging/monitoring/image pulls only,
# instead of the project-wide default compute SA.
resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = "${var.prefix}-gke-nodes"
  display_name = "GKE node service account (minimal)"

  depends_on = [google_project_service.iam]
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_node_pool" "main" {
  project  = var.project_id
  name     = "${var.prefix}-nodes"
  location = var.region
  cluster  = google_container_cluster.main.name

  # Per-zone node count at creation; autoscaler owns the actual size from here on.
  initial_node_count = var.node_count

  # Total across all zones (this is a regional cluster), so the root modules'
  # numbers mean the same thing on every cloud instead of being multiplied by
  # the zone count.
  autoscaling {
    total_min_node_count = var.node_min_count
    total_max_node_count = var.node_max_count
    location_policy      = "BALANCED"
  }

  node_config {
    machine_type = var.node_machine_type

    # Dedicated minimal service account — nodes must not run as the
    # project-wide default compute SA.
    service_account = google_service_account.nodes.email

    # GKE_METADATA mode is required for Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = merge(var.labels, {
      role = "platform"
    })
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

# Tainted, preemptible pool for Woodpecker CI jobs — build containers stay off the
# nodes that run Vault, Keycloak and PostgreSQL.
resource "google_container_node_pool" "ci" {
  count = var.ci_node_max_count > 0 ? 1 : 0

  project  = var.project_id
  name     = "${var.prefix}-ci"
  location = var.region
  cluster  = google_container_cluster.main.name

  initial_node_count = var.ci_node_min_count

  # Totals across all zones, matching the platform pool.
  autoscaling {
    total_min_node_count = var.ci_node_min_count
    total_max_node_count = var.ci_node_max_count
    location_policy      = "BALANCED"
  }

  node_config {
    machine_type    = var.ci_node_machine_type
    spot            = var.ci_node_spot
    service_account = google_service_account.nodes.email

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = merge(var.labels, { role = "ci" })

    taint {
      key    = "workload"
      value  = "ci"
      effect = "NO_SCHEDULE"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

# ─── Cloud NAT ────────────────────────────────────────────────────────
# Private nodes have no external IPs, so egress (image pulls, Let's Encrypt,
# webhooks) goes through a NAT gateway.

resource "google_compute_router" "main" {
  project = var.project_id
  name    = "${var.prefix}-router"
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  project = var.project_id
  name    = "${var.prefix}-nat"
  router  = google_compute_router.main.name
  region  = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ─── Cloud SQL PostgreSQL ─────────────────────────────────────────────
#
# Private IP only — reachable from GKE via VPC peering.
# NOTE: Cloud SQL doesn't support Terraform-managed local user creation.
#       Users (keycloak, forgejo) must be created post-provision via psql.
#       Use: kubectl run pg-init --rm -it --image=postgres:16 -- psql -h <private_ip> -U pgadmin

resource "random_password" "pg_admin" {
  length  = 32
  special = false
}

resource "random_password" "pg_keycloak" {
  length  = 32
  special = false
}

resource "random_password" "pg_forgejo" {
  length  = 32
  special = false
}

resource "google_sql_database_instance" "main" {
  project          = var.project_id
  name             = "${var.prefix}-postgresql"
  region           = var.region
  database_version = var.pg_database_version

  settings {
    tier              = var.pg_tier
    availability_type = var.pg_availability_type
    disk_size         = var.pg_disk_size_gb
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled                                  = false # private IP only
      private_network                               = google_compute_network.main.id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = var.pg_backup_enabled
      point_in_time_recovery_enabled = var.pg_backup_enabled
      start_time                     = "01:00" # UTC, matches the other clouds' backup windows

      backup_retention_settings {
        retained_backups = 7
      }
    }

    database_flags {
      name  = "max_connections"
      value = "200"
    }
  }

  deletion_protection = var.pg_deletion_protection

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

resource "google_sql_user" "pg_admin" {
  project  = var.project_id
  name     = "pgadmin"
  instance = google_sql_database_instance.main.name
  password = random_password.pg_admin.result
}

resource "google_sql_database" "keycloak" {
  project  = var.project_id
  name     = "keycloak"
  instance = google_sql_database_instance.main.name
}

resource "google_sql_database" "forgejo" {
  project  = var.project_id
  name     = "forgejo"
  instance = google_sql_database_instance.main.name
}

# ─── Cloud Memorystore (Redis) ────────────────────────────────────────
#
# Private IP within VPC. Auth enabled (password via AUTH command), TLS in
# transit. The auth_string is output and must be stored in a K8s secret for
# its consumers.
#
# Gated behind enable_cache: no platform component consumes the cache today
# (Forgejo runs its default memory/leveldb backends, apps bring their own
# in-cluster Redis) — enable it for workloads that need managed capacity.

resource "google_project_service" "redis" {
  count = var.enable_cache ? 1 : 0

  project            = var.project_id
  service            = "redis.googleapis.com"
  disable_on_destroy = false
}

resource "google_redis_instance" "main" {
  count = var.enable_cache ? 1 : 0

  project        = var.project_id
  name           = "${var.prefix}-redis"
  region         = var.region
  tier           = var.redis_tier
  memory_size_gb = var.redis_memory_size_gb

  authorized_network = google_compute_network.main.id

  # Redis AUTH password — keyless access is not supported by Memorystore
  auth_enabled = true

  # TLS in transit; clients connect with rediss:// and the CA from the instance.
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  labels = var.labels

  depends_on = [google_project_service.redis]
}

# NOTE: Forgejo keeps repositories, LFS objects, packages and container registry
# blobs on its PersistentVolume. Forgejo supports local disk or S3-compatible
# storage only — Azure Blob and GCS have no S3 API — so rather than run two
# storage models, every cloud uses the volume, and Velero backs it up alongside
# the managed PostgreSQL PITR.

# ─── Google Identity Provider for Keycloak ────────────────────────────
#
# Keycloak federates with Google — users authenticate via "Sign in with Google"
# through Keycloak, which remains the single OIDC issuer for all services.
#
# IMPORTANT: The Google OAuth 2.0 client (Web Application type) must be
# created MANUALLY in Google Cloud Console:
#   APIs & Services → Credentials → Create OAuth client ID → Web application
#   Authorized redirect URIs: https://keycloak.<domain>/realms/devops/broker/google/endpoint
#
# After creation, fill in k8s/scripts/gcp-{dev,prod}/gcp-idp.env:
#   GOOGLE_IDP_CLIENT_ID=<client-id>
#   GOOGLE_IDP_CLIENT_SECRET=<client-secret>
#
# Then run: ./setup-keycloak.sh --env gcp-dev idp

# Enable Google Identity Platform API for documentation purposes
resource "google_project_service" "oauth2" {
  project            = var.project_id
  service            = "oauth2.googleapis.com"
  disable_on_destroy = false
}

# ─── External-DNS Workload Identity ──────────────────────────────────
# Allows external-dns to manage Cloud DNS records for the cluster's domain.
# The K8s service account "external-dns/external-dns" exchanges its OIDC token
# for a Google token via Workload Identity.

resource "google_service_account" "external_dns" {
  project      = var.project_id
  account_id   = "${var.prefix}-external-dns"
  display_name = "External-DNS Service Account (Workload Identity)"

  depends_on = [google_project_service.iam]
}

resource "google_project_iam_member" "external_dns_dns_admin" {
  project = var.project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.external_dns.email}"
}

resource "google_service_account_iam_member" "external_dns_workload_identity" {
  service_account_id = google_service_account.external_dns.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[external-dns/external-dns]"
}

# ─── cert-manager DNS-01 Workload Identity ───────────────────────────
# cert-manager's DNS-01 solver writes TXT records into the same Cloud DNS zone.
# Without this identity no wildcard certificate can ever be issued (Let's
# Encrypt requires DNS-01 for wildcards), which the apps listener needs.

resource "google_service_account" "cert_manager" {
  project      = var.project_id
  account_id   = "${var.prefix}-cert-manager"
  display_name = "cert-manager DNS-01 solver (Workload Identity)"

  depends_on = [google_project_service.iam]
}

resource "google_project_iam_member" "cert_manager_dns_admin" {
  project = var.project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.cert_manager.email}"
}

resource "google_service_account_iam_member" "cert_manager_workload_identity" {
  service_account_id = google_service_account.cert_manager.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[cert-manager/cert-manager]"
}
