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
