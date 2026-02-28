# Current Azure/Entra ID context — provides tenant_id used in outputs
data "azurerm_client_config" "current" {}

# ─── Resource Group ───────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_management_lock" "main" {
  count      = var.enable_delete_lock ? 1 : 0
  name       = "${var.prefix}-delete-lock"
  scope      = azurerm_resource_group.main.id
  lock_level = "CanNotDelete"
  notes      = "Prevents accidental deletion of production resources"
}

# ─── Networking ───────────────────────────────────────────────────────

resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

# AKS nodes subnet
resource "azurerm_subnet" "aks" {
  name                 = "${var.prefix}-aks-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aks_subnet_cidr]
}

# PostgreSQL Flexible Server requires a delegated subnet
resource "azurerm_subnet" "postgresql" {
  name                 = "${var.prefix}-pg-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.pg_subnet_cidr]

  delegation {
    name = "postgresql-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# ─── AKS Cluster ──────────────────────────────────────────────────────

resource "azurerm_kubernetes_cluster" "main" {
  name                = "${var.prefix}-aks"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = replace(var.prefix, "-", "")
  kubernetes_version  = var.aks_kubernetes_version
  tags                = var.tags

  default_node_pool {
    name           = "system"
    node_count     = var.aks_node_count
    vm_size        = var.aks_node_vm_size
    vnet_subnet_id = azurerm_subnet.aks.id
    node_labels = {
      prefix = var.prefix
      role   = "worker"
      env    = lookup(var.tags, "Environment", "dev")
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
  }

  # Enable Workload Identity for keyless Azure service access (MSI)
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
}

# ─── PostgreSQL Flexible Server ───────────────────────────────────────

# Private DNS zone: required for VNet-integrated Flexible Server
resource "azurerm_private_dns_zone" "postgresql" {
  name                = "${replace(var.prefix, "-", "")}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgresql" {
  name                  = "${var.prefix}-pg-dns-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgresql.name
  resource_group_name   = azurerm_resource_group.main.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "random_password" "pg_admin" {
  length  = 32
  special = false
}

# Passwords for application DB users.
# NOTE: The users themselves must be created post-provision — Azure PostgreSQL
# Flexible Server has no Terraform resource for local user creation. Use
# setup scripts to run: CREATE USER keycloak/gitlab WITH PASSWORD '...';
resource "random_password" "pg_keycloak" {
  length  = 32
  special = false
}

resource "random_password" "pg_gitlab" {
  length  = 32
  special = false
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                   = "${var.prefix}-postgresql"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  version                = var.pg_version
  sku_name               = var.pg_sku_name
  storage_mb             = var.pg_storage_mb
  backup_retention_days  = var.pg_backup_retention_days
  administrator_login    = "pgadmin"
  administrator_password = random_password.pg_admin.result
  delegated_subnet_id    = azurerm_subnet.postgresql.id
  private_dns_zone_id    = azurerm_private_dns_zone.postgresql.id
  tags                   = var.tags

  dynamic "high_availability" {
    for_each = var.pg_ha_mode != "Disabled" ? [1] : []
    content {
      mode                      = var.pg_ha_mode
      standby_availability_zone = var.pg_standby_zone
    }
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgresql]
}

resource "azurerm_postgresql_flexible_server_database" "keycloak" {
  name      = "keycloak"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

resource "azurerm_postgresql_flexible_server_database" "gitlab" {
  name      = "gitlabhq_production"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# ─── Azure Cache for Redis ────────────────────────────────────────────

resource "azurerm_redis_cache" "main" {
  name                 = "${var.prefix}-redis"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  sku_name             = var.redis_sku_name
  family               = var.redis_family
  capacity             = var.redis_capacity
  non_ssl_port_enabled = false
  minimum_tls_version  = "1.2"
  tags                 = var.tags
}

# ─── Blob Storage ─────────────────────────────────────────────────────

locals {
  # Storage account name: 3-24 chars, lowercase alphanumeric only
  storage_account_name = substr(replace(lower(var.prefix), "-", ""), 0, 19)
}

resource "azurerm_storage_account" "main" {
  name                     = "${local.storage_account_name}store"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = var.storage_replication
  min_tls_version          = "TLS1_2"

  # Enable hierarchical namespace for better performance (optional, uncomment for Premium)
  # is_hns_enabled = false

  tags = var.tags
}

# GitLab storage containers — native Azure Blob (provider: AzureRM)
# No S3 shim required: GitLab CE Helm chart supports Azure Blob natively
resource "azurerm_storage_container" "gitlab_artifacts" {
  name                  = "gitlab-artifacts"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "gitlab_uploads" {
  name                  = "gitlab-uploads"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "gitlab_packages" {
  name                  = "gitlab-packages"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "gitlab_lfs" {
  name                  = "gitlab-lfs"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "gitlab_registry" {
  name                  = "gitlab-registry"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "gitlab_backups" {
  name                  = "gitlab-backups"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

# ─── Entra ID Identity Provider for Keycloak ─────────────────────────
#
# Keycloak federates with Entra ID — users authenticate via "Sign in with
# Microsoft" through Keycloak, which remains the single OIDC issuer for all
# services. This keeps the auth layer portable across clouds (UpCloud, GCP, AWS).
#
# Three App Roles are defined (devops-admins, developers, viewers). Assign
# Entra ID users or security groups to these roles in the Azure portal or
# via the azuread_app_role_assignment resource.
#
# The redirect URI is set to a placeholder here; setup-keycloak.sh updates it
# to the real domain (https://keycloak.<domain>/realms/devops/broker/entra/endpoint)
# using `az ad app update` after the domain is known.

resource "azuread_application" "keycloak_idp" {
  display_name = "${var.prefix}-keycloak-idp"

  web {
    redirect_uris = ["https://placeholder.invalid/realms/devops/broker/entra/endpoint"]
  }

  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph
    resource_access {
      id   = "37f7f235-527c-4136-accd-4a02d197296e" # openid
      type = "Scope"
    }
    resource_access {
      id   = "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0" # email
      type = "Scope"
    }
    resource_access {
      id   = "14dad69e-099b-42c9-810b-d002981feec1" # profile
      type = "Scope"
    }
  }

  # App Roles map to Keycloak groups via setup-keycloak.sh IdP mappers.
  # Assign Entra ID users/groups to these roles in the Azure portal.
  app_role {
    allowed_member_types = ["User"]
    description          = "Full access to DevOps platform administration"
    display_name         = "DevOps Admins"
    enabled              = true
    id                   = "a1b2c3d4-0001-4000-8000-devopsadmins0" # stable GUID
    value                = "devops-admins"
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Developer access to DevOps platform services"
    display_name         = "Developers"
    enabled              = true
    id                   = "a1b2c3d4-0002-4000-8000-developers000" # stable GUID
    value                = "developers"
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Read-only access to DevOps platform services"
    display_name         = "Viewers"
    enabled              = true
    id                   = "a1b2c3d4-0003-4000-8000-viewers000000" # stable GUID
    value                = "viewers"
  }
}

resource "azuread_service_principal" "keycloak_idp" {
  client_id                    = azuread_application.keycloak_idp.client_id
  app_role_assignment_required = var.entra_require_assignment
}

resource "azuread_application_password" "keycloak_idp" {
  application_id = azuread_application.keycloak_idp.id
  display_name   = "keycloak-idp-secret"
  end_date       = "2099-01-01T00:00:00Z"
}

# ─── Workload Identity for GitLab ─────────────────────────────────────
#
# Allows GitLab pods (webservice, sidekiq) to access Blob Storage without
# a storage account key. The K8s service account "gitlab" in the "gitlab"
# namespace exchanges its projected OIDC token for an Azure AD token.
#
# AKS must have oidc_issuer_enabled and workload_identity_enabled (set above).

resource "azurerm_user_assigned_identity" "gitlab" {
  name                = "${var.prefix}-gitlab-identity"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

# Grant the identity read/write access to all blob containers in the storage account
resource "azurerm_role_assignment" "gitlab_storage" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.gitlab.principal_id
}

# Federated credential: trusts tokens from the AKS OIDC issuer for the
# "gitlab" service account in the "gitlab" namespace.
# The GitLab Helm chart creates this SA when global.serviceAccount.enabled=true.
resource "azurerm_federated_identity_credential" "gitlab" {
  name                = "${var.prefix}-gitlab-fedcred"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.gitlab.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:gitlab:gitlab"
}
