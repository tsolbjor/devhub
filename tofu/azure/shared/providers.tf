# Shared by tofu/<cloud>/dev and tofu/<cloud>/prod — both link to this file,
# because both had a byte-identical copy of it. Anything that must differ per
# environment belongs in main.tf or variables-deployment.tf, which stay separate.
#
terraform {
  required_version = ">= 1.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    # Drives the two-year rotation of the Entra IdP client secret.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  features {}

  # The storage account has shared_access_key_enabled = false, and after
  # creating it the provider polls the *blob data plane* to confirm the service
  # is up. Without this flag that poll signs with an account key, which the
  # account refuses — "403 Key based authentication is not permitted on this
  # storage account" — and the account resource errors out mid-apply, taking
  # its containers and role assignments with it. With it, the poll authenticates
  # as the identity running tofu (see azurerm_role_assignment.tofu_storage_data).
  storage_use_azuread = true

  # Credentials via environment variables:
  #   ARM_SUBSCRIPTION_ID, ARM_TENANT_ID, ARM_CLIENT_ID, ARM_CLIENT_SECRET
  # Or: az login (uses your Azure CLI session)
}
