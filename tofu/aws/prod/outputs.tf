output "cluster_name" { value = module.cluster.cluster_name }
output "aws_region" { value = module.cluster.aws_region }
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
output "cognito_user_pool_id" { value = module.cluster.cognito_user_pool_id }
output "cognito_issuer_url" { value = module.cluster.cognito_issuer_url }
output "cognito_hosted_ui_domain" { value = module.cluster.cognito_hosted_ui_domain }
output "cognito_client_id" { value = module.cluster.cognito_client_id }
output "cognito_client_secret" {
  value     = module.cluster.cognito_client_secret
  sensitive = true
}
output "redis_auth_token" {
  value     = module.cluster.redis_auth_token
  sensitive = true
}
output "redis_tls_enabled" { value = module.cluster.redis_tls_enabled }
output "external_dns_irsa_role_arn" { value = module.cluster.external_dns_irsa_role_arn }
output "loki_irsa_role_arn" { value = module.cluster.loki_irsa_role_arn }
output "loki_bucket" { value = module.cluster.loki_bucket }
output "velero_irsa_role_arn" { value = module.cluster.velero_irsa_role_arn }
output "velero_bucket" { value = module.cluster.velero_bucket }
output "cluster_autoscaler_irsa_role_arn" { value = module.cluster.cluster_autoscaler_irsa_role_arn }
output "vault_kms_key_id" { value = module.cluster.vault_kms_key_id }
output "vault_kms_irsa_role_arn" { value = module.cluster.vault_kms_irsa_role_arn }
