output "cluster_name" { value = upcloud_kubernetes_cluster.main.name }
output "cluster_id" { value = upcloud_kubernetes_cluster.main.id }
output "zone" { value = var.zone }
