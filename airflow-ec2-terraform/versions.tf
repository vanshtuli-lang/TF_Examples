terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }

  # Keep state in an encrypted, access-controlled S3 bucket: it holds the
  # generated database password, Fernet key and UI user passwords.
  # backend "s3" {
  #   bucket       = "CHANGE-ME-terraform-state"
  #   key          = "airflow/dev/terraform.tfstate"
  #   encrypt      = true
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}
