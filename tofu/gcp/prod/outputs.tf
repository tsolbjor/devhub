output "cluster_name"            { value = module.cluster.cluster_name }
output "project_id"              { value = module.cluster.project_id }
output "region"                  { value = module.cluster.region }
output "pg_host"                 { value = module.cluster.pg_host }
output "pg_port"                 { value = module.cluster.pg_port }
output "pg_admin_login"          { value = module.cluster.pg_admin_login }
output "pg_admin_password"       { value = module.cluster.pg_admin_password;       sensitive = true }
output "pg_keycloak_password"    { value = module.cluster.pg_keycloak_password;    sensitive = true }
output "pg_gitlab_password"      { value = module.cluster.pg_gitlab_password;      sensitive = true }
output "redis_host"              { value = module.cluster.redis_host }
output "redis_port"              { value = module.cluster.redis_port }
output "redis_auth_string"       { value = module.cluster.redis_auth_string;       sensitive = true }
output "gitlab_gcs_bucket_prefix" { value = module.cluster.gitlab_gcs_bucket_prefix }
output "gitlab_gsa_email"        { value = module.cluster.gitlab_gsa_email }
