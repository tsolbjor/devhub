output "cluster_name"              { value = module.cluster.cluster_name }
output "aws_region"                { value = module.cluster.aws_region }
output "pg_host"                   { value = module.cluster.pg_host }
output "pg_port"                   { value = module.cluster.pg_port }
output "pg_admin_login"            { value = module.cluster.pg_admin_login }
output "pg_admin_password"         { value = module.cluster.pg_admin_password;      sensitive = true }
output "pg_keycloak_password"      { value = module.cluster.pg_keycloak_password;   sensitive = true }
output "pg_gitlab_password"        { value = module.cluster.pg_gitlab_password;     sensitive = true }
output "redis_host"                { value = module.cluster.redis_host }
output "redis_port"                { value = module.cluster.redis_port }
output "gitlab_s3_bucket_prefix"   { value = module.cluster.gitlab_s3_bucket_prefix }
output "gitlab_irsa_role_arn"      { value = module.cluster.gitlab_irsa_role_arn }
output "cognito_user_pool_id"      { value = module.cluster.cognito_user_pool_id }
output "cognito_issuer_url"        { value = module.cluster.cognito_issuer_url }
output "cognito_hosted_ui_domain"  { value = module.cluster.cognito_hosted_ui_domain }
output "cognito_client_id"         { value = module.cluster.cognito_client_id }
output "cognito_client_secret"     { value = module.cluster.cognito_client_secret;  sensitive = true }
