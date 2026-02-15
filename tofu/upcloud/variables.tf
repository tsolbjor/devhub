variable "prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "tshub"
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "main"
}

variable "zone" {
  description = "UpCloud zone where the cluster will be created"
  type        = string
  default     = "de-fra1" # Frankfurt, Germany
}

variable "node_plan" {
  description = "UpCloud server plan for worker nodes"
  type        = string
  default     = "2xCPU-4GB" # Suitable for dev environment
}

variable "node_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "control_plane_plan" {
  description = "UpCloud server plan for control plane"
  type        = string
  default     = "2xCPU-4GB"
}

variable "network_cidr" {
  description = "CIDR block for the private network"
  type        = string
  default     = "10.100.0.0/24"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "enable_auto_upgrade" {
  description = "Enable automatic Kubernetes version upgrades"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    Environment = "dev"
    ManagedBy   = "tofu"
    Purpose     = "cluster-management"
  }
}

# ─── Managed Data Services ───────────────────────────────────────────

variable "pg_plan" {
  description = "UpCloud Managed PostgreSQL plan"
  type        = string
  default     = "1x1xCPU-2GB-25GB"
}

variable "pg_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}

variable "valkey_plan" {
  description = "UpCloud Managed Valkey plan"
  type        = string
  default     = "1x1xCPU-2GB"
}

variable "objstore_region" {
  description = "UpCloud Managed Object Storage region"
  type        = string
  default     = "europe-1"
}
