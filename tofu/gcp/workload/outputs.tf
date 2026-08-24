output "cluster_name" { value = google_container_cluster.main.name }
output "project_id" { value = var.project_id }
output "region" { value = var.region }
output "external_dns_gsa_email" { value = google_service_account.external_dns.email }
output "cert_manager_gsa_email" { value = google_service_account.cert_manager.email }
output "oidc_issuer_url" { value = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/clusters/${google_container_cluster.main.name}" }
