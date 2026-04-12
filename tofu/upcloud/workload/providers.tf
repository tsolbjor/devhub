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
  # Set via environment variables: UPCLOUD_USERNAME, UPCLOUD_PASSWORD
}
