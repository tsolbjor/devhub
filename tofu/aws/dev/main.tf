module "cluster" {
  source = "../modules/cluster"

  region = var.region
  prefix = var.prefix

  # VPC
  availability_zones = ["${var.region}a", "${var.region}b"]
  nat_gateway_per_az = false # single NAT is fine for dev

  # Kubernetes API exposure — see variable docs in providers.tf
  api_allowed_cidrs = var.api_allowed_cidrs

  # EKS — small dev nodes
  node_instance_type = "t3.medium"
  node_count         = 2
  node_min_count     = 1
  node_max_count     = 4
  kubernetes_version = "1.33"

  # CI node group — spot, scales to zero, tainted workload=ci
  ci_node_instance_type = "t3.large"
  ci_node_min_count     = 0
  ci_node_max_count     = 2
  ci_node_capacity_type = "SPOT"

  # RDS — small burstable tier for dev
  rds_instance_class        = "db.t3.micro"
  rds_allocated_storage     = 20
  rds_multi_az              = false
  rds_backup_retention_days = 7
  rds_performance_insights  = false # unsupported on db.t3.micro

  # ElastiCache — small single node for dev (TLS + AUTH always on)
  redis_node_type               = "cache.t3.micro"
  redis_num_cache_clusters      = 1
  redis_automatic_failover      = false
  redis_snapshot_retention_days = 1

  # Retention
  backup_retention_days = 14
  log_retention_days    = 14

  # DNS — must match an existing Route53 hosted zone (set in terraform.tfvars)
  domain = var.domain

  # Cognito — the hosted-UI domain derives from the deployment prefix,
  # which is what keeps it globally unique
  cognito_domain_prefix = var.prefix

  enable_deletion_protection = false

  tags = {
    Environment = "dev"
    ManagedBy   = "tofu"
    Deployment  = var.prefix
    DeployedBy  = var.deployed_by
  }
}
