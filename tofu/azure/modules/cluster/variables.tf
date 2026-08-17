# ─── Cluster ─────────────────────────────────────────────────────────

variable "prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "location" {
  description = "Azure region (e.g., norwayeast, westeurope, northeurope)"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the Azure Resource Group to create"
  type        = string
}

variable "vnet_address_space" {
  description = "Address space for the virtual network"
  type        = string
  default     = "10.100.0.0/16"
}

variable "aks_subnet_cidr" {
  description = "CIDR block for the AKS node subnet"
  type        = string
  default     = "10.100.0.0/22"
}

variable "pg_subnet_cidr" {
  description = "CIDR block for the PostgreSQL delegated subnet"
  type        = string
  default     = "10.100.4.0/24"
}

variable "aks_node_vm_size" {
  description = "VM size for AKS worker nodes (e.g., Standard_B2s, Standard_D4s_v3)"
  type        = string
}

variable "aks_node_count" {
  description = "Number of AKS worker nodes"
  type        = number
}

variable "aks_kubernetes_version" {
  description = "Kubernetes version for AKS (null = latest stable)"
  type        = string
  default     = null
}

variable "aks_node_min_count" {
  description = "Minimum AKS nodes in the platform pool (autoscaler lower bound)"
  type        = number
  default     = 2
}

variable "aks_node_max_count" {
  description = "Maximum AKS nodes in the platform pool (autoscaler upper bound)"
  type        = number
  default     = 6
}

# ─── API server exposure ──────────────────────────────────────────────

variable "api_allowed_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach the AKS API server.
    Empty list = private cluster, no public endpoint.
    No default on purpose: an open control plane must be an explicit decision.
  EOT
  type        = list(string)
}

variable "aad_admin_group_object_ids" {
  description = <<-EOT
    Entra ID group object IDs granted cluster-admin via Azure RBAC.
    When set, the AKS local admin account (an unrevocable cluster-admin client
    certificate) is disabled and all cluster access is audited per user.
  EOT
  type        = list(string)
  default     = []
}

# ─── CI node pool (Woodpecker agents) ─────────────────────────────────

variable "ci_node_vm_size" {
  description = "VM size for the tainted CI node pool"
  type        = string
  default     = "Standard_D4s_v3"
}

variable "ci_node_min_count" {
  description = "Minimum CI nodes (0 = scale to zero when idle)"
  type        = number
  default     = 0
}

variable "ci_node_max_count" {
  description = "Maximum CI nodes (0 disables the CI node pool)"
  type        = number
  default     = 3
}

variable "ci_node_spot" {
  description = "Run CI nodes as Azure Spot VMs"
  type        = bool
  default     = true
}

# ─── Backups / retention ──────────────────────────────────────────────

variable "backup_retention_days" {
  description = "Retention for Velero backup blob versions"
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "Retention for Loki log chunks in blob storage"
  type        = number
  default     = 30
}

variable "enable_delete_lock" {
  description = "Protect the resource group from accidental deletion"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}

# ─── PostgreSQL Flexible Server ───────────────────────────────────────

variable "pg_sku_name" {
  description = "PostgreSQL Flexible Server SKU (e.g., B_Standard_B1ms, GP_Standard_D2s_v3)"
  type        = string
}

variable "pg_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}

variable "pg_storage_mb" {
  description = "PostgreSQL storage in MB (minimum 32768)"
  type        = number
  default     = 32768
}

variable "pg_backup_retention_days" {
  description = "PostgreSQL backup retention in days (7-35)"
  type        = number
  default     = 7
}

variable "pg_geo_redundant_backup" {
  description = "Replicate PostgreSQL backups to the Azure paired region"
  type        = bool
  default     = false
}

variable "pg_ha_mode" {
  description = "PostgreSQL high availability mode: Disabled or ZoneRedundant"
  type        = string
  default     = "Disabled"
}

variable "pg_standby_zone" {
  description = "Availability zone for PostgreSQL standby replica (used when pg_ha_mode = ZoneRedundant)"
  type        = string
  default     = "2"
}

# ─── Azure Cache for Redis ────────────────────────────────────────────

variable "redis_sku_name" {
  description = "Azure Cache for Redis SKU: Basic, Standard, or Premium"
  type        = string
}

variable "redis_family" {
  description = "Redis family: C (Basic/Standard) or P (Premium)"
  type        = string
}

variable "redis_capacity" {
  description = "Redis cache size (0-6, meaning depends on SKU/family)"
  type        = number
}

# ─── Blob Storage ─────────────────────────────────────────────────────

variable "storage_replication" {
  description = "Storage account replication type (LRS, ZRS, GRS, RAGRS)"
  type        = string
  default     = "LRS"
}

# ─── DNS ─────────────────────────────────────────────────────────────

variable "domain" {
  description = "Public domain name for the cluster (e.g., dev.example.com) — must have an existing Azure DNS zone"
  type        = string
}

variable "dns_zone_resource_group" {
  description = "Resource group containing the Azure DNS zone (defaults to the cluster resource group)"
  type        = string
  default     = ""
}

# ─── Entra ID (Azure AD) ──────────────────────────────────────────────

variable "entra_require_assignment" {
  description = "Require explicit App Role assignment before users can authenticate via Entra ID"
  type        = bool
  default     = false # Set true for production to restrict access to assigned users only
}
