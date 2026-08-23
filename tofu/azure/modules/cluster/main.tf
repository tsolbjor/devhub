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

    auto_scaling_enabled = true
    min_count            = var.aks_node_min_count
    max_count            = var.aks_node_max_count

    node_labels = {
      prefix = var.prefix
      role   = "platform"
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

  # API server exposure. An empty api_allowed_cidrs means no public endpoint at
  # all (private cluster, reachable over the VNet / VPN / `az aks command invoke`).
  private_cluster_enabled = length(var.api_allowed_cidrs) == 0

  dynamic "api_server_access_profile" {
    for_each = length(var.api_allowed_cidrs) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_allowed_cidrs
    }
  }

  # Entra ID + Azure RBAC for cluster auth. When admin groups are supplied the
  # local admin kubeconfig (a permanent cluster-admin client cert that cannot be
  # revoked or audited per-user) is switched off.
  dynamic "azure_active_directory_role_based_access_control" {
    for_each = length(var.aad_admin_group_object_ids) > 0 ? [1] : []
    content {
      azure_rbac_enabled     = true
      admin_group_object_ids = var.aad_admin_group_object_ids
    }
  }

  local_account_disabled = length(var.aad_admin_group_object_ids) > 0

  # Enable Workload Identity for keyless Azure service access (MSI)
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  lifecycle {
    # Node count is owned by the AKS autoscaler once it is running.
    ignore_changes = [default_node_pool[0].node_count]
  }
}

# Tainted, spot-backed pool for Woodpecker CI jobs so build containers never share a
# node with Vault/Keycloak/PostgreSQL.
resource "azurerm_kubernetes_cluster_node_pool" "ci" {
  count = var.ci_node_max_count > 0 ? 1 : 0

  name                  = "ci"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.ci_node_vm_size
  vnet_subnet_id        = azurerm_subnet.aks.id
  # Lets the provider rotate the pool in place when vm_size (or similar)
  # changes, instead of erroring: it creates this temp pool, swaps, deletes it.
  temporary_name_for_rotation = "citmp"

  auto_scaling_enabled = true
  min_count            = var.ci_node_min_count
  max_count            = var.ci_node_max_count

  priority        = var.ci_node_spot ? "Spot" : "Regular"
  eviction_policy = var.ci_node_spot ? "Delete" : null
  spot_max_price  = var.ci_node_spot ? -1 : null

  node_labels = merge(
    { role = "ci" },
    var.ci_node_spot ? { "kubernetes.azure.com/scalesetpriority" = "spot" } : {}
  )

  node_taints = concat(
    ["workload=ci:NoSchedule"],
    var.ci_node_spot ? ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"] : []
  )

  tags = var.tags
}

