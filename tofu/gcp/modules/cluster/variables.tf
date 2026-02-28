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
  description = "Number of nodes per zone (regional cluster spawns nodes in each zone)"
  type        = number
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
