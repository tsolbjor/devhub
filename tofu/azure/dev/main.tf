module "cluster" {
  source = "../modules/cluster"

  prefix              = var.prefix
  location            = "norwayeast"
  resource_group_name = "${var.prefix}-rg"

  # Kubernetes API exposure — set in terraform.tfvars
  api_allowed_cidrs          = var.api_allowed_cidrs
  aad_admin_group_object_ids = var.aad_admin_group_object_ids

  # AKS — small dev nodes
  aks_node_vm_size   = "Standard_B2s"
  aks_node_count     = 2
  aks_node_min_count = 2
  aks_node_max_count = 5

  # CI node pool — spot, scales to zero, tainted workload=ci
  ci_node_vm_size   = "Standard_D4s_v3"
  ci_node_min_count = 0
  ci_node_max_count = 2
  ci_node_spot      = true

  # PostgreSQL — burstable tier for dev
  pg_sku_name              = "B_Standard_B1ms"
  pg_version               = "16"
  pg_storage_mb            = 32768
  pg_backup_retention_days = 7
  pg_ha_mode               = "Disabled"
  pg_geo_redundant_backup  = false

  # Redis — Basic C0 (250 MB) for dev
  redis_sku_name = "Basic"
  redis_family   = "C"
  redis_capacity = 0

  # Blob storage — locally-redundant for dev
  storage_replication = "LRS"

  # DNS — must match an existing Azure DNS zone (set in terraform.tfvars)
  domain                  = var.domain
  dns_zone_resource_group = var.dns_zone_resource_group

  enable_delete_lock = false

  # Retention
  backup_retention_days = 14
  log_retention_days    = 14

  tags = {
    Environment = "dev"
    ManagedBy   = "tofu"
    Deployment  = var.prefix
    DeployedBy  = var.deployed_by
  }
}
