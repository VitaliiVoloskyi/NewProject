terraform {
  required_version = ">= 1.10"

  # A second HCP Terraform workspace with its own state, next to spry-dev (infra/, AWS). One plan
  # can never break both clouds. Runs reach Google Cloud through Workload Identity Federation
  # (gcp/bootstrap), with no service account key anywhere.
  cloud {
    organization = "ooad-voloskyi"

    workspaces {
      name = "spry-gcp"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Labels are GCP's tags: lowercase keys and values only.
provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project    = var.project_name
    managed-by = "terraform"
  }
}

provider "google-beta" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project    = var.project_name
    managed-by = "terraform"
  }
}
