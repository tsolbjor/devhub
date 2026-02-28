# ─── Cluster ─────────────────────────────────────────────────────────

output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.main.name
}

output "project_id" {
  description = "GCP project ID"
  value       = var.project_id
}

output "region" {
  description = "GCP region"
  value       = var.region
}

# ─── PostgreSQL ───────────────────────────────────────────────────────

output "pg_host" {
  description = "Cloud SQL private IP address (reachable from GKE via VPC)"
  value       = google_sql_database_instance.main.private_ip_address
}

output "pg_port" {
  description = "PostgreSQL port"
  value       = 5432
}

output "pg_admin_login" {
  description = "PostgreSQL administrator login"
  value       = google_sql_user.pg_admin.name
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
  description = "Memorystore Redis host (private IP within VPC)"
  value       = google_redis_instance.main.host
}

output "redis_port" {
  description = "Memorystore Redis port"
  value       = google_redis_instance.main.port
}

output "redis_auth_string" {
  description = "Memorystore Redis AUTH string — store in gitlab-redis-secret K8s secret"
  value       = google_redis_instance.main.auth_string
  sensitive   = true
}

# ─── GCS ─────────────────────────────────────────────────────────────

output "gitlab_gcs_bucket_prefix" {
  description = "GCS bucket name prefix — buckets are {prefix}-artifacts, {prefix}-uploads, etc."
  value       = local.gcs_bucket_prefix
}

# ─── Workload Identity ────────────────────────────────────────────────

output "gitlab_gsa_email" {
  description = "GitLab Google Service Account email — annotate the K8s service account with this value"
  value       = google_service_account.gitlab.email
}
