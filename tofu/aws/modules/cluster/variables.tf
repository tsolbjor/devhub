# ─── Region ──────────────────────────────────────────────────────────

variable "region" {
  description = "AWS region (e.g., eu-west-1, us-east-1)"
  type        = string
}

variable "prefix" {
  description = "Prefix for resource names (e.g., devhub-dev)"
  type        = string
}

# ─── Networking ───────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.100.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs for subnets (2–3 recommended)"
  type        = list(string)
}

variable "nat_gateway_per_az" {
  description = "Create one NAT gateway per AZ (HA, higher cost) instead of a single shared gateway"
  type        = bool
  default     = false
}

# ─── API server exposure ──────────────────────────────────────────────

variable "api_allowed_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach the public Kubernetes API endpoint.
    Empty list = no public endpoint at all (VPC-only access via VPN/bastion).
    There is deliberately no default: an unrestricted control plane must be a
    conscious choice, e.g. ["203.0.113.4/32"] for an office egress IP.
  EOT
  type        = list(string)
}

# ─── EKS Cluster ─────────────────────────────────────────────────────

variable "node_instance_type" {
  description = "EKS node instance type (e.g., t3.medium, m5.xlarge)"
  type        = string
}

variable "node_count" {
  description = "Desired number of EKS worker nodes"
  type        = number
}

variable "node_min_count" {
  description = "Minimum number of EKS worker nodes"
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum number of EKS worker nodes"
  type        = number
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS (e.g., \"1.33\")"
  type        = string
  default     = "1.33"
}

# ─── CI node group (Woodpecker agents) ────────────────────────────────

variable "ci_node_instance_type" {
  description = "Instance type for the tainted CI node group"
  type        = string
  default     = "t3.large"
}

variable "ci_node_min_count" {
  description = "Minimum CI nodes (0 = scale to zero when no jobs are running)"
  type        = number
  default     = 0
}

variable "ci_node_max_count" {
  description = "Maximum CI nodes (0 disables the CI node group entirely)"
  type        = number
  default     = 3
}

variable "ci_node_capacity_type" {
  description = "CI node capacity type: SPOT (cheap, interruptible) or ON_DEMAND"
  type        = string
  default     = "SPOT"
}

variable "enable_deletion_protection" {
  description = "Enable deletion protection on stateful resources (RDS)"
  type        = bool
  default     = false
}

# ─── RDS (PostgreSQL) ────────────────────────────────────────────────

variable "rds_instance_class" {
  description = "RDS instance class (e.g., db.t3.micro, db.r5.large)"
  type        = string
}

variable "rds_allocated_storage" {
  description = "RDS allocated storage in GB"
  type        = number
  default     = 20
}

variable "rds_multi_az" {
  description = "Enable RDS Multi-AZ deployment"
  type        = bool
  default     = false
}

variable "rds_backup_retention_days" {
  description = "RDS automated backup retention in days (enables point-in-time recovery)"
  type        = number
  default     = 7
}

variable "rds_performance_insights" {
  description = "Enable RDS Performance Insights (not supported on db.t3.micro)"
  type        = bool
  default     = false
}

# ─── ElastiCache (Redis) ──────────────────────────────────────────────

variable "enable_cache" {
  description = "Provision the managed ElastiCache Redis replication group. No platform component consumes the cache today; enable for workloads that need it."
  type        = bool
  default     = false
}

variable "redis_node_type" {
  description = "ElastiCache node type (e.g., cache.t3.micro, cache.r5.large)"
  type        = string
}

variable "redis_num_cache_clusters" {
  description = "Number of Redis cache clusters (1 = single, 2 = primary+replica)"
  type        = number
  default     = 1
}

variable "redis_automatic_failover" {
  description = "Enable automatic Redis failover (requires num_cache_clusters >= 2)"
  type        = bool
  default     = false
}

variable "redis_snapshot_retention_days" {
  description = "ElastiCache daily snapshot retention in days (0 disables snapshots)"
  type        = number
  default     = 1
}

# ─── Backups / retention ──────────────────────────────────────────────

variable "backup_retention_days" {
  description = "Retention for Velero backup object versions"
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "Retention for Loki log chunks in S3"
  type        = number
  default     = 30
}

# ─── DNS ─────────────────────────────────────────────────────────────

variable "domain" {
  description = "Public domain name for the cluster (e.g., dev.example.com) — must have an existing Route53 hosted zone"
  type        = string
}

# ─── Cognito (IdP for Keycloak) ───────────────────────────────────────

variable "cognito_domain_prefix" {
  description = "Cognito hosted UI domain prefix — must be globally unique across all AWS accounts"
  type        = string
}

variable "cognito_mfa_configuration" {
  description = "TOTP MFA on the Cognito user pool: OFF, OPTIONAL (users may enrol) or ON (required). These accounts federate into Keycloak, including devops-admins."
  type        = string
  default     = "OPTIONAL"

  validation {
    condition     = contains(["OFF", "OPTIONAL", "ON"], var.cognito_mfa_configuration)
    error_message = "cognito_mfa_configuration must be OFF, OPTIONAL or ON."
  }
}

# ─── Tags ─────────────────────────────────────────────────────────────

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
