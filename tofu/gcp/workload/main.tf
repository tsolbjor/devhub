# =============================================================================
# GCP Workload Cluster
# =============================================================================
# A lean GKE cluster for running application workloads. No managed data
# services — those live on the platform cluster. ArgoCD (on the platform
# cluster) deploys apps to this cluster via the app-of-apps pattern.
#
# Platform components deployed by deploy-workload.sh:
#   nginx-ingress, cert-manager, external-dns, external-secrets, alloy
#
# Usage:
#   tofu init && tofu plan && tofu apply
#   ./sync-tofu-outputs.sh --env gcp-workload
#   ./deploy-workload.sh --env gcp-workload
# =============================================================================

variable "prefix" {
  description = "Prefix for resource names (e.g., devhub-workload)"
  type        = string
  default     = "devhub-workload"
}

variable "node_machine_type" {
  description = "GKE node machine type"
  type        = string
  default     = "e2-standard-2"
}

variable "node_count" {
  description = "Number of nodes per zone"
  type        = number
  default     = 1
}

variable "kubernetes_version" {
  description = "GKE Kubernetes version (null = STABLE release channel)"
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Prevent cluster deletion"
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels applied to all resources"
  type        = map(string)
  default = {
    environment = "workload"
    managed-by  = "tofu"
  }
}

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

resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dns" {
  project            = var.project_id
  service            = "dns.googleapis.com"
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
  ip_cidr_range = "10.110.0.0/22"
  region        = var.region
  network       = google_compute_network.main.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.210.0.0/14"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.214.0.0/20"
  }
}

# ─── GKE Cluster ──────────────────────────────────────────────────────

resource "google_container_cluster" "main" {
  project  = var.project_id
  name     = "${var.prefix}-gke"
  location = var.region

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Private nodes (no public IPs); egress goes through Cloud NAT below.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = length(var.api_allowed_cidrs) == 0
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

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

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = merge(var.labels, { role = "worker" })
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# ─── External-DNS Workload Identity ──────────────────────────────────
# Allows external-dns to manage Cloud DNS records for app ingresses.

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

variable "master_ipv4_cidr_block" {
  description = "/28 CIDR for the GKE control plane peering range (must not overlap the VPC)"
  type        = string
  default     = "172.17.0.0/28"
}

# ─── Cloud NAT ────────────────────────────────────────────────────────
# Private nodes need NAT for image pulls, ACME challenges and webhooks.

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
