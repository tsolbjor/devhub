module "cluster" {
  source = "../modules/cluster"

  project_id = var.project_id
  region     = var.region
  prefix     = "devhub-dev"

  # GKE — small dev nodes
  node_machine_type = "e2-standard-2"
  node_count        = 2

  # Cloud SQL — small burstable tier for dev
  pg_tier               = "db-g1-small"
  pg_disk_size_gb       = 20
  pg_availability_type  = "ZONAL"
  pg_deletion_protection = false

  # Memorystore Redis — BASIC (no HA) for dev
  redis_tier           = "BASIC"
  redis_memory_size_gb = 1

  # GCS — STANDARD storage for dev
  gcs_storage_class = "STANDARD"

  deletion_protection = false

  labels = {
    environment = "dev"
    managed-by  = "tofu"
  }
}
