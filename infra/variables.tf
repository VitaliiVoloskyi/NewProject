# Non-secret values are in terraform.tfvars. Secrets, and personal addresses this public
# repository should not carry, are variables of the HCP Terraform workspace.

variable "project_name" {
  type        = string
  description = "Prefix of every resource name, and the PROJECT_NAME tag"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "project_name must be lowercase letters, digits and dashes, starting with a letter."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# ------------------------------------------------------------------ Auth (Lab 4)

variable "app_urls" {
  type        = list(string)
  description = <<-EOT
    Origins the frontend runs on (no trailing slash): the local dev servers, CloudFront and the
    custom domain. Cognito redirects back to <origin>/auth/callback after sign-in and to
    <origin>/ after sign-out, and the agenda parser accepts browser calls from them.
  EOT
}

variable "google_client_id" {
  type        = string
  default     = ""
  description = "Google OAuth client id. Empty: Google sign-in is disabled."
}

variable "google_client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Google OAuth client secret. Set it in the workspace, never in a file."
}

# --------------------------------------------------------------- Reports (Lab 5)

variable "report_recipients" {
  type        = string
  description = <<-EOT
    Comma-separated addresses the weekly report goes to. In the SES sandbox each must be a
    verified identity: make verify-recipients sends the verification emails.
  EOT

  validation {
    condition     = can(regex(".+@.+", var.report_recipients))
    error_message = "report_recipients must contain at least one email address."
  }
}

variable "report_sender_domain" {
  type        = string
  default     = ""
  description = "Domain to send from as reports@<domain>, verified with DKIM. Empty: the first recipient sends to itself."
}

variable "hosted_zone_id" {
  type        = string
  default     = ""
  description = "Route 53 zone of report_sender_domain. If set, the DKIM records are created there."
}

variable "report_schedule" {
  type        = string
  default     = "cron(0 7 ? * MON *)"
  description = "When the report is built. Use rate(5 minutes) to test, then set it back."
}

variable "report_timezone" {
  type        = string
  default     = "Europe/Kyiv"
  description = "The schedule's time zone, and where report weeks start and end."
}

variable "report_break_week" {
  type        = string
  default     = ""
  description = "For the DLQ exercise only: the builder fails every request for this week."
}

# ---------------------------------------------------------- Agenda parser (Lab 6)

variable "parser_model" {
  type        = string
  default     = "anthropic.claude-opus-5-5"
  description = "Bedrock model ID. A plain anthropic.* ID uses the Messages API, an inference profile (us.*, global.*) the Converse API."
}

variable "budget_email" {
  type        = string
  default     = ""
  description = "Where the monthly budget alarm goes. Empty: no budget."
}

variable "budget_limit_usd" {
  type        = number
  default     = 5
  description = "Monthly AWS cost (the whole account) that triggers the alarm."
}

# ------------------------------------------------------------------- Shared

variable "initial_image_tag" {
  type        = string
  description = <<-EOT
    Backend image tag (built at its `app` target) that the builder and the parser start with when
    Terraform creates them. After that the application road ships the code (make deploy-backend,
    in CI), and Terraform ignores the image.
  EOT
}
