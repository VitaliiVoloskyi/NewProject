# The static frontend on Firebase Hosting: CDN, HTTPS and a certificate included, free up to 10 GB
# stored and 360 MB a day out. The files and the /api/** rewrite to Cloud Run are deployed by
# `make gcp-deploy-frontend` (firebase deploy), which makes one origin and no CORS, as CloudFront
# did on AWS.
resource "google_firebase_hosting_site" "app" {
  provider = google-beta
  site_id  = "${var.project_id}-app"

  depends_on = [google_project_service.this]
}

locals {
  site_urls = [
    "https://${google_firebase_hosting_site.app.site_id}.web.app",
    "https://${google_firebase_hosting_site.app.site_id}.firebaseapp.com",
  ]
  app_urls = concat(local.site_urls, ["http://localhost:5173", "http://localhost:3000"])
}
