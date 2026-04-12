output "cluster_name"           { value = google_container_cluster.main.name }
output "project_id"             { value = var.project_id }
output "region"                 { value = var.region }
output "external_dns_gsa_email" { value = google_service_account.external_dns.email }
