module "cluster" {
  source = "../modules/cluster"

  project_id = var.project_id
  region     = var.region
  prefix     = "devhub"

  # GKE — general-purpose nodes for production
  node_machine_type   = "e2-standard-4"
  node_count          = 3
  deletion_protection = true

  # Cloud SQL — general-purpose HA tier for production
  pg_tier               = "db-n1-standard-2"
  pg_disk_size_gb       = 100
  pg_availability_type  = "REGIONAL" # HA with hot standby
  pg_backup_enabled     = true
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
