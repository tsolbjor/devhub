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
  description = "CIDRs allowed to access the K8s API"
  type        = list(string)
  default     = ["0.0.0.0/0"]
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

variable "valkey_plan" {
  description = "UpCloud Managed Valkey plan"
  type        = string
}

variable "objstore_region" {
  description = "UpCloud Managed Object Storage region"
  type        = string
}
