module "cluster" {
  source = "../modules/cluster"

  project_id = var.project_id
  region     = var.region
  prefix     = "devhub"

  # Kubernetes API exposure — set in terraform.tfvars
  api_allowed_cidrs = var.api_allowed_cidrs

  # GKE — general-purpose nodes for production (private, autoscaled)
  node_machine_type   = "e2-standard-4"
  node_count          = 3
  node_min_count      = 3
  node_max_count      = 8
  deletion_protection = true

  # CI node pool — spot, scales to zero, tainted workload=ci
  ci_node_machine_type = "e2-standard-4"
  ci_node_min_count    = 0
  ci_node_max_count    = 4
  ci_node_spot         = true

  # Retention
  backup_retention_days = 90
  log_retention_days    = 90

  # Cloud SQL — general-purpose HA tier for production
  pg_tier                = "db-n1-standard-2"
  pg_disk_size_gb        = 100
  pg_availability_type   = "REGIONAL" # HA with hot standby
  pg_backup_enabled      = true
  pg_deletion_protection = true

  # Memorystore Redis — STANDARD_HA for production
  redis_tier           = "STANDARD_HA"
  redis_memory_size_gb = 4

  # GCS — STANDARD storage (geo-redundant via multi-region location if needed)
  gcs_storage_class = "STANDARD"

  labels = {
    environment = "prod"
    managed-by  = "tofu"
  }
}
