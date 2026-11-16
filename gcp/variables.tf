variable "project_id" {
  type        = string
  description = "The Google Cloud project (created by hand; gcp/bootstrap prepared it)"
}

variable "project_name" {
  type    = string
  default = "spry"
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Cloud Run, Cloud SQL and Artifact Registry live here"
}

variable "database_tier" {
  type        = string
  default     = "db-f1-micro"
  description = "Smallest shared-core tier (0.6 GB). It does not pause: it bills until stopped."
}

variable "cognito_user_pool_id" {
  type        = string
  description = "Sign-in stays on AWS: the API accepts ID tokens of this Cognito user pool"
}

variable "cognito_client_id" {
  type = string
}
