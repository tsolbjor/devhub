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

output "pg_forgejo_password" {
  description = "PostgreSQL password for forgejo user"
  value       = upcloud_managed_database_user.forgejo.password
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


output "loki_bucket" {
  description = "Object storage bucket for Loki log chunks"
  value       = upcloud_managed_object_storage_bucket.platform["loki"].name
}

output "velero_bucket" {
  description = "Object storage bucket for Velero backups"
  value       = upcloud_managed_object_storage_bucket.platform["velero"].name
}

output "loki_s3_access_key_id" {
  description = "Access key for the loki object-storage user (bucket-scoped)"
  value       = upcloud_managed_object_storage_user_access_key.platform["loki"].access_key_id
  sensitive   = true
}

output "loki_s3_secret_access_key" {
  value     = upcloud_managed_object_storage_user_access_key.platform["loki"].secret_access_key
  sensitive = true
}

output "velero_s3_access_key_id" {
  description = "Access key for the velero object-storage user (bucket-scoped)"
  value       = upcloud_managed_object_storage_user_access_key.platform["velero"].access_key_id
  sensitive   = true
}

output "velero_s3_secret_access_key" {
  value     = upcloud_managed_object_storage_user_access_key.platform["velero"].secret_access_key
  sensitive = true
}
