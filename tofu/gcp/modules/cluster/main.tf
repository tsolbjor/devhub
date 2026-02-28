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

resource "google_project_service" "redis" {
  project            = var.project_id
  service            = "redis.googleapis.com"
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

  # Remove default node pool — we manage our own below
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.deletion_protection

  dynamic "release_channel" {
    for_each = var.kubernetes_version == null ? [1] : []
    content {
      channel = "STABLE"
    }
  }

  resource_labels = var.labels

  depends_on = [google_project_service.container]
}

resource "google_container_node_pool" "main" {
  project    = var.project_id
  name       = "${var.prefix}-nodes"
  location   = var.region
  cluster    = google_container_cluster.main.name
  node_count = var.node_count

  node_config {
    machine_type = var.node_machine_type

    # GKE_METADATA mode is required for Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = merge(var.labels, {
      role = "worker"
    })
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# ─── Cloud SQL PostgreSQL ─────────────────────────────────────────────
#
# Private IP only — reachable from GKE via VPC peering.
# NOTE: Cloud SQL doesn't support Terraform-managed local user creation.
#       Users (keycloak, gitlab) must be created post-provision via psql.
#       Use: kubectl run pg-init --rm -it --image=postgres:16 -- psql -h <private_ip> -U pgadmin

resource "random_password" "pg_admin" {
  length  = 32
  special = false
}

resource "random_password" "pg_keycloak" {
  length  = 32
  special = false
}

resource "random_password" "pg_gitlab" {
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
    }

    backup_configuration {
      enabled = var.pg_backup_enabled
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

resource "google_sql_database" "gitlab" {
  project  = var.project_id
  name     = "gitlabhq_production"
  instance = google_sql_database_instance.main.name
}

# ─── Cloud Memorystore (Redis) ────────────────────────────────────────
#
# Private IP within VPC. Auth enabled (password via AUTH command).
# The auth_string is output and must be stored in a K8s secret for GitLab.

resource "google_redis_instance" "main" {
  project        = var.project_id
  name           = "${var.prefix}-redis"
  region         = var.region
  tier           = var.redis_tier
  memory_size_gb = var.redis_memory_size_gb

  authorized_network = google_compute_network.main.id

  # Redis AUTH password — keyless access is not supported by Memorystore
  auth_enabled = true

  labels = var.labels

  depends_on = [google_project_service.redis]
}

# ─── GCS Buckets (GitLab Object Storage) ─────────────────────────────
#
# GitLab supports GCS natively via the Fog/Google provider.
# Workload Identity is used for keyless access — no access key required.
# NOTE: GCS bucket names are globally unique. If "${prefix}-gitlab-*" conflicts,
#       adjust var.prefix to include a project-specific component.

locals {
  gcs_bucket_prefix = "${var.prefix}-gitlab"
}

resource "google_storage_bucket" "gitlab_artifacts" {
  project       = var.project_id
  name          = "${local.gcs_bucket_prefix}-artifacts"
  location      = var.region
  storage_class = var.gcs_storage_class
  force_destroy = true

  uniform_bucket_level_access = true
  labels                      = var.labels
}

resource "google_storage_bucket" "gitlab_uploads" {
  project       = var.project_id
  name          = "${local.gcs_bucket_prefix}-uploads"
  location      = var.region
  storage_class = var.gcs_storage_class
  force_destroy = true

  uniform_bucket_level_access = true
  labels                      = var.labels
}

resource "google_storage_bucket" "gitlab_packages" {
  project       = var.project_id
  name          = "${local.gcs_bucket_prefix}-packages"
  location      = var.region
  storage_class = var.gcs_storage_class
  force_destroy = true

  uniform_bucket_level_access = true
  labels                      = var.labels
}

resource "google_storage_bucket" "gitlab_lfs" {
  project       = var.project_id
  name          = "${local.gcs_bucket_prefix}-lfs"
  location      = var.region
  storage_class = var.gcs_storage_class
  force_destroy = true

  uniform_bucket_level_access = true
  labels                      = var.labels
}

resource "google_storage_bucket" "gitlab_registry" {
  project       = var.project_id
  name          = "${local.gcs_bucket_prefix}-registry"
  location      = var.region
  storage_class = var.gcs_storage_class
  force_destroy = true

  uniform_bucket_level_access = true
  labels                      = var.labels
}

resource "google_storage_bucket" "gitlab_backups" {
  project       = var.project_id
  name          = "${local.gcs_bucket_prefix}-backups"
  location      = var.region
  storage_class = var.gcs_storage_class
  force_destroy = true

  uniform_bucket_level_access = true
  labels                      = var.labels
}

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

# ─── Workload Identity for GitLab ─────────────────────────────────────
#
# Allows GitLab pods (webservice, sidekiq) to access GCS buckets without
# a service account key. The K8s service account "gitlab" in the "gitlab"
# namespace exchanges its projected OIDC token for a Google token.
#
# GKE must have workload_identity_config set (done above).

resource "google_service_account" "gitlab" {
  project      = var.project_id
  account_id   = "${var.prefix}-gitlab"
  display_name = "GitLab Service Account (Workload Identity)"

  depends_on = [google_project_service.iam]
}

# Grant the GSA Object Admin on all GitLab buckets
resource "google_storage_bucket_iam_member" "gitlab_artifacts" {
  bucket = google_storage_bucket.gitlab_artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.gitlab.email}"
}

resource "google_storage_bucket_iam_member" "gitlab_uploads" {
  bucket = google_storage_bucket.gitlab_uploads.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.gitlab.email}"
}

resource "google_storage_bucket_iam_member" "gitlab_packages" {
  bucket = google_storage_bucket.gitlab_packages.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.gitlab.email}"
}

resource "google_storage_bucket_iam_member" "gitlab_lfs" {
  bucket = google_storage_bucket.gitlab_lfs.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.gitlab.email}"
}

resource "google_storage_bucket_iam_member" "gitlab_registry" {
  bucket = google_storage_bucket.gitlab_registry.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.gitlab.email}"
}

resource "google_storage_bucket_iam_member" "gitlab_backups" {
  bucket = google_storage_bucket.gitlab_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.gitlab.email}"
}

# Bind the K8s service account "gitlab/gitlab" to the GSA via Workload Identity.
# The GitLab Helm chart creates the "gitlab" SA when global.serviceAccount.enabled=true.
resource "google_service_account_iam_member" "gitlab_workload_identity" {
  service_account_id = google_service_account.gitlab.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[gitlab/gitlab]"
}
