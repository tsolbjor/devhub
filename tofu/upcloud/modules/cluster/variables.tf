# ─── Cluster ─────────────────────────────────────────────────────────

variable "prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "main"
}

variable "zone" {
  description = "UpCloud zone"
  type        = string
}

variable "node_plan" {
  description = "UpCloud server plan for worker nodes"
  type        = string
}

variable "node_count" {
  description = "Number of worker nodes"
  type        = number
}

variable "network_cidr" {
  description = "CIDR block for the private network"
  type        = string
  default     = "10.100.0.0/24"
}

variable "control_plane_ip_filter" {
  description = <<-EOT
    CIDRs allowed to reach the UCS control plane.
    No default on purpose — ["0.0.0.0/0"] exposes the API server to the whole
    internet and should be a written-down decision, e.g. ["203.0.113.4/32"].
  EOT
  type        = list(string)
}

# ─── CI node group (Woodpecker agents) ────────────────────────────────

variable "ci_node_count" {
  description = "Nodes in the tainted CI node group (0 disables it)"
  type        = number
  default     = 1
}

variable "ci_node_plan" {
  description = "UpCloud server plan for CI nodes"
  type        = string
  default     = "4xCPU-8GB"
}

variable "termination_protection" {
  description = "Protect managed databases from accidental deletion"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Labels to apply to resources"
  type        = map(string)
}

# ─── Managed Data Services ───────────────────────────────────────────

variable "pg_plan" {
  description = "UpCloud Managed PostgreSQL plan"
  type        = string
}

variable "pg_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}

variable "enable_cache" {
  description = "Provision the managed Valkey instance. No platform component consumes the cache today; enable for workloads that need it."
  type        = bool
  default     = false
}

variable "valkey_plan" {
  description = "UpCloud Managed Valkey plan"
  type        = string
}

variable "objstore_region" {
  description = "UpCloud Managed Object Storage region"
  type        = string
}
