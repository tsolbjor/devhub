# Shared by tofu/<cloud>/dev and tofu/<cloud>/prod — both link to this file,
# because both had a byte-identical copy of it. Anything that must differ per
# environment belongs in main.tf or variables-deployment.tf, which stay separate.
#
# Remote state — partial configuration.
# UpCloud has no native OpenTofu backend; its Managed Object Storage is
# S3-compatible, so the s3 backend is used with checksum/region features that
# only AWS implements switched off. Initialise with:
#
#   tofu init -backend-config=backend.hcl
#
# Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY set to the
# object storage user's access key.
terraform {
  backend "s3" {}
}
