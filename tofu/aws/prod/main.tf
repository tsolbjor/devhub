module "cluster" {
  source = "../modules/cluster"

  region = var.region
  prefix = "devhub"

  # VPC
  availability_zones = ["${var.region}a", "${var.region}b", "${var.region}c"]

  # EKS — general-purpose nodes for production
  node_instance_type = "m5.xlarge"
  node_count         = 3
  node_min_count     = 3
  node_max_count     = 6
  kubernetes_version = "1.30"

  # RDS — larger instance with Multi-AZ for production
  rds_instance_class    = "db.r5.large"
  rds_allocated_storage = 100
  rds_multi_az          = true

  # ElastiCache — larger instance with replica for production
  redis_node_type          = "cache.r5.large"
  redis_num_cache_clusters = 2
  redis_automatic_failover = true

  # Cognito — domain prefix must be globally unique
  cognito_domain_prefix = "devhub-prod-devhub" # TODO: customize to avoid conflicts

  enable_deletion_protection = true

  tags = {
    Environment = "prod"
    ManagedBy   = "tofu"
  }
}
