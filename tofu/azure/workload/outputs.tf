output "cluster_name" { value = azurerm_kubernetes_cluster.main.name }
output "resource_group_name" { value = azurerm_resource_group.main.name }
output "location" { value = azurerm_resource_group.main.location }
output "external_dns_identity_client_id" { value = azurerm_user_assigned_identity.external_dns.client_id }
output "dns_zone_resource_group" { value = data.azurerm_dns_zone.main.resource_group_name }
output "oidc_issuer_url" { value = azurerm_kubernetes_cluster.main.oidc_issuer_url }
