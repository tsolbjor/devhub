# Shared by tofu/<cloud>/dev and tofu/<cloud>/prod — both link to this file,
# because both had a byte-identical copy of it. Anything that must differ per
# environment belongs in main.tf or variables-deployment.tf, which stay separate.
#
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

output "pg_forgejo_password" {
  value     = module.cluster.pg_forgejo_password
  sensitive = true
}

# ─── Redis ────────────────────────────────────────────────────────────

output "redis_host" {
  value = module.cluster.redis_host
}

output "redis_port" {
  value = module.cluster.redis_port
}

# No redis_password: Managed Redis has access keys disabled (Entra-only auth).

# ─── Blob Storage ─────────────────────────────────────────────────────

output "storage_account_name" {
  value = module.cluster.storage_account_name
}

# No storage_primary_access_key: shared-key auth is disabled on the account.

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

# ─── External-DNS / platform identities ──────────────────────────────

output "external_dns_identity_client_id" { value = module.cluster.external_dns_identity_client_id }
output "dns_zone_resource_group" { value = module.cluster.dns_zone_resource_group }
output "loki_identity_client_id" { value = module.cluster.loki_identity_client_id }
output "loki_container" { value = module.cluster.loki_container }
output "velero_identity_client_id" { value = module.cluster.velero_identity_client_id }
output "velero_container" { value = module.cluster.velero_container }
output "node_resource_group" { value = module.cluster.node_resource_group }
output "subscription_id" { value = module.cluster.subscription_id }
output "oidc_issuer_url" { value = module.cluster.oidc_issuer_url }

# ─── Vault auto-unseal ──────────────────────────────────────────────

output "vault_key_vault_name" { value = module.cluster.vault_key_vault_name }
output "vault_key_name" { value = module.cluster.vault_key_name }
output "vault_identity_client_id" { value = module.cluster.vault_identity_client_id }
