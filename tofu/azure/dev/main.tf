module "cluster" {
  source = "../modules/cluster"

  prefix              = "devhub-dev"
  location            = "norwayeast"
  resource_group_name = "devhub-dev-rg"

  # AKS — small dev nodes
  aks_node_vm_size = "Standard_B2s"
  aks_node_count   = 2

  # PostgreSQL — burstable tier for dev
  pg_sku_name              = "B_Standard_B1ms"
  pg_version               = "16"
  pg_storage_mb            = 32768
  pg_backup_retention_days = 7
  pg_ha_mode               = "Disabled"

  # Redis — Basic C0 (250 MB) for dev
  redis_sku_name = "Basic"
  redis_family   = "C"
  redis_capacity = 0

  # Blob storage — locally-redundant for dev
  storage_replication = "LRS"

  enable_delete_lock = false

  tags = {
    Environment = "dev"
    ManagedBy   = "tofu"
  }
}
