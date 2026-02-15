# ─── Cluster ─────────────────────────────────────────────────────────

output "cluster_id" {
  description = "The ID of the Kubernetes cluster"
  value       = upcloud_kubernetes_cluster.main.id
}

output "cluster_name" {
  description = "The name of the Kubernetes cluster"
  value       = upcloud_kubernetes_cluster.main.name
}

output "network_id" {
  description = "The ID of the private network"
  value       = upcloud_network.kubernetes.id
}

output "network_cidr" {
  description = "The CIDR block of the private network"
  value       = var.network_cidr
}

output "kubernetes_version" {
  description = "The Kubernetes version of the cluster"
  value       = upcloud_kubernetes_cluster.main.version
}

output "zone" {
  description = "The zone where the cluster is deployed"
  value       = var.zone
}

# ─── PostgreSQL ──────────────────────────────────────────────────────

output "pg_host" {
  description = "PostgreSQL private hostname"
  value       = upcloud_managed_database_postgresql.main.service_host
}

output "pg_port" {
  description = "PostgreSQL port"
  value       = upcloud_managed_database_postgresql.main.service_port
}

output "pg_keycloak_password" {
  description = "PostgreSQL password for keycloak user"
  value       = upcloud_managed_database_user.keycloak.password
  sensitive   = true
}

output "pg_gitlab_password" {
  description = "PostgreSQL password for gitlab user"
  value       = upcloud_managed_database_user.gitlab.password
  sensitive   = true
}

# ─── Valkey ──────────────────────────────────────────────────────────

output "valkey_host" {
  description = "Valkey private hostname"
  value       = upcloud_managed_database_valkey.main.service_host
}

output "valkey_port" {
  description = "Valkey port"
  value       = upcloud_managed_database_valkey.main.service_port
}

output "valkey_password" {
  description = "Valkey default user password"
  value       = upcloud_managed_database_valkey.main.service_password
  sensitive   = true
}

# ─── Object Storage ─────────────────────────────────────────────────

output "s3_endpoint" {
  description = "S3-compatible public endpoint"
  value = [
    for ep in upcloud_managed_object_storage.main.endpoint :
    "https://${ep.domain_name}" if ep.type == "public"
  ][0]
}

output "s3_region" {
  description = "Object storage region"
  value       = var.objstore_region
}

output "s3_access_key" {
  description = "S3 access key ID"
  value       = upcloud_managed_object_storage_user_access_key.gitlab.access_key_id
}

output "s3_secret_key" {
  description = "S3 secret access key"
  value       = upcloud_managed_object_storage_user_access_key.gitlab.secret_access_key
  sensitive   = true
}
