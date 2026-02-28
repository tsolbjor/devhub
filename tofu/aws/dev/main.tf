module "cluster" {
  source = "../modules/cluster"

  region = var.region
  prefix = "devhub-dev"

  # VPC
  availability_zones = ["${var.region}a", "${var.region}b"]

  # EKS — small dev nodes
  node_instance_type = "t3.medium"
  node_count         = 2
  node_min_count     = 1
  node_max_count     = 4
  kubernetes_version = "1.30"

  # RDS — small burstable tier for dev
  rds_instance_class    = "db.t3.micro"
  rds_allocated_storage = 20
  rds_multi_az          = false

  # ElastiCache — small single node for dev
  redis_node_type          = "cache.t3.micro"
  redis_num_cache_clusters = 1
  redis_automatic_failover = false

  # Cognito — domain prefix must be globally unique
  cognito_domain_prefix = "devhub-dev-devhub" # TODO: customize to avoid conflicts

  enable_deletion_protection = false

  tags = {
    Environment = "dev"
    ManagedBy   = "tofu"
  }
}
