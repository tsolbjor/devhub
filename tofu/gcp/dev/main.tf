module "cluster" {
  source = "../modules/cluster"

  project_id = var.project_id
  region     = var.region
  prefix     = "devhub-dev"

  # Kubernetes API exposure — set in terraform.tfvars
  api_allowed_cidrs = var.api_allowed_cidrs

  # GKE — small dev nodes (private, autoscaled)
  node_machine_type = "e2-standard-2"
  node_count        = 2
  node_min_count    = 1
  node_max_count    = 4

  # CI node pool — spot, scales to zero, tainted workload=ci
  ci_node_machine_type = "e2-standard-4"
  ci_node_min_count    = 0
  ci_node_max_count    = 2
  ci_node_spot         = true

  # Cloud SQL — small burstable tier for dev
  pg_tier                = "db-g1-small"
  pg_disk_size_gb        = 20
  pg_availability_type   = "ZONAL"
  pg_deletion_protection = false

  # Memorystore Redis — BASIC (no HA) for dev
  redis_tier           = "BASIC"
  redis_memory_size_gb = 1

  # GCS — STANDARD storage for dev
  gcs_storage_class = "STANDARD"

  deletion_protection = false

  # Retention
  backup_retention_days = 14
  log_retention_days    = 14

  labels = {
    environment = "dev"
    managed-by  = "tofu"
  }
}
