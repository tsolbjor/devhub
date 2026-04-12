output "cluster_name"              { value = aws_eks_cluster.main.name }
output "aws_region"                { value = var.region }
output "external_dns_irsa_role_arn" { value = aws_iam_role.external_dns_irsa.arn }
