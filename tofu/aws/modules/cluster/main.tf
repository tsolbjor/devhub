# ─── VPC ──────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = "${var.prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.prefix}-igw" })
}

# Public subnets (one per AZ) — for NAT gateways and load balancers
resource "aws_subnet" "public" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                                      = "${var.prefix}-public-${count.index + 1}"
    "kubernetes.io/cluster/${var.prefix}-eks" = "shared"
    "kubernetes.io/role/elb"                  = "1"
  })
}

# Private subnets (one per AZ) — for EKS nodes, RDS, ElastiCache
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.availability_zones))
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name                                      = "${var.prefix}-private-${count.index + 1}"
    "kubernetes.io/cluster/${var.prefix}-eks" = "shared"
    "kubernetes.io/role/internal-elb"         = "1"
  })
}

# NAT Gateways — one per AZ when nat_gateway_per_az is true (prod HA), otherwise a single
# shared gateway in the first public subnet (cheaper, but an AZ outage takes egress down).
locals {
  nat_gateway_count = var.nat_gateway_per_az ? length(var.availability_zones) : 1
}

resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.prefix}-nat-eip-${count.index + 1}" })
}

resource "aws_nat_gateway" "main" {
  count         = local.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.prefix}-nat-${count.index + 1}" })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ so each AZ can use its own NAT gateway.
resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[var.nat_gateway_per_az ? count.index : 0].id
  }

  tags = merge(var.tags, { Name = "${var.prefix}-private-rt-${count.index + 1}" })
}

resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ─── Security Groups ──────────────────────────────────────────────────

resource "aws_security_group" "rds" {
  name_prefix = "${var.prefix}-rds-"
  description = "Allow PostgreSQL access from within VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.prefix}-rds-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.prefix}-redis-"
  description = "Allow Redis access from within VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Redis from VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.prefix}-redis-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# ─── EKS Cluster ──────────────────────────────────────────────────────

resource "aws_iam_role" "eks_cluster" {
  name_prefix = "${var.prefix}-eks-cluster-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# KMS key for envelope-encrypting Kubernetes Secrets in etcd.
resource "aws_kms_key" "eks_secrets" {
  description             = "${var.prefix} EKS secret envelope encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.prefix}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

resource "aws_eks_cluster" "main" {
  name     = "${var.prefix}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_private_access = true

    # Public endpoint is only enabled when an explicit allow-list is supplied.
    # api_allowed_cidrs = [] means the API server is reachable from inside the VPC only
    # (use a bastion, VPN, or SSM port-forward).
    endpoint_public_access = length(var.api_allowed_cidrs) > 0
    public_access_cidrs    = length(var.api_allowed_cidrs) > 0 ? var.api_allowed_cidrs : null
  }

  # Control-plane audit trail — required to investigate anything after the fact.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
    resources = ["secrets"]
  }

  # Enable OIDC issuer for IRSA (IAM Roles for Service Accounts)
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# OIDC provider — required for IRSA (IAM Roles for Service Accounts)
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = var.tags
}

# EKS Node Group

resource "aws_iam_role" "eks_nodes" {
  name_prefix = "${var.prefix}-eks-nodes-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.prefix}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id

  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_count
    max_size     = var.node_max_count
    min_size     = var.node_min_count
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role = "platform"
  }

  # Tags consumed by cluster-autoscaler auto-discovery.
  tags = merge(var.tags, {
    "k8s.io/cluster-autoscaler/enabled"           = "true"
    "k8s.io/cluster-autoscaler/${var.prefix}-eks" = "owned"
  })

  lifecycle {
    # desired_size is owned by cluster-autoscaler once it is running.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]
}

# Dedicated, tainted node group for Woodpecker CI jobs. Build workloads never share
# nodes with Vault/Keycloak/PostgreSQL, so a container escape in a CI job does not
# hand over the platform's secrets. Scales from zero.
resource "aws_eks_node_group" "ci" {
  count = var.ci_node_max_count > 0 ? 1 : 0

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.prefix}-ci"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id

  instance_types = [var.ci_node_instance_type]
  capacity_type  = var.ci_node_capacity_type

  scaling_config {
    desired_size = var.ci_node_min_count
    max_size     = var.ci_node_max_count
    min_size     = var.ci_node_min_count
  }

  labels = {
    role = "ci"
  }

  taint {
    key    = "workload"
    value  = "ci"
    effect = "NO_SCHEDULE"
  }

  tags = merge(var.tags, {
    "k8s.io/cluster-autoscaler/enabled"           = "true"
    "k8s.io/cluster-autoscaler/${var.prefix}-eks" = "owned"
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]
}

# ─── RDS PostgreSQL ────────────────────────────────────────────────────
#
# NOTE: RDS doesn't support Terraform-managed local user creation.
#       Create users post-provision via psql:
#       kubectl run pg-init --rm -it --image=postgres:16 -- psql -h <rds_endpoint> -U pgadmin

resource "aws_db_subnet_group" "main" {
  name_prefix = "${var.prefix}-pg-"
  subnet_ids  = aws_subnet.private[*].id

  tags = merge(var.tags, { Name = "${var.prefix}-pg-subnet-group" })
}

resource "random_password" "pg_admin" {
  length  = 32
  special = false
}

resource "random_password" "pg_keycloak" {
  length  = 32
  special = false
}

resource "random_password" "pg_forgejo" {
  length  = 32
  special = false
}

resource "aws_db_instance" "main" {
  identifier        = "${var.prefix}-postgresql"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = var.rds_instance_class
  allocated_storage = var.rds_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "postgres"
  username = "pgadmin"
  password = random_password.pg_admin.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = var.rds_multi_az
  deletion_protection = var.enable_deletion_protection
  skip_final_snapshot = !var.enable_deletion_protection

  # Point-in-time recovery + a maintenance window that does not overlap the backup window.
  backup_retention_period = var.rds_backup_retention_days
  backup_window           = "01:00-02:00"
  maintenance_window      = "sun:03:00-sun:04:00"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade      = true
  performance_insights_enabled    = var.rds_performance_insights
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = var.tags
}

# ─── ElastiCache Redis ────────────────────────────────────────────────
#
# TLS in transit + AUTH token, on top of VPC/security-group isolation. Clients
# connect with rediss:// and the token from a K8s secret.

resource "random_password" "redis_auth" {
  length  = 64
  special = false
}

resource "aws_elasticache_subnet_group" "main" {
  # ElastiCache subnet groups take a fixed name (no name_prefix support).
  name       = "${var.prefix}-redis"
  subnet_ids = aws_subnet.private[*].id

  tags = var.tags
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "${var.prefix}-redis"
  description                = "Redis for DevHub ${var.prefix}"
  node_type                  = var.redis_node_type
  num_cache_clusters         = var.redis_num_cache_clusters
  automatic_failover_enabled = var.redis_automatic_failover
  engine_version             = "7.0"
  port                       = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result
  auth_token_update_strategy = "ROTATE"

  snapshot_retention_limit = var.redis_snapshot_retention_days
  maintenance_window       = "sun:04:00-sun:05:00"

  tags = var.tags
}

# NOTE: Forgejo keeps repositories, LFS objects, packages and container registry
# blobs on its PersistentVolume. Forgejo supports local disk or S3-compatible
# storage only — Azure Blob and GCS have no S3 API — so rather than run two
# storage models, every cloud uses the volume, and Velero backs it up alongside
# the managed PostgreSQL PITR.

# ─── Cognito User Pool (IdP for Keycloak) ────────────────────────────
#
# Keycloak federates with Cognito — users authenticate via "Sign in with AWS"
# through Keycloak, which remains the single OIDC issuer for all services.
#
# Three Cognito groups map to Keycloak groups via setup-keycloak.sh IdP mappers.
# The token's `cognito:groups` claim is an array — assign users to Cognito groups
# in the AWS console or via `aws cognito-idp admin-add-user-to-group`.
#
# NOTE: var.cognito_domain_prefix must be globally unique across ALL AWS accounts.

resource "aws_cognito_user_pool" "main" {
  name = "${var.prefix}-devhub"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = true # admins create users; disable for self-signup
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = false
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  schema {
    attribute_data_type = "String"
    name                = "email"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 254
    }
  }

  tags = var.tags
}

