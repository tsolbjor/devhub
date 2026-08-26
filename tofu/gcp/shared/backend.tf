# Shared by tofu/<cloud>/dev and tofu/<cloud>/prod — both link to this file,
# because both had a byte-identical copy of it. Anything that must differ per
# environment belongs in main.tf or variables-deployment.tf, which stay separate.
#
# Remote state — partial configuration.
# State holds the Cloud SQL admin password and the Memorystore AUTH string.
# Initialise with:
#
#   tofu init -backend-config=backend.hcl
terraform {
  backend "gcs" {}
}
