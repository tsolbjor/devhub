# =============================================================================
# UpCloud Workload Cluster
# =============================================================================
# A lean UCS cluster for running application workloads. No managed data
# services — those live on the platform cluster. ArgoCD (on the platform
# cluster) deploys apps to this cluster via the app-of-apps pattern.
#
# Platform components deployed by deploy-workload.sh:
#   envoy-gateway, cert-manager, kyverno, external-dns, external-secrets, alloy
#
# Usage:
#   tofu init && tofu plan && tofu apply
#   ./sync-tofu-outputs.sh --env upcloud-workload
#   ./deploy-workload.sh --env upcloud-workload
# =============================================================================

variable "prefix" {
  description = "Deployment identifier — prefixes every resource name; pick one per deployment (e.g. acme-workload)"
  type        = string
  default     = "devhub-workload"

  validation {
    condition = (
      length(var.prefix) >= 3 && length(var.prefix) <= 16 &&
      can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.prefix))
    )
    error_message = "prefix must be 3-16 lowercase letters, digits or dashes, starting with a letter and not ending in a dash."
  }
}

variable "deployed_by" {
  description = "Identity of the operator who configured this deployment (written by setup-env.sh; used only in labels)"
  type        = string
  default     = "unknown"
}

locals {
  # UpCloud label values reject most punctuation; operator identities are
  # usually emails, so squash anything outside the safe set.
  deployed_by_label = substr(replace(lower(var.deployed_by), "/[^a-z0-9_.-]/", "_"), 0, 63)
}

variable "zone" {
  description = "UpCloud zone"
  type        = string
  default     = "fi-hel1"
}

variable "node_plan" {
  description = "UpCloud server plan for worker nodes"
  type        = string
  default     = "2xCPU-4GB"
}

variable "node_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "network_cidr" {
  description = "CIDR block for the private network"
  type        = string
  default     = "10.110.0.0/24"
}

variable "tags" {
  description = "Labels to apply to resources"
  type        = map(string)
  default = {
    Environment = "workload"
    ManagedBy   = "tofu"
  }
}

# ─── Networking ───────────────────────────────────────────────────────

resource "upcloud_router" "kubernetes" {
  name = "${var.prefix}-workload-router"
}

resource "upcloud_gateway" "kubernetes" {
  name     = "${var.prefix}-workload-gateway"
  zone     = var.zone
  features = ["nat"]
  router {
    id = upcloud_router.kubernetes.id
  }
}

resource "upcloud_network" "kubernetes" {
  name   = "${var.prefix}-workload-network"
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

# ─── Kubernetes Cluster ───────────────────────────────────────────────

resource "upcloud_kubernetes_cluster" "main" {
  name                    = "${var.prefix}-workload"
  zone                    = var.zone
  network                 = upcloud_network.kubernetes.id
  control_plane_ip_filter = var.api_allowed_cidrs

  private_node_groups = true
}

resource "upcloud_kubernetes_node_group" "workers" {
  cluster       = upcloud_kubernetes_cluster.main.id
  name          = "${var.prefix}-workload-workers"
  node_count    = var.node_count
  plan          = var.node_plan
  anti_affinity = var.node_count > 1
  labels = {
    prefix      = var.prefix
    cluster     = "workload"
    role        = "worker"
    env         = lookup(var.tags, "Environment", "workload")
    deployed_by = local.deployed_by_label
  }
}
