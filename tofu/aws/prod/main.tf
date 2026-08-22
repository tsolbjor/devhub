module "cluster" {
  source = "../modules/cluster"

  region = var.region
  prefix = var.prefix

  # VPC
  availability_zones = ["${var.region}a", "${var.region}b", "${var.region}c"]
  nat_gateway_per_az = true # survive a single-AZ outage

  # Kubernetes API exposure — see variable docs in providers.tf
  api_allowed_cidrs = var.api_allowed_cidrs

  # EKS — general-purpose nodes for production
  node_instance_type = "m5.xlarge"
  node_count         = 3
  node_min_count     = 3
  node_max_count     = 6
  kubernetes_version = "1.30"

  # CI node group — spot, scales to zero, tainted workload=ci
  ci_node_instance_type = "m5.large"
  ci_node_min_count     = 0
  ci_node_max_count     = 6
  ci_node_capacity_type = "SPOT"

  # RDS — larger instance with Multi-AZ for production
  rds_instance_class        = "db.r5.large"
  rds_allocated_storage     = 100
  rds_multi_az              = true
  rds_backup_retention_days = 30
  rds_performance_insights  = true

  # ElastiCache — larger instance with replica for production
  redis_node_type               = "cache.r5.large"
  redis_num_cache_clusters      = 2
  redis_automatic_failover      = true
  redis_snapshot_retention_days = 7

  # Retention
  backup_retention_days = 90
  log_retention_days    = 90

  # DNS — must match an existing Route53 hosted zone (set in terraform.tfvars)
  domain = var.domain

  # Cognito — the hosted-UI domain derives from the deployment prefix,
  # which is what keeps it globally unique
  cognito_domain_prefix = var.prefix

  enable_deletion_protection = true

  tags = {
    Environment = "prod"
    ManagedBy   = "tofu"
    Deployment  = var.prefix
    DeployedBy  = var.deployed_by
  }
}
