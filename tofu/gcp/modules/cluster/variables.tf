# ─── Project / Region ────────────────────────────────────────────────

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region (e.g., europe-west4, europe-west1)"
  type        = string
}

variable "prefix" {
  description = "Prefix for resource names (e.g., devhub-dev)"
  type        = string
}

# ─── GKE Cluster ─────────────────────────────────────────────────────

variable "node_machine_type" {
  description = "GKE node machine type (e.g., e2-standard-2, e2-standard-4)"
  type        = string
}

variable "node_count" {
  description = "Initial number of nodes per zone at pool creation (the autoscaler owns sizing afterwards)"
  type        = number
}

variable "node_min_count" {
  description = "Minimum nodes in total across all zones (autoscaler lower bound)"
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum nodes in total across all zones (autoscaler upper bound)"
  type        = number
  default     = 4
}

# ─── API server exposure ──────────────────────────────────────────────

variable "api_allowed_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach the GKE control plane.
    Empty list = private endpoint only (reach it from inside the VPC / via a
    bastion or Connect gateway). No default on purpose.
  EOT
  type        = list(string)
}

variable "master_ipv4_cidr_block" {
  description = "/28 CIDR for the GKE control plane peering range (must not overlap the VPC)"
  type        = string
  default     = "172.16.0.0/28"
}

# ─── CI node pool (Woodpecker agents) ─────────────────────────────────

variable "ci_node_machine_type" {
  description = "Machine type for the tainted CI node pool"
  type        = string
  default     = "e2-standard-4"
}

variable "ci_node_min_count" {
  description = "Minimum CI nodes in total across all zones (0 = scale to zero when idle)"
  type        = number
  default     = 0
}

variable "ci_node_max_count" {
  description = "Maximum CI nodes in total across all zones (0 disables the CI node pool)"
  type        = number
  default     = 2
}

variable "ci_node_spot" {
  description = "Run CI nodes as Spot VMs"
  type        = bool
  default     = true
}

# ─── Backups / retention ──────────────────────────────────────────────

variable "backup_retention_days" {
  description = "Retention for Velero backup object versions"
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "Retention for Loki log chunks in GCS"
  type        = number
  default     = 30
}

variable "kubernetes_version" {
  description = "GKE Kubernetes version channel (null = STABLE release channel)"
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Prevent cluster deletion (set true for production)"
  type        = bool
  default     = false
}

# ─── Cloud SQL (PostgreSQL) ───────────────────────────────────────────

variable "pg_database_version" {
  description = "PostgreSQL version (e.g., POSTGRES_16)"
  type        = string
  default     = "POSTGRES_16"
}

variable "pg_tier" {
  description = "Cloud SQL machine tier (e.g., db-g1-small, db-n1-standard-2)"
  type        = string
}

variable "pg_disk_size_gb" {
  description = "Cloud SQL disk size in GB"
  type        = number
  default     = 20
}

variable "pg_availability_type" {
  description = "Cloud SQL availability: ZONAL or REGIONAL (REGIONAL = HA)"
  type        = string
  default     = "ZONAL"
}

variable "pg_backup_enabled" {
  description = "Enable automated Cloud SQL backups"
  type        = bool
  default     = true
}

variable "pg_deletion_protection" {
  description = "Prevent Cloud SQL instance deletion"
  type        = bool
  default     = false
}

# ─── Cloud Memorystore (Redis) ────────────────────────────────────────

variable "enable_cache" {
  description = "Provision the managed Memorystore Redis instance. No platform component consumes the cache today; enable for workloads that need it."
  type        = bool
  default     = false
}

variable "redis_tier" {
  description = "Memorystore Redis tier: BASIC or STANDARD_HA"
  type        = string
}

variable "redis_memory_size_gb" {
  description = "Redis memory size in GB"
  type        = number
}

# ─── GCS (Object Storage) ────────────────────────────────────────────

variable "gcs_storage_class" {
  description = "GCS storage class: STANDARD, NEARLINE, COLDLINE, ARCHIVE"
  type        = string
  default     = "STANDARD"
}

# ─── Labels ──────────────────────────────────────────────────────────

variable "labels" {
  description = "Labels applied to all resources"
  type        = map(string)
  default     = {}
}
