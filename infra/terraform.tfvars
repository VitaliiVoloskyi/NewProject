# Non-secret settings of the dev environment. Secrets and personal addresses are variables of
# the HCP Terraform workspace: google_client_secret (sensitive), report_recipients, budget_email.
project_name = "spry"
region       = "us-east-1"

app_urls = [
  "http://localhost:5173",
  "http://localhost:3000",
  "https://d7qg7pyr3qt78.cloudfront.net",
]

google_client_id = "973101215476-jj7ttgnls5ok504k6ja8vsp6clpr1fv5.apps.googleusercontent.com"
parser_model     = "us.anthropic.claude-opus-4-5-20251101-v1:0"

initial_image_tag = "36fd2ff-app"
