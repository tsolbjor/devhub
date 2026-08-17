module "cluster" {
  source = "../modules/cluster"

  region = var.region
  prefix = "devhub-dev"

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
  kubernetes_version = "1.30"

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

  # DNS — must match an existing Route53 hosted zone
  domain = "dev.example.com" # TODO: set to your actual domain

  # Cognito — domain prefix must be globally unique
  cognito_domain_prefix = "devhub-dev-devhub" # TODO: customize to avoid conflicts

  enable_deletion_protection = false

  tags = {
    Environment = "dev"
    ManagedBy   = "tofu"
  }
}
