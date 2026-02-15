terraform {
  required_version = ">= 1.0"
  
  required_providers {
    upcloud = {
      source  = "UpCloudLtd/upcloud"
      version = "~> 5.0"
    }
  }
}

provider "upcloud" {
  # Username and password can be set via environment variables:
  # UPCLOUD_USERNAME and UPCLOUD_PASSWORD
  # Or uncomment and set directly (not recommended for production)
  # username = var.upcloud_username
  # password = var.upcloud_password
}
