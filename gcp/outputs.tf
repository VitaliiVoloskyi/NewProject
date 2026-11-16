output "app_urls" {
  description = "Add these to app_urls in infra/terraform.tfvars, so Cognito sends users back here"
  value       = local.site_urls
}

output "hosting_site" {
  value = google_firebase_hosting_site.app.site_id
}

output "api_service" {
  value = google_cloud_run_v2_service.api.name
}

output "api_url" {
  value = google_cloud_run_v2_service.api.uri
}

output "image_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.api.repository_id}"
}

output "database_instance" {
  value = google_sql_database_instance.main.name
}

output "database_connection_name" {
  value = google_sql_database_instance.main.connection_name
}
