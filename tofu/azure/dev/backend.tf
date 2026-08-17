# Remote state — partial configuration.
# State holds the PostgreSQL admin password, the Entra ID client secret and the
# storage account key. Initialise with:
#
#   tofu init -backend-config=backend.hcl
terraform {
  backend "azurerm" {}
}
