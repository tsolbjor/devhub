# ─── EKS Add-ons ──────────────────────────────────────────────────────
#
# EKS ships no in-tree storage provisioner since 1.23, so without the EBS CSI
# driver every PersistentVolumeClaim on the platform (Prometheus, Vault, Gitaly,
# Loki, Grafana, Alertmanager) stays Pending and `deploy.sh --atomic` times out.
# The driver needs its own IRSA role, so it is wired up here rather than left to
# the console.

locals {
  # OIDC issuer hostname+path, used in all IRSA trust policies.
  oidc_url = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")

  # Add-ons managed below. Versions are resolved explicitly (most recent for the
  # cluster's Kubernetes version) so they show up in state and plans instead of
  # drifting behind EKS defaults.
  eks_addons = toset(["aws-ebs-csi-driver", "vpc-cni", "kube-proxy", "coredns"])
}

data "aws_eks_addon_version" "this" {
  for_each = local.eks_addons

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# Reusable trust policy for a namespace/service-account pair.
data "aws_iam_policy_document" "irsa_trust" {
  for_each = {
    ebs_csi            = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
    cluster_autoscaler = "system:serviceaccount:kube-system:cluster-autoscaler"
    cert_manager       = "system:serviceaccount:cert-manager:cert-manager"
    loki               = "system:serviceaccount:monitoring:loki"
    velero             = "system:serviceaccount:velero:velero"
    vault              = "system:serviceaccount:vault:vault"
  }

  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = [each.value]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ─── EBS CSI driver ───────────────────────────────────────────────────

resource "aws_iam_role" "ebs_csi" {
  name_prefix        = "${var.prefix}-ebs-csi-"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["ebs_csi"].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi.name
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags

  depends_on = [aws_eks_node_group.main]
}

# ─── Core networking / DNS add-ons ────────────────────────────────────
# Managed explicitly so upgrades are a reviewable diff instead of a console click.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.this["vpc-cni"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.this["kube-proxy"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.this["coredns"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags

  # CoreDNS runs as a Deployment — it needs nodes before it can become healthy.
  depends_on = [aws_eks_node_group.main]
}

# ─── cluster-autoscaler ───────────────────────────────────────────────

resource "aws_iam_role" "cluster_autoscaler" {
  name_prefix        = "${var.prefix}-cluster-autoscaler-"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["cluster_autoscaler"].json
  tags               = var.tags
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.prefix}-eks"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name_prefix = "${var.prefix}-cluster-autoscaler-"
  role        = aws_iam_role.cluster_autoscaler.id
  policy      = data.aws_iam_policy_document.cluster_autoscaler.json
}
