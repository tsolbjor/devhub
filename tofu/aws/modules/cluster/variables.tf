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
  description = "Kubernetes version for EKS (e.g., \"1.30\")"
  type        = string
  default     = "1.30"
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

# ─── ElastiCache (Redis) ──────────────────────────────────────────────

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

# ─── Cognito (IdP for Keycloak) ───────────────────────────────────────

variable "cognito_domain_prefix" {
  description = "Cognito hosted UI domain prefix — must be globally unique across all AWS accounts"
  type        = string
}

# ─── Tags ─────────────────────────────────────────────────────────────

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
