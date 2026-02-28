# ─── Cluster ─────────────────────────────────────────────────────────

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "resource_group_name" {
  value = module.cluster.resource_group_name
}

output "kubernetes_version" {
  value = module.cluster.kubernetes_version
}

output "location" {
  value = module.cluster.location
}

# ─── PostgreSQL ───────────────────────────────────────────────────────

output "pg_host" {
  value = module.cluster.pg_host
}

output "pg_port" {
  value = module.cluster.pg_port
}

output "pg_admin_login" {
  value = module.cluster.pg_admin_login
}

output "pg_admin_password" {
  value     = module.cluster.pg_admin_password
  sensitive = true
}

output "pg_keycloak_password" {
  value     = module.cluster.pg_keycloak_password
  sensitive = true
}

output "pg_gitlab_password" {
  value     = module.cluster.pg_gitlab_password
  sensitive = true
}

# ─── Redis ────────────────────────────────────────────────────────────

output "redis_host" {
  value = module.cluster.redis_host
}

output "redis_port" {
  value = module.cluster.redis_port
}

output "redis_password" {
  value     = module.cluster.redis_password
  sensitive = true
}

# ─── Blob Storage ─────────────────────────────────────────────────────

output "storage_account_name" {
  value = module.cluster.storage_account_name
}

output "storage_primary_access_key" {
  value     = module.cluster.storage_primary_access_key
  sensitive = true
}

output "gitlab_identity_client_id" {
  value = module.cluster.gitlab_identity_client_id
}

# ─── Entra ID ────────────────────────────────────────────────────────

output "entra_tenant_id" {
  value = module.cluster.entra_tenant_id
}

output "entra_keycloak_client_id" {
  value = module.cluster.entra_keycloak_client_id
}

output "entra_keycloak_client_secret" {
  value     = module.cluster.entra_keycloak_client_secret
  sensitive = true
}
