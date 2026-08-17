# ─── Platform service storage and keys ────────────────────────────────
#
# Backing resources for platform components that must not keep state on a local
# PVC: Loki (log storage), Velero (cluster backups), Vault (Key Vault auto-unseal).

# ─── Loki blob storage ────────────────────────────────────────────────

resource "azurerm_storage_container" "loki" {
  name                  = "loki"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_user_assigned_identity" "loki" {
  name                = "${var.prefix}-loki-identity"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "loki_storage" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.loki.principal_id
}

resource "azurerm_federated_identity_credential" "loki" {
  name                = "${var.prefix}-loki-fedcred"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.loki.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:monitoring:loki"
}

# ─── Velero blob storage ──────────────────────────────────────────────

resource "azurerm_storage_container" "velero" {
  name                  = "velero"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_user_assigned_identity" "velero" {
  name                = "${var.prefix}-velero-identity"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "velero_storage" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.velero.principal_id
}

# Velero also snapshots managed disks, which needs Contributor on the node
# resource group (where AKS keeps the disks).
resource "azurerm_role_assignment" "velero_disks" {
  scope                = azurerm_kubernetes_cluster.main.node_resource_group_id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.velero.principal_id
}

resource "azurerm_federated_identity_credential" "velero" {
  name                = "${var.prefix}-velero-fedcred"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.velero.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:velero:velero"
}

# Blob lifecycle: expire old Loki chunks and old backup versions.
resource "azurerm_storage_management_policy" "main" {
  storage_account_id = azurerm_storage_account.main.id

  rule {
    name    = "loki-chunk-expiry"
    enabled = true
    filters {
      prefix_match = ["loki"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.log_retention_days
      }
    }
  }

  rule {
    name    = "backup-expiry"
    enabled = true
    filters {
      prefix_match = ["velero"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.backup_retention_days
      }
      version {
        delete_after_days_since_creation = var.backup_retention_days
      }
    }
  }
}

# ─── Vault auto-unseal (Key Vault) ────────────────────────────────────
#
# With auto-unseal, Vault's unseal shares never have to be written down or kept
# in a Kubernetes secret — Vault decrypts its own root key via Key Vault on start.

resource "azurerm_key_vault" "vault_unseal" {
  name                       = substr(replace("${var.prefix}-unseal", "-", ""), 0, 24)
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 30
  rbac_authorization_enabled = true
  tags                       = var.tags
}

# The identity running tofu needs key create rights to make the unseal key.
resource "azurerm_role_assignment" "vault_unseal_admin" {
  scope                = azurerm_key_vault.vault_unseal.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_key" "vault_unseal" {
  name         = "vault-unseal"
  key_vault_id = azurerm_key_vault.vault_unseal.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["decrypt", "encrypt", "wrapKey", "unwrapKey"]

  depends_on = [azurerm_role_assignment.vault_unseal_admin]
}

resource "azurerm_user_assigned_identity" "vault" {
  name                = "${var.prefix}-vault-identity"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "vault_unseal_user" {
  scope                = azurerm_key_vault.vault_unseal.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.vault.principal_id
}

resource "azurerm_federated_identity_credential" "vault" {
  name                = "${var.prefix}-vault-fedcred"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.vault.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:vault:vault"
}
