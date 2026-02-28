# ─── Cluster ─────────────────────────────────────────────────────────

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "aws_region" {
  description = "AWS region"
  value       = var.region
}

# ─── PostgreSQL ───────────────────────────────────────────────────────

output "pg_host" {
  description = "RDS PostgreSQL endpoint (private, reachable from EKS)"
  value       = aws_db_instance.main.address
}

output "pg_port" {
  description = "PostgreSQL port"
  value       = aws_db_instance.main.port
}

output "pg_admin_login" {
  description = "RDS administrator login"
  value       = aws_db_instance.main.username
}

output "pg_admin_password" {
  description = "RDS administrator password"
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
  description = "ElastiCache Redis primary endpoint"
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "redis_port" {
  description = "ElastiCache Redis port"
  value       = aws_elasticache_replication_group.main.port
}

# ─── S3 ──────────────────────────────────────────────────────────────

output "gitlab_s3_bucket_prefix" {
  description = "S3 bucket name prefix — buckets are {prefix}-artifacts, {prefix}-uploads, etc."
  value       = local.s3_bucket_prefix
}

output "aws_region_output" {
  description = "AWS region (for S3 connection config)"
  value       = var.region
}

# ─── IRSA ────────────────────────────────────────────────────────────

output "gitlab_irsa_role_arn" {
  description = "IAM Role ARN for GitLab IRSA — annotate the K8s service account with this value"
  value       = aws_iam_role.gitlab_irsa.arn
}

# ─── Cognito ─────────────────────────────────────────────────────────

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_issuer_url" {
  description = "Cognito OIDC issuer URL — used in Keycloak IdP config"
  value       = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

output "cognito_hosted_ui_domain" {
  description = "Cognito hosted UI domain (for auth/token endpoints)"
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}

output "cognito_client_id" {
  description = "Cognito app client ID for the Keycloak IdP"
  value       = aws_cognito_user_pool_client.keycloak_idp.id
}

output "cognito_client_secret" {
  description = "Cognito app client secret for the Keycloak IdP"
  value       = aws_cognito_user_pool_client.keycloak_idp.client_secret
  sensitive   = true
}
