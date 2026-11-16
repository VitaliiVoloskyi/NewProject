# The FastAPI container on Cloud Run: the same image as locally (--target cloudrun), with no
# Lambda adapter. It scales to zero, so an idle month costs nothing.
resource "google_cloud_run_v2_service" "api" {
  name                = "${var.project_name}-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  # Public, because the API checks Cognito ID tokens itself (every route but /api/health).
  # This skips the IAM invoker check without granting anything to allUsers.
  invoker_iam_disabled = true

  template {
    service_account = data.google_service_account.api.email

    scaling {
      min_instance_count = 0
      # db-f1-micro allows about 25 connections; 2 instances x (4 + 4) stays below that.
      max_instance_count = 2
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.main.connection_name]
      }
    }

    containers {
      # A placeholder until the first `make gcp-deploy-backend`, which pushes the real image to
      # Artifact Registry and points the service at it. Terraform then leaves the image alone
      # (lifecycle below), as infra/ does with the Lambda images.
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true # request-based billing: CPU only while serving a request
        startup_cpu_boost = true
      }

      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_url.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "DB_POOL_SIZE"
        value = "4"
      }
      env {
        name  = "DB_MAX_OVERFLOW"
        value = "4"
      }
      env {
        name  = "COGNITO_USER_POOL_ID"
        value = var.cognito_user_pool_id
      }
      env {
        name  = "COGNITO_CLIENT_ID"
        value = var.cognito_client_id
      }
      # The browser calls /api on the Firebase origin (a Hosting rewrite), so CORS is only
      # needed for the run.app URL itself and local development.
      env {
        name  = "CORS_ORIGINS"
        value = join(",", local.app_urls)
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      startup_probe {
        http_get {
          path = "/api/health"
        }
        initial_delay_seconds = 0
        period_seconds        = 5
        timeout_seconds       = 3
        failure_threshold     = 24 # alembic upgrade head runs before uvicorn starts
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [
    google_project_service.this,
    google_secret_manager_secret_iam_member.api_reads_database_url,
    google_secret_manager_secret_version.database_url,
  ]
}
