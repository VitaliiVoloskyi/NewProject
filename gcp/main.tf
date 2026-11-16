# Spry's core on Google Cloud: Firebase Hosting (frontend) -> Cloud Run (FastAPI) -> Cloud SQL
# (PostgreSQL). Sign-in (Cognito), the weekly report and the agenda parser stay on AWS.
# Service choices: docs/adr/0008-google-cloud.md.

# APIs are off by default in a new project. Enabling them here keeps a fresh project
# reproducible. Turning one off on destroy could break things outside this configuration, so
# destroy leaves them on.
resource "google_project_service" "this" {
  for_each = toset([
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "firebasehosting.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "this" {}

data "google_service_account" "api" {
  account_id = "spry-api" # created in gcp/bootstrap
}

# ---- Artifact Registry: the API image ------------------------------------------------------------

resource "google_artifact_registry_repository" "api" {
  repository_id = var.project_name
  format        = "DOCKER"
  location      = var.region
  description   = "Spry API images, tagged with the commit SHA"

  # 0.5 GB is free. One image is ~185 MB compressed, and most of it (Python, dependencies) is
  # layers that later tags share, so the last three fit. Older ones are deleted.
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "keep-last-3"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }
  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"
    condition {
      older_than = "0s"
    }
  }

  depends_on = [google_project_service.this]
}
