# ─── Cluster ─────────────────────────────────────────────────────────

output "cluster_id" {
  value = module.cluster.cluster_id
}

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "zone" {
  value = module.cluster.zone
}

# ─── PostgreSQL ──────────────────────────────────────────────────────

output "pg_host" {
  value = module.cluster.pg_host
}

output "pg_port" {
  value = module.cluster.pg_port
}

output "pg_keycloak_password" {
  value     = module.cluster.pg_keycloak_password
  sensitive = true
}

output "pg_forgejo_password" {
  value     = module.cluster.pg_forgejo_password
  sensitive = true
}

# ─── Valkey ──────────────────────────────────────────────────────────

output "valkey_host" {
  value = module.cluster.valkey_host
}

output "valkey_port" {
  value = module.cluster.valkey_port
}

output "valkey_password" {
  value     = module.cluster.valkey_password
  sensitive = true
}

# ─── Object Storage ─────────────────────────────────────────────────

output "s3_endpoint" {
  value = module.cluster.s3_endpoint
}

output "s3_region" {
  value = module.cluster.s3_region
}
