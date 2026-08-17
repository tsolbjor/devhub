# ─── Platform service storage and keys ────────────────────────────────
#
# Backing resources for platform components that must not keep state on a local
# PVC: Loki (log storage), Velero (cluster backups), Vault (KMS auto-unseal).

# ─── Loki object storage ──────────────────────────────────────────────
# Loki on a single 10Gi PVC loses history on every pod recycle. S3 chunks +
# IRSA gives durable, keyless log storage.

resource "aws_s3_bucket" "loki" {
  bucket        = "${var.prefix}-loki"
  force_destroy = !var.enable_deletion_protection
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    id     = "expire-chunks"
    status = "Enabled"
    filter {}

    expiration {
      days = var.log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_iam_role" "loki_irsa" {
  name_prefix        = "${var.prefix}-loki-irsa-"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["loki"].json
  tags               = var.tags
}

data "aws_iam_policy_document" "loki_s3" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.loki.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.loki.arn}/*"]
  }
}

resource "aws_iam_role_policy" "loki_s3" {
  name_prefix = "${var.prefix}-loki-s3-"
  role        = aws_iam_role.loki_irsa.id
  policy      = data.aws_iam_policy_document.loki_s3.json
}

# ─── Velero backup storage ────────────────────────────────────────────
# Cluster-object and PV backups. Versioned + lifecycle-expired.

resource "aws_s3_bucket" "velero" {
  bucket        = "${var.prefix}-velero"
  force_destroy = !var.enable_deletion_protection
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id

  rule {
    id     = "expire-backups"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.backup_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_iam_role" "velero_irsa" {
  name_prefix        = "${var.prefix}-velero-irsa-"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["velero"].json
  tags               = var.tags
}

data "aws_iam_policy_document" "velero" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:CreateSnapshot",
      "ec2:DeleteSnapshot",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.velero.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.velero.arn]
  }
}

resource "aws_iam_role_policy" "velero" {
  name_prefix = "${var.prefix}-velero-"
  role        = aws_iam_role.velero_irsa.id
  policy      = data.aws_iam_policy_document.velero.json
}

# ─── Vault auto-unseal KMS key ────────────────────────────────────────
# With KMS auto-unseal, unseal shares never need to be stored anywhere — Vault
# unseals itself on restart. This replaces keeping unseal keys in a K8s secret.

resource "aws_kms_key" "vault_unseal" {
  description             = "${var.prefix} Vault auto-unseal"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.prefix}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

resource "aws_iam_role" "vault_kms_irsa" {
  name_prefix        = "${var.prefix}-vault-kms-"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["vault"].json
  tags               = var.tags
}

data "aws_iam_policy_document" "vault_kms" {
  statement {
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.vault_unseal.arn]
  }
}

resource "aws_iam_role_policy" "vault_kms" {
  name_prefix = "${var.prefix}-vault-kms-"
  role        = aws_iam_role.vault_kms_irsa.id
  policy      = data.aws_iam_policy_document.vault_kms.json
}
