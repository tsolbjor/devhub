output "cluster_name" { value = upcloud_kubernetes_cluster.main.name }
output "cluster_id" { value = upcloud_kubernetes_cluster.main.id }
output "zone" { value = var.zone }

# No oidc_issuer_url output: the UpCloud provider (upcloud_kubernetes_cluster,
# checked at v5.43.0) exposes no OIDC issuer/JWKS attribute, unlike EKS/AKS/GKE.
# Workload-cluster Vault JWT auth against the cluster's own issuer therefore
# cannot be wired from tofu outputs on UpCloud; sync-tofu-outputs.sh will leave
# OIDC_ISSUER_URL empty for this environment.
# output "oidc_issuer_url" { value = ... }
