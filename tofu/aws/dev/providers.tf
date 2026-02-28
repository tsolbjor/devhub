terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Authentication: set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
# or configure an AWS profile: export AWS_PROFILE=devhub
provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region for dev environment"
  type        = string
  default     = "eu-west-1"
}
