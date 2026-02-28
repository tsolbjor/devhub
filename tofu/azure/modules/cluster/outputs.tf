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

output "pg_gitlab_password" {
  description = "Pre-generated password for gitlab DB user — create user post-provision"
  value       = random_password.pg_gitlab.result
  sensitive   = true
}

# ─── Redis ────────────────────────────────────────────────────────────

output "redis_host" {
  description = "Azure Cache for Redis hostname"
  value       = azurerm_redis_cache.main.hostname
}

output "redis_port" {
  description = "Redis SSL port (6380)"
  value       = azurerm_redis_cache.main.ssl_port
}

output "redis_password" {
  description = "Redis primary access key"
  value       = azurerm_redis_cache.main.primary_access_key
  sensitive   = true
}

# ─── Blob Storage ─────────────────────────────────────────────────────

output "storage_account_name" {
  description = "Azure Storage Account name"
  value       = azurerm_storage_account.main.name
}

output "storage_primary_access_key" {
  description = "Storage Account primary access key (used for registry; main GitLab storage uses managed identity)"
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

output "gitlab_identity_client_id" {
  description = "Client ID of the GitLab managed identity — annotate the K8s service account with this value"
  value       = azurerm_user_assigned_identity.gitlab.client_id
}
