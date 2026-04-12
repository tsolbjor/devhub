# =============================================================================
# Azure Workload Cluster
# =============================================================================
# A lean AKS cluster for running application workloads. No managed data
# services — those live on the platform cluster. ArgoCD (on the platform
# cluster) deploys apps to this cluster via the app-of-apps pattern.
#
# Platform components deployed by deploy-workload.sh:
#   nginx-ingress, cert-manager, external-dns, external-secrets, alloy
#
# Usage:
#   tofu init && tofu plan && tofu apply
#   ./sync-tofu-outputs.sh --env azure-workload
#   ./deploy-workload.sh --env azure-workload
# =============================================================================

variable "prefix" {
  description = "Prefix for resource names (e.g., devhub-workload)"
  type        = string
  default     = "devhub-workload"
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
  description = "Number of AKS worker nodes"
  type        = number
  default     = 2
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

# ─── Resource Group ───────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ─── Networking ───────────────────────────────────────────────────────

resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = [var.vnet_address_space]
  tags                = var.tags
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
  tags                = var.tags

  default_node_pool {
    name           = "system"
    node_count     = var.aks_node_count
    vm_size        = var.aks_node_vm_size
    vnet_subnet_id = azurerm_subnet.aks.id
    node_labels = {
      prefix = var.prefix
      role   = "worker"
      env    = lookup(var.tags, "Environment", "workload")
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true
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
  tags                = var.tags
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
