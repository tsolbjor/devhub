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
    Name                                        = "${var.prefix}-public-${count.index + 1}"
    "kubernetes.io/cluster/${var.prefix}-eks"   = "shared"
    "kubernetes.io/role/elb"                    = "1"
  })
}

# Private subnets (one per AZ) — for EKS nodes, RDS, ElastiCache
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.availability_zones))
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name                                        = "${var.prefix}-private-${count.index + 1}"
    "kubernetes.io/cluster/${var.prefix}-eks"   = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  })
}

# NAT Gateway (single, in first public subnet — use one per AZ for prod HA)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.prefix}-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(var.tags, { Name = "${var.prefix}-nat" })

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

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(var.tags, { Name = "${var.prefix}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
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

resource "aws_eks_cluster" "main" {
  name     = "${var.prefix}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
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

  tags = var.tags

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

resource "random_password" "pg_gitlab" {
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

  tags = var.tags
}

# ─── ElastiCache Redis ────────────────────────────────────────────────
#
# In-VPC Redis with no TLS/auth — security via security group (VPC-only access).
# For production, consider enabling transit_encryption_enabled + auth_token.

resource "aws_elasticache_subnet_group" "main" {
  name_prefix = "${var.prefix}-redis-"
  subnet_ids  = aws_subnet.private[*].id

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

  tags = var.tags
}

# ─── S3 Buckets (GitLab Object Storage) ──────────────────────────────
#
# GitLab supports S3 natively — no shim needed.
# IRSA (IAM Role for Service Accounts) provides keyless access.
# NOTE: S3 bucket names are globally unique. Adjust var.prefix if conflicts arise.

locals {
  s3_bucket_prefix = "${var.prefix}-gitlab"
}

resource "aws_s3_bucket" "gitlab_artifacts" {
  bucket        = "${local.s3_bucket_prefix}-artifacts"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket" "gitlab_uploads" {
  bucket        = "${local.s3_bucket_prefix}-uploads"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket" "gitlab_packages" {
  bucket        = "${local.s3_bucket_prefix}-packages"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket" "gitlab_lfs" {
  bucket        = "${local.s3_bucket_prefix}-lfs"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket" "gitlab_registry" {
  bucket        = "${local.s3_bucket_prefix}-registry"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket" "gitlab_backups" {
  bucket        = "${local.s3_bucket_prefix}-backups"
  force_destroy = true
  tags          = var.tags
}

# Block public access on all GitLab buckets
resource "aws_s3_bucket_public_access_block" "gitlab_artifacts" {
  bucket                  = aws_s3_bucket.gitlab_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "gitlab_uploads" {
  bucket                  = aws_s3_bucket.gitlab_uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "gitlab_packages" {
  bucket                  = aws_s3_bucket.gitlab_packages.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "gitlab_lfs" {
  bucket                  = aws_s3_bucket.gitlab_lfs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "gitlab_registry" {
  bucket                  = aws_s3_bucket.gitlab_registry.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "gitlab_backups" {
  bucket                  = aws_s3_bucket.gitlab_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side encryption for all buckets
resource "aws_s3_bucket_server_side_encryption_configuration" "gitlab_artifacts" {
  bucket = aws_s3_bucket.gitlab_artifacts.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gitlab_uploads" {
  bucket = aws_s3_bucket.gitlab_uploads.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gitlab_packages" {
  bucket = aws_s3_bucket.gitlab_packages.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gitlab_lfs" {
  bucket = aws_s3_bucket.gitlab_lfs.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gitlab_registry" {
  bucket = aws_s3_bucket.gitlab_registry.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gitlab_backups" {
  bucket = aws_s3_bucket.gitlab_backups.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

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

# ─── IRSA for GitLab ─────────────────────────────────────────────────
#
# Allows GitLab pods (webservice, sidekiq) to access S3 without explicit
# AWS credentials. The K8s service account "gitlab" in the "gitlab" namespace
# exchanges its projected OIDC token for temporary AWS credentials.

data "aws_iam_policy_document" "gitlab_assume_role" {
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
      values   = ["system:serviceaccount:gitlab:gitlab"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gitlab_irsa" {
  name_prefix        = "${var.prefix}-gitlab-irsa-"
  assume_role_policy = data.aws_iam_policy_document.gitlab_assume_role.json

  tags = var.tags
}

data "aws_iam_policy_document" "gitlab_s3" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListMultipartUploadParts",
      "s3:AbortMultipartUpload",
    ]
    resources = [
      "${aws_s3_bucket.gitlab_artifacts.arn}/*",
      "${aws_s3_bucket.gitlab_uploads.arn}/*",
      "${aws_s3_bucket.gitlab_packages.arn}/*",
      "${aws_s3_bucket.gitlab_lfs.arn}/*",
      "${aws_s3_bucket.gitlab_registry.arn}/*",
      "${aws_s3_bucket.gitlab_backups.arn}/*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [
      aws_s3_bucket.gitlab_artifacts.arn,
      aws_s3_bucket.gitlab_uploads.arn,
      aws_s3_bucket.gitlab_packages.arn,
      aws_s3_bucket.gitlab_lfs.arn,
      aws_s3_bucket.gitlab_registry.arn,
      aws_s3_bucket.gitlab_backups.arn,
    ]
  }
}

resource "aws_iam_role_policy" "gitlab_s3" {
  name_prefix = "${var.prefix}-gitlab-s3-"
  role        = aws_iam_role.gitlab_irsa.id
  policy      = data.aws_iam_policy_document.gitlab_s3.json
}
