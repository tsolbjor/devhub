# Shared by tofu/<cloud>/dev and tofu/<cloud>/prod — both link to this file,
# because both had a byte-identical copy of it. Anything that must differ per
# environment belongs in main.tf or variables-deployment.tf, which stay separate.
#
# Remote state — partial configuration.
# State holds RDS/PostgreSQL passwords, the Cognito client secret and Redis AUTH
# tokens, so it must never live on a laptop. Initialise with:
#
#   tofu init -backend-config=backend.hcl
#
# Copy backend.hcl.example to backend.hcl and fill it in (backend.hcl is gitignored).
terraform {
  backend "s3" {}
}
