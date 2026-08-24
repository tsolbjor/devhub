module "cluster" {
  source = "../modules/cluster"

  prefix              = var.prefix
  location            = "westeurope"
  resource_group_name = "${var.prefix}-rg"

  # Kubernetes API exposure — set in terraform.tfvars
  api_allowed_cidrs          = var.api_allowed_cidrs
  aad_admin_group_object_ids = var.aad_admin_group_object_ids

  # AKS — general-purpose nodes for production
  aks_node_vm_size   = "Standard_D4s_v3"
  aks_node_count     = 3
  aks_node_min_count = 3
  aks_node_max_count = 8

  # CI node pool — spot, scales to zero, tainted workload=ci
  ci_node_vm_size   = "Standard_D4s_v3"
  ci_node_min_count = 0
  ci_node_max_count = 6
  ci_node_spot      = true

  # PostgreSQL — general-purpose tier for production
  pg_sku_name              = "GP_Standard_D2s_v3"
  pg_version               = "16"
  pg_storage_mb            = 102400 # 100 GB
  pg_backup_retention_days = 14
  pg_ha_mode               = "ZoneRedundant"
  pg_standby_zone          = "2"
  pg_geo_redundant_backup  = true

  # Managed Redis — balanced SKU with high availability, Entra-only auth
  redis_sku_name          = "Balanced_B1"
  redis_high_availability = true

  # Blob storage — geo-redundant for production
  storage_replication = "GRS"

  # DNS — must match an existing Azure DNS zone (set in terraform.tfvars)
  domain                  = var.domain
  dns_zone_resource_group = var.dns_zone_resource_group

  # Entra ID — production requires an explicit App Role assignment before a
  # user can sign in, so a tenant account is not automatically a platform
  # account. Assign users/groups to devops-admins, developers or viewers.
  entra_require_assignment = true

  enable_delete_lock = true

  # Retention
  backup_retention_days = 90
  log_retention_days    = 90

  tags = {
    Environment = "prod"
    ManagedBy   = "tofu"
    Deployment  = var.prefix
    DeployedBy  = var.deployed_by
  }
}
