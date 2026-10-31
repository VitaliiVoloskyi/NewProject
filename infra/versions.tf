terraform {
  required_version = ">= 1.10"

  # State, locking and runs live in HCP Terraform. A pull request gets a plan, a merge to main
  # applies it. The runs reach AWS with dynamic credentials (infra/bootstrap), not stored keys.
  cloud {
    organization = "ooad-voloskyi"

    workspaces {
      name = "spry-dev"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region = var.region

  # Every resource that accepts tags gets PROJECT_NAME (Lab 4's rule) without repeating it.
  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
    }
  }
}
