output "cluster_name" { value = module.cluster.cluster_name }
output "project_id" { value = module.cluster.project_id }
output "region" { value = module.cluster.region }
output "pg_host" { value = module.cluster.pg_host }
output "pg_port" { value = module.cluster.pg_port }
output "pg_admin_login" { value = module.cluster.pg_admin_login }
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
output "redis_host" { value = module.cluster.redis_host }
output "redis_port" { value = module.cluster.redis_port }
output "redis_auth_string" {
  value     = module.cluster.redis_auth_string
  sensitive = true
}
output "external_dns_gsa_email" { value = module.cluster.external_dns_gsa_email }
output "cert_manager_gsa_email" { value = module.cluster.cert_manager_gsa_email }
output "loki_gsa_email" { value = module.cluster.loki_gsa_email }
output "loki_bucket" { value = module.cluster.loki_bucket }
output "velero_gsa_email" { value = module.cluster.velero_gsa_email }
output "velero_bucket" { value = module.cluster.velero_bucket }
output "vault_gsa_email" { value = module.cluster.vault_gsa_email }
output "vault_kms_region" { value = module.cluster.vault_kms_region }
output "vault_kms_key_ring" { value = module.cluster.vault_kms_key_ring }
output "vault_kms_crypto_key" { value = module.cluster.vault_kms_crypto_key }
output "oidc_issuer_url" { value = module.cluster.oidc_issuer_url }
