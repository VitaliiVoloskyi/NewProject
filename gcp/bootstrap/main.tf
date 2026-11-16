# Bootstrap: what must exist before HCP Terraform can touch the Google Cloud project at all.
#
#   * the APIs Terraform itself needs (IAM, STS, Service Usage, Firebase)
#   * two service accounts, one per program: spry-terraform (HCP Terraform runs as it) and
#     spry-api (the Cloud Run service runs as it). Neither gets Owner or Editor, and neither has
#     a key: Google's advice is to avoid service account keys whenever possible.
#   * Workload Identity Federation for HCP Terraform. Each run presents an OIDC token signed by
#     app.terraform.io; Google exchanges it for a short-lived token of spry-terraform. The
#     attribute condition admits one workspace of one organization, by their immutable ids
#     (ws-..., org-...), not by names that could be re-registered by someone else.
#   * Firebase on the project (adding Firebase to a project needs more than Firebase Hosting Admin).
#
# Applied once from a laptop with your own Google account (application default credentials), and
# its state stays local (gitignored), exactly like infra/bootstrap for AWS:
#
#   gcloud auth application-default login
#   terraform -chdir=gcp/bootstrap init
#   terraform -chdir=gcp/bootstrap apply -var project_id=... -var tfc_organization_id=org-... \
#     -var tfc_workspace_id=ws-...
#
# Then set the three TFC_GCP_* environment variables it prints in the workspace spry-gcp.

terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "The Google Cloud project, created by hand in the console with billing linked"
}

variable "tfc_organization_id" {
  type        = string
  description = "Immutable id of the HCP Terraform organization (org-...), not its name"
}

variable "tfc_workspace_id" {
  type        = string
  description = "Immutable id of the workspace spry-gcp (ws-...), the only one allowed in"
}

provider "google" {
  project = var.project_id
}

provider "google-beta" {
  project = var.project_id
}

data "google_project" "this" {}

resource "google_project_service" "bootstrap" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "firebase.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

resource "google_firebase_project" "this" {
  provider   = google-beta
  project    = var.project_id
  depends_on = [google_project_service.bootstrap]
}

# ---- service accounts ---------------------------------------------------------------------------

resource "google_service_account" "terraform" {
  account_id   = "spry-terraform"
  display_name = "HCP Terraform (workspace spry-gcp)"
  depends_on   = [google_project_service.bootstrap]
}

resource "google_service_account" "api" {
  account_id   = "spry-api"
  display_name = "Spry API on Cloud Run"
  depends_on   = [google_project_service.bootstrap]
}

# What gcp/*.tf creates, and nothing more. The lab's list, plus Firebase Hosting Admin for the
# hosting site. No Owner, no Editor, no IAM admin on the project: the API's own project role
# (Cloud SQL Client) is granted here instead, so Terraform never needs to edit project IAM.
resource "google_project_iam_member" "terraform" {
  for_each = toset([
    "roles/run.admin",
    "roles/cloudsql.admin",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/firebasehosting.admin",
  ])
  project = var.project_id
  role    = each.value
  member  = google_service_account.terraform.member
}

# Service Account User only on spry-api, not on the project: Terraform may deploy a Cloud Run
# service that runs as spry-api, but cannot act as any other account (the default compute one
# starts with Editor).
resource "google_service_account_iam_member" "terraform_acts_as_api" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.terraform.member
}

# The API connects to Cloud SQL through the Cloud Run connector (Cloud SQL Admin API).
# Its access to the database password is granted on that one secret, in gcp/database.tf.
resource "google_project_iam_member" "api_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.api.member
}

# ---- Workload Identity Federation for HCP Terraform ---------------------------------------------

resource "google_iam_workload_identity_pool" "tfc" {
  workload_identity_pool_id = "hcp-terraform"
  display_name              = "HCP Terraform"
  depends_on                = [google_project_service.bootstrap]
}

resource "google_iam_workload_identity_pool_provider" "tfc" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.tfc.workload_identity_pool_id
  workload_identity_pool_provider_id = "app-terraform-io"
  display_name                       = "app.terraform.io"

  oidc {
    issuer_uri = "https://app.terraform.io"
  }

  attribute_mapping = {
    "google.subject"                      = "assertion.sub"
    "attribute.terraform_organization_id" = "assertion.terraform_organization_id"
    "attribute.terraform_workspace_id"    = "assertion.terraform_workspace_id"
    "attribute.terraform_run_phase"       = "assertion.terraform_run_phase"
  }

  # Tokens of any other organization or workspace are rejected before any role is considered.
  attribute_condition = join(" && ", [
    "assertion.terraform_organization_id == \"${var.tfc_organization_id}\"",
    "assertion.terraform_workspace_id == \"${var.tfc_workspace_id}\"",
  ])
}

resource "google_service_account_iam_member" "tfc_impersonates_terraform" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.tfc.name}/attribute.terraform_workspace_id/${var.tfc_workspace_id}"
}

# ---- what to paste into the workspace ------------------------------------------------------------

output "workspace_env" {
  description = "Environment variables of the HCP Terraform workspace spry-gcp"
  value = {
    TFC_GCP_PROVIDER_AUTH             = "true"
    TFC_GCP_RUN_SERVICE_ACCOUNT_EMAIL = google_service_account.terraform.email
    TFC_GCP_WORKLOAD_PROVIDER_NAME    = google_iam_workload_identity_pool_provider.tfc.name
  }
}

output "api_service_account" {
  value = google_service_account.api.email
}

output "project_number" {
  value = data.google_project.this.number
}