# Untainted overflow pool in a different VM family than the system pool: when
# the subscription's quota for the system pool's family is exhausted (B-series
# filled at 5×B2s on a default subscription), the autoscaler's scale-ups fail
# silently and the tail of the platform sits Pending forever. A second family
# draws from a separate quota bucket.
resource "azurerm_kubernetes_cluster_node_pool" "worker" {
  count = var.worker_node_max_count > 0 ? 1 : 0

  name                  = "worker"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.worker_node_vm_size
  vnet_subnet_id        = azurerm_subnet.aks.id

  auto_scaling_enabled = true
  min_count            = var.worker_node_min_count
  max_count            = var.worker_node_max_count

  node_labels = { role = "worker" }

  tags = var.tags
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
# setup scripts to run: CREATE USER keycloak/forgejo WITH PASSWORD '...';
resource "random_password" "pg_keycloak" {
  length  = 32
  special = false
}

resource "random_password" "pg_forgejo" {
  length  = 32
  special = false
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                         = "${var.prefix}-postgresql"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  version                      = var.pg_version
  sku_name                     = var.pg_sku_name
  storage_mb                   = var.pg_storage_mb
  backup_retention_days        = var.pg_backup_retention_days
  geo_redundant_backup_enabled = var.pg_geo_redundant_backup
  administrator_login          = "pgadmin"
  administrator_password       = random_password.pg_admin.result
  delegated_subnet_id          = azurerm_subnet.postgresql.id
  private_dns_zone_id          = azurerm_private_dns_zone.postgresql.id
  tags                         = var.tags

  # VNet integration (delegated subnet) and public access are mutually
  # exclusive; azurerm v4 defaults this to true, and Azure then rejects the
  # create with ConflictingPublicNetworkAccessAndVirtualNetworkConfiguration.
  public_network_access_enabled = false

  dynamic "high_availability" {
    for_each = var.pg_ha_mode != "Disabled" ? [1] : []
    content {
      mode                      = var.pg_ha_mode
      standby_availability_zone = var.pg_standby_zone
    }
  }

  lifecycle {
    # Azure picks an availability zone at creation when none is configured;
    # without this, every later plan tries to "move" the server back to no
    # zone and the apply fails ("zone can only be changed when exchanged
    # with the standby zone").
    ignore_changes = [zone]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgresql]
}

resource "azurerm_postgresql_flexible_server_database" "keycloak" {
  name      = "keycloak"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

resource "azurerm_postgresql_flexible_server_database" "forgejo" {
  name      = "forgejo"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# ─── Azure Cache for Redis ────────────────────────────────────────────

# Azure Managed Redis (the Redis-Enterprise-based successor to Azure Cache
# for Redis), Entra-only: access keys are disabled, so there is no password to
# leak or rotate — a client authenticates as a managed identity that has been
# granted an azurerm_managed_redis_access_policy_assignment. Nothing on the
# platform consumes Redis today (Forgejo runs its default memory/leveldb
# backends); this is capacity for workloads, keyless from the start.
resource "azurerm_managed_redis" "main" {
  name                      = "${var.prefix}-redis"
  resource_group_name       = azurerm_resource_group.main.name
  location                  = azurerm_resource_group.main.location
  sku_name                  = var.redis_sku_name
  high_availability_enabled = var.redis_high_availability

  default_database {
    access_keys_authentication_enabled = false
    client_protocol                    = "Encrypted"
  }

  tags = var.tags
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

  # Blob versioning + soft delete so a bad backup overwrite is recoverable.
  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  # Enable hierarchical namespace for better performance (optional, uncomment for Premium)
  # is_hns_enabled = false

  tags = var.tags
}

# NOTE: Forgejo keeps repositories, LFS objects, packages and container registry
# blobs on its PersistentVolume. Forgejo supports local disk or S3-compatible
# storage only — Azure Blob and GCS have no S3 API — so rather than run two
# storage models, every cloud uses the volume, and Velero backs it up alongside
# the managed PostgreSQL PITR.

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

# The identity running this apply — Entra objects list it as their owner so
# they stay editable after a PIM-elevated directory role (the usual way the
# create permission was obtained) expires. An ownerless app registration is
# frozen the moment the elevation lapses: even fixing its own redirect URI
# then needs a new PIM activation.
data "azuread_client_config" "current" {}

resource "azuread_application" "keycloak_idp" {
  display_name = "${var.prefix}-keycloak-idp"
  owners       = [data.azuread_client_config.current.object_id]

  web {
    # Keycloak's broker callback for the Entra IdP. The domain is a module
    # input now, so no placeholder + post-hoc `az ad app update` patching —
    # that update failed silently once and every Entra login then died on
    # AADSTS50011 (redirect URI mismatch).
    redirect_uris = ["https://keycloak.${var.domain}/realms/devops/broker/entra/endpoint"]
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
    id                   = "a1b2c3d4-0001-4000-8000-0de70d5ad115" # stable GUID: devops-admins
    value                = "devops-admins"
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Developer access to DevOps platform services"
    display_name         = "Developers"
    enabled              = true
    id                   = "a1b2c3d4-0002-4000-8000-0de7e10be5c0" # stable GUID: developers
    value                = "developers"
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Read-only access to DevOps platform services"
    display_name         = "Viewers"
    enabled              = true
    id                   = "a1b2c3d4-0003-4000-8000-00a1e0e50003" # stable GUID: viewers
    value                = "viewers"
  }
}

resource "azuread_service_principal" "keycloak_idp" {
  client_id                    = azuread_application.keycloak_idp.client_id
  app_role_assignment_required = var.entra_require_assignment
  owners                       = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "keycloak_idp" {
  application_id = azuread_application.keycloak_idp.id
  display_name   = "keycloak-idp-secret"
  end_date       = "2099-01-01T00:00:00Z"
}

# ─── External-DNS Workload Identity ──────────────────────────────────
# Allows external-dns to manage Azure DNS records for the cluster's domain.
# The K8s service account "external-dns/external-dns" uses the federated credential.

data "azurerm_dns_zone" "main" {
  name                = var.domain
  resource_group_name = var.dns_zone_resource_group != "" ? var.dns_zone_resource_group : azurerm_resource_group.main.name
}

resource "azurerm_user_assigned_identity" "external_dns" {
  name                = "${var.prefix}-external-dns-identity"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "external_dns_dns_contributor" {
  scope                = data.azurerm_dns_zone.main.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.external_dns.principal_id
}

resource "azurerm_federated_identity_credential" "external_dns" {
  name                = "${var.prefix}-external-dns-fedcred"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.external_dns.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:external-dns:external-dns"
}
