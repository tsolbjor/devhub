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

output "pg_forgejo_password" {
  description = "Pre-generated password for the forgejo DB user — create it post-provision"
  value       = random_password.pg_forgejo.result
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

output "redis_auth_token" {
  description = "ElastiCache AUTH token — store in the forgejo-redis-secret K8s secret"
  value       = random_password.redis_auth.result
  sensitive   = true
}

output "redis_tls_enabled" {
  description = "Whether Redis requires TLS (rediss://)"
  value       = aws_elasticache_replication_group.main.transit_encryption_enabled
}

# ─── S3 ──────────────────────────────────────────────────────────────

output "aws_region_output" {
  description = "AWS region (for S3 connection config)"
  value       = var.region
}

# ─── IRSA ────────────────────────────────────────────────────────────

output "external_dns_irsa_role_arn" {
  description = "IAM Role ARN for external-dns IRSA — written to tofu-outputs.env by sync-tofu-outputs.sh"
  value       = aws_iam_role.external_dns_irsa.arn
}

output "loki_irsa_role_arn" {
  description = "IAM Role ARN for Loki IRSA (S3 chunk storage)"
  value       = aws_iam_role.loki_irsa.arn
}

output "loki_bucket" {
  description = "S3 bucket for Loki chunks"
  value       = aws_s3_bucket.loki.id
}

output "velero_irsa_role_arn" {
  description = "IAM Role ARN for Velero IRSA (cluster backups)"
  value       = aws_iam_role.velero_irsa.arn
}

output "velero_bucket" {
  description = "S3 bucket for Velero backups"
  value       = aws_s3_bucket.velero.id
}

output "cluster_autoscaler_irsa_role_arn" {
  description = "IAM Role ARN for cluster-autoscaler IRSA"
  value       = aws_iam_role.cluster_autoscaler.arn
}

# ─── Vault auto-unseal ───────────────────────────────────────────────

output "vault_kms_key_id" {
  description = "KMS key ID used for Vault auto-unseal"
  value       = aws_kms_key.vault_unseal.key_id
}

output "vault_kms_irsa_role_arn" {
  description = "IAM Role ARN granting the Vault service account access to the unseal key"
  value       = aws_iam_role.vault_kms_irsa.arn
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
