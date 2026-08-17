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
