module "cluster" {
  source = "../modules/cluster"

  prefix              = "devhub"
  location            = "westeurope"
  resource_group_name = "devhub-prod-rg"

  # AKS — general-purpose nodes for production
  aks_node_vm_size = "Standard_D4s_v3"
  aks_node_count   = 3

  # PostgreSQL — general-purpose tier for production
  pg_sku_name              = "GP_Standard_D2s_v3"
  pg_version               = "16"
  pg_storage_mb            = 102400 # 100 GB
  pg_backup_retention_days = 14
  pg_ha_mode               = "ZoneRedundant"
  pg_standby_zone          = "2"

  # Redis — Standard C1 (1 GB) with replication for production
  redis_sku_name = "Standard"
  redis_family   = "C"
  redis_capacity = 1

  # Blob storage — geo-redundant for production
  storage_replication = "GRS"

  enable_delete_lock = true

  # api_server_authorized_ip_ranges = ["0.0.0.0/0"] # TODO: restrict to known CIDRs

  tags = {
    Environment = "prod"
    ManagedBy   = "tofu"
  }
}
