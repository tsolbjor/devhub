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

output "pg_forgejo_password" {
  description = "Pre-generated password for the forgejo DB user — create it post-provision"
  value       = random_password.pg_forgejo.result
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
  description = "Memorystore Redis AUTH string — store in the forgejo-redis-secret K8s secret"
  value       = google_redis_instance.main.auth_string
  sensitive   = true
}

# ─── GCS ─────────────────────────────────────────────────────────────

# ─── Workload Identity ────────────────────────────────────────────────

output "external_dns_gsa_email" {
  description = "External-DNS Google Service Account email — written to tofu-outputs.env by sync-tofu-outputs.sh"
  value       = google_service_account.external_dns.email
}

output "loki_gsa_email" {
  description = "Loki Google Service Account email (GCS chunk storage)"
  value       = google_service_account.loki.email
}

output "loki_bucket" {
  description = "GCS bucket for Loki chunks"
  value       = google_storage_bucket.loki.name
}

output "velero_gsa_email" {
  description = "Velero Google Service Account email (cluster backups)"
  value       = google_service_account.velero.email
}

output "velero_bucket" {
  description = "GCS bucket for Velero backups"
  value       = google_storage_bucket.velero.name
}

# ─── Vault auto-unseal ───────────────────────────────────────────────

output "vault_gsa_email" {
  description = "Vault Google Service Account email (KMS auto-unseal)"
  value       = google_service_account.vault.email
}

output "vault_kms_region" {
  description = "Cloud KMS location of the Vault key ring"
  value       = google_kms_key_ring.vault.location
}

output "vault_kms_key_ring" {
  description = "Cloud KMS key ring holding the Vault unseal key"
  value       = google_kms_key_ring.vault.name
}

output "vault_kms_crypto_key" {
  description = "Cloud KMS crypto key used for Vault auto-unseal"
  value       = google_kms_crypto_key.vault_unseal.name
}

output "oidc_issuer_url" {
  description = "GKE OIDC issuer URL (used for Vault JWT auth from workload clusters)"
  value       = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/clusters/${google_container_cluster.main.name}"
}
