# Everything the Makefile, the infra scripts and the frontend build read, with
# `terraform -chdir=infra output -raw <name>` (tf_output in infra/common.sh).

# ------------------------------------------------------------------------ Auth
output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "cognito_domain" {
  description = "Cognito domain of the managed login page and the OAuth endpoints"
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}

output "cognito_issuer" {
  description = "Issuer of the tokens; the backend checks it"
  value       = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

output "cognito_google_enabled" {
  value = tostring(local.google_enabled)
}

output "app_urls" {
  description = "Origins Cognito redirects to and the parser accepts, comma-separated"
  value       = join(",", var.app_urls)
}

# --------------------------------------------------------------------- Reports
output "reports_bucket" {
  value = aws_s3_bucket.reports.bucket
}

output "report_queue_url" {
  description = "Where make report-now sends its requests"
  value       = aws_sqs_queue.requests.url
}

output "report_dlq_url" {
  value = aws_sqs_queue.requests_dlq.url
}

output "report_builder_function" {
  value = aws_lambda_function.builder.function_name
}

output "report_mailer_function" {
  value = aws_lambda_function.mailer.function_name
}

output "report_sender" {
  value = local.sender
}

output "report_schedule" {
  value = "${aws_scheduler_schedule.weekly.schedule_expression} (${aws_scheduler_schedule.weekly.schedule_expression_timezone})"
}

output "dkim_records" {
  description = "CNAME records to add at the DNS provider of report_sender_domain"
  value = join(" | ", [
    for t in try(aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens, []) :
    "${t}._domainkey.${var.report_sender_domain} CNAME ${t}.dkim.amazonses.com"
  ])
}

# ---------------------------------------------------------------------- Parser
output "parser_url" {
  description = "The parser's function URL without the trailing slash; the frontend posts to it"
  value       = trimsuffix(aws_lambda_function_url.parser.function_url, "/")
}

output "parser_function" {
  value = aws_lambda_function.parser.function_name
}

output "parser_model" {
  value = var.parser_model
}

output "budget_email" {
  value = var.budget_email
}
