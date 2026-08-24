output "cluster_name" { value = aws_eks_cluster.main.name }
output "aws_region" { value = var.region }
output "external_dns_irsa_role_arn" { value = aws_iam_role.external_dns_irsa.arn }
output "cert_manager_role_arn" { value = aws_iam_role.cert_manager_irsa.arn }
output "oidc_issuer_url" { value = aws_eks_cluster.main.identity[0].oidc[0].issuer }
