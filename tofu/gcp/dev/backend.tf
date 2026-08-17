# Remote state — partial configuration.
# State holds the Cloud SQL admin password and the Memorystore AUTH string.
# Initialise with:
#
#   tofu init -backend-config=backend.hcl
terraform {
  backend "gcs" {}
}
