# ─── Cluster ─────────────────────────────────────────────────────────

output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.main.name
}

output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.main.name
}

output "kubernetes_version" {
  description = "Kubernetes version"
  value       = azurerm_kubernetes_cluster.main.kubernetes_version
}

output "location" {
  description = "Azure region"
  value       = azurerm_resource_group.main.location
}

# ─── PostgreSQL ───────────────────────────────────────────────────────

output "pg_host" {
  description = "PostgreSQL Flexible Server FQDN (private, reachable from AKS)"
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "pg_port" {
  description = "PostgreSQL port"
  value       = 5432
}

output "pg_admin_login" {
  description = "PostgreSQL administrator login"
  value       = azurerm_postgresql_flexible_server.main.administrator_login
}

output "pg_admin_password" {
  description = "PostgreSQL administrator password"
  value       = random_password.pg_admin.result
  sensitive   = true
}

output "pg_keycloak_password" {
  description = "Pre-generated password for keycloak DB user — create user post-provision"
  value       = random_password.pg_keycloak.result
  sensitive   = true
}

output "pg_forgejo_password" {
  description = "Pre-generated password for the forgejo DB user — create it post-provision"
  value       = random_password.pg_forgejo.result
  sensitive   = true
}

# ─── Redis ────────────────────────────────────────────────────────────

output "redis_host" {
  description = "Azure Managed Redis hostname"
  value       = azurerm_managed_redis.main.hostname
}

output "redis_port" {
  description = "Managed Redis TLS port"
  value       = azurerm_managed_redis.main.default_database[0].port
}

# No redis_password output: access keys are disabled — clients authenticate as
# managed identities via azurerm_managed_redis_access_policy_assignment.

# ─── Blob Storage ─────────────────────────────────────────────────────

output "storage_account_name" {
  description = "Azure Storage Account name"
  value       = azurerm_storage_account.main.name
}

output "storage_primary_access_key" {
  description = "Storage Account primary access key (Loki and Velero use managed identity)"
  value       = azurerm_storage_account.main.primary_access_key
  sensitive   = true
}

# ─── Entra ID ────────────────────────────────────────────────────────

output "entra_tenant_id" {
  description = "Entra ID tenant ID — used in Keycloak IdP OIDC endpoint URLs"
  value       = data.azurerm_client_config.current.tenant_id
}

output "entra_keycloak_client_id" {
  description = "App Registration client ID for the Keycloak IdP"
  value       = azuread_application.keycloak_idp.client_id
}

output "entra_keycloak_client_secret" {
  description = "App Registration client secret for the Keycloak IdP"
  value       = azuread_application_password.keycloak_idp.value
  sensitive   = true
}

# ─── Workload Identity ────────────────────────────────────────────────

output "external_dns_identity_client_id" {
  description = "Client ID of the external-dns managed identity — written to tofu-outputs.env by sync-tofu-outputs.sh"
  value       = azurerm_user_assigned_identity.external_dns.client_id
}

output "loki_identity_client_id" {
  description = "Client ID of the Loki managed identity (blob chunk storage)"
  value       = azurerm_user_assigned_identity.loki.client_id
}

output "loki_container" {
  description = "Blob container for Loki chunks"
  value       = azurerm_storage_container.loki.name
}

output "velero_identity_client_id" {
  description = "Client ID of the Velero managed identity (cluster backups)"
  value       = azurerm_user_assigned_identity.velero.client_id
}

output "velero_container" {
  description = "Blob container for Velero backups"
  value       = azurerm_storage_container.velero.name
}

output "node_resource_group" {
  description = "AKS-managed node resource group (needed by Velero disk snapshots)"
  value       = azurerm_kubernetes_cluster.main.node_resource_group
}

output "subscription_id" {
  description = "Azure subscription ID"
  value       = data.azurerm_client_config.current.subscription_id
}

# ─── Vault auto-unseal ───────────────────────────────────────────────

output "vault_key_vault_name" {
  description = "Key Vault holding the Vault auto-unseal key"
  value       = azurerm_key_vault.vault_unseal.name
}

output "vault_key_name" {
  description = "Key Vault key name used for Vault auto-unseal"
  value       = azurerm_key_vault_key.vault_unseal.name
}

output "vault_identity_client_id" {
  description = "Client ID of the managed identity allowed to use the unseal key"
  value       = azurerm_user_assigned_identity.vault.client_id
}

output "oidc_issuer_url" {
  description = "AKS OIDC issuer URL (used for Vault JWT auth from workload clusters)"
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}
