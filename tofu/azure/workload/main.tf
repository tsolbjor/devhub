# =============================================================================
# Azure Workload Cluster
# =============================================================================
# A lean AKS cluster for running application workloads. No managed data
# services — those live on the platform cluster. ArgoCD (on the platform
# cluster) deploys apps to this cluster via the app-of-apps pattern.
#
# Platform components deployed by deploy-workload.sh:
#   envoy-gateway, cert-manager, kyverno, external-dns, external-secrets, alloy
#
# Usage:
#   tofu init && tofu plan && tofu apply
#   ./sync-tofu-outputs.sh --env azure-workload
#   ./deploy-workload.sh --env azure-workload
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
  description = "Identity of the operator who configured this deployment (written by setup-env.sh; used only in tags)"
  type        = string
  default     = "unknown"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "norwayeast"
}

variable "resource_group_name" {
  description = "Name of the Azure Resource Group to create"
  type        = string
  default     = "devhub-workload-rg"
}

variable "vnet_address_space" {
  description = "Address space for the virtual network"
  type        = string
  default     = "10.110.0.0/16"
}

variable "aks_subnet_cidr" {
  description = "CIDR block for the AKS node subnet"
  type        = string
  default     = "10.110.0.0/22"
}

variable "aks_node_vm_size" {
  description = "VM size for AKS worker nodes"
  type        = string
  default     = "Standard_B2s"
}

variable "aks_node_count" {
  description = "Initial number of AKS worker nodes — the autoscaler owns it from the first scale event onwards"
  type        = number
  default     = 2
}

variable "aks_node_min_count" {
  description = "Minimum AKS worker nodes (autoscaler lower bound)"
  type        = number
  default     = 2
}

variable "aks_node_max_count" {
  description = "Maximum AKS worker nodes (autoscaler upper bound)"
  type        = number
  default     = 8
}

variable "aks_kubernetes_version" {
  description = "Kubernetes version for AKS (null = latest stable)"
  type        = string
  default     = null
}

variable "domain" {
  description = "Public domain name — must have an existing Azure DNS zone"
  type        = string
}

variable "dns_zone_resource_group" {
  description = "Resource group containing the Azure DNS zone (defaults to cluster RG)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Environment = "workload"
    ManagedBy   = "tofu"
  }
}

locals {
  tags = merge(var.tags, {
    Deployment = var.prefix
    DeployedBy = var.deployed_by
  })
}

# ─── Resource Group ───────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# ─── Networking ───────────────────────────────────────────────────────

resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = [var.vnet_address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "${var.prefix}-aks-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aks_subnet_cidr]
}

# ─── AKS Cluster ──────────────────────────────────────────────────────

resource "azurerm_kubernetes_cluster" "main" {
  name                = "${var.prefix}-aks"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = replace(var.prefix, "-", "")
  kubernetes_version  = var.aks_kubernetes_version
  tags                = local.tags

  default_node_pool {
    name           = "system"
    node_count     = var.aks_node_count
    vm_size        = var.aks_node_vm_size
    vnet_subnet_id = azurerm_subnet.aks.id

    # A fixed node_count made aks_node_count a hard ceiling: app deployments
    # that outgrew it sat Pending with nothing to fix it. Same autoscaler wiring
    # as the platform module.
    auto_scaling_enabled = true
    min_count            = var.aks_node_min_count
    max_count            = var.aks_node_max_count

    node_labels = {
      prefix = var.prefix
      role   = "worker"
      env    = lookup(local.tags, "Environment", "workload")
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
  }

  # API server exposure: empty allow-list = private cluster, no public endpoint.
  private_cluster_enabled = length(var.api_allowed_cidrs) == 0

  dynamic "api_server_access_profile" {
    for_each = length(var.api_allowed_cidrs) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_allowed_cidrs
    }
  }

  dynamic "azure_active_directory_role_based_access_control" {
    for_each = length(var.aad_admin_group_object_ids) > 0 ? [1] : []
    content {
      azure_rbac_enabled     = true
      admin_group_object_ids = var.aad_admin_group_object_ids
    }
  }

  local_account_disabled = length(var.aad_admin_group_object_ids) > 0

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Same reasoning as the platform module: without a channel Azure force-upgrades
  # the cluster off unsupported versions outside tofu. This is the cluster running
  # customer apps, so patches matter more here, not less.
  automatic_upgrade_channel = var.aks_upgrade_channel == "none" ? null : var.aks_upgrade_channel

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = "+00:00"
  }

  lifecycle {
    # Node count is owned by the AKS autoscaler once it is running; the patch
    # version by the upgrade channel (otherwise every plan rolls it back).
    ignore_changes = [default_node_pool[0].node_count, kubernetes_version]
  }
}

variable "aks_upgrade_channel" {
  description = "AKS automatic upgrade channel: patch, stable, rapid, node-image or none"
  type        = string
  default     = "patch"

  validation {
    condition     = contains(["patch", "stable", "rapid", "node-image", "none"], var.aks_upgrade_channel)
    error_message = "aks_upgrade_channel must be one of: patch, stable, rapid, node-image, none."
  }
}

variable "aad_admin_group_object_ids" {
  description = "Entra ID group object IDs granted cluster-admin via Azure RBAC (disables the local admin account when set)"
  type        = list(string)
  default     = []
}

# ─── External-DNS Workload Identity ──────────────────────────────────
# Allows external-dns to manage Azure DNS records for app ingresses.

data "azurerm_dns_zone" "main" {
  name                = var.domain
  resource_group_name = var.dns_zone_resource_group != "" ? var.dns_zone_resource_group : azurerm_resource_group.main.name
}

resource "azurerm_user_assigned_identity" "external_dns" {
  name                = "${var.prefix}-external-dns-identity"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "external_dns_dns_contributor" {
  scope                = data.azurerm_dns_zone.main.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.external_dns.principal_id
}

resource "azurerm_federated_identity_credential" "external_dns" {
  name                = "${var.prefix}-external-dns-fedcred"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.external_dns.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:external-dns:external-dns"
}

# cert-manager shares the DNS identity: its DNS-01 solver writes the same
# zone's TXT records. Without this federated credential no wildcard
# certificate can ever be issued (Let's Encrypt requires DNS-01 for
# wildcards), which the apps listener needs.
resource "azurerm_federated_identity_credential" "cert_manager" {
  name                = "${var.prefix}-cert-manager-fedcred"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.external_dns.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:cert-manager:cert-manager"
}