resource "aws_cognito_user_pool_client" "keycloak_idp" {
  name         = "${var.prefix}-keycloak-idp"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = true
  prevent_user_existence_errors        = "ENABLED"
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  # Placeholder redirect URI — updated by setup-keycloak.sh via AWS CLI
  callback_urls = ["https://placeholder.invalid/realms/devops/broker/aws-cognito/endpoint"]

  refresh_token_validity = 30
  access_token_validity  = 60
  id_token_validity      = 60

  token_validity_units {
    refresh_token = "days"
    access_token  = "minutes"
    id_token      = "minutes"
  }
}

resource "aws_cognito_user_pool_domain" "main" {
  # Must be globally unique. Customize var.cognito_domain_prefix to avoid conflicts.
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.main.id
}

# Cognito groups — assign users to these groups to grant platform access.
# The token's `cognito:groups` claim maps to Keycloak groups via IdP mappers.
resource "aws_cognito_user_group" "devops_admins" {
  name         = "devops-admins"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Full access to DevOps platform administration"
}

resource "aws_cognito_user_group" "developers" {
  name         = "developers"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Developer access to DevOps platform services"
}

resource "aws_cognito_user_group" "viewers" {
  name         = "viewers"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Read-only access to DevOps platform services"
}

# ─── External-DNS IRSA ───────────────────────────────────────────────
# Allows external-dns to manage Route53 records for the cluster's domain.
# The K8s service account "external-dns/external-dns" assumes this role via IRSA.

data "aws_route53_zone" "main" {
  name         = var.domain
  private_zone = false
}

data "aws_iam_policy_document" "external_dns_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-dns:external-dns"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_dns_irsa" {
  name_prefix        = "${var.prefix}-external-dns-irsa-"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume_role.json

  tags = var.tags
}

data "aws_iam_policy_document" "external_dns_route53" {
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.main.zone_id}"]
  }

  statement {
    effect    = "Allow"
    actions   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_dns_route53" {
  name_prefix = "${var.prefix}-external-dns-route53-"
  role        = aws_iam_role.external_dns_irsa.id
  policy      = data.aws_iam_policy_document.external_dns_route53.json
}
