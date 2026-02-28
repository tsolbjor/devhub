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

# ─── Entra ID (Azure AD) ──────────────────────────────────────────────

variable "entra_require_assignment" {
  description = "Require explicit App Role assignment before users can authenticate via Entra ID"
  type        = bool
  default     = false # Set true for production to restrict access to assigned users only
}
