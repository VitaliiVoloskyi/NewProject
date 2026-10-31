# Cognito user pool: sign-in with email and password (self sign-up, email verification code) or
# Google, both on Cognito's managed login page. A public app client for the SPA (authorization
# code + PKCE), a Cognito domain with managed login v2, and Google as an identity provider that
# exists only when google_client_id is set. Was infra/auth.yaml (Lab 4).

locals {
  google_enabled = var.google_client_id != ""
}

resource "aws_cognito_user_pool" "main" {
  name = "${var.project_name}-users"
  # Managed login needs Essentials (free up to 10,000 monthly active users).
  user_pool_tier = "ESSENTIALS"

  # Self sign-up: anyone can create an account on the managed login page.
  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  # Users sign in with their email; Cognito emails a code to verify it.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # A new email (profile page) takes effect only after its code is entered; until then the user
  # keeps signing in with, and recovering the password through, the old one.
  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  username_configuration {
    case_sensitive = false
  }

  # Changing the schema forces a new user pool, which deletes every account. Never edit it.
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = "0"
      max_length = "2048"
    }
  }

  # Mirrored by the profile page's password form (frontend/src/pages/profile-page.tsx).
  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_numbers                  = true
    require_uppercase                = false
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Cognito's own sender: no SES setup, limited to about 50 emails a day.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Your Meetings verification code"
    email_message        = "Your Meetings verification code is {####}"
  }

  # Deleting the pool deletes every account in it. CloudFormation had DeletionPolicy: Retain;
  # here a destroy or a replacing change fails the plan instead.
  lifecycle {
    prevent_destroy = true
  }
}

# Hosted domain for the OAuth endpoints and the managed login page. Prefixes are global.
resource "aws_cognito_user_pool_domain" "main" {
  user_pool_id          = aws_cognito_user_pool.main.id
  domain                = "${var.project_name}-${local.account_id}"
  managed_login_version = 2
}

# Without a branding style, a version 2 domain has no sign-in page to show.
resource "aws_cognito_managed_login_branding" "main" {
  user_pool_id                = aws_cognito_user_pool.main.id
  client_id                   = aws_cognito_user_pool_client.web.id
  use_cognito_provided_values = true
}

resource "aws_cognito_identity_provider" "google" {
  count = local.google_enabled ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  # Cognito fills in the endpoint keys itself; they are written out so the plan stays empty.
  provider_details = {
    client_id                     = var.google_client_id
    client_secret                 = var.google_client_secret
    authorize_scopes              = "openid email profile"
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  attribute_mapping = {
    email          = "email"
    email_verified = "email_verified"
    name           = "name"
    username       = "sub"
  }
}

# Public client (no secret): a browser cannot keep one, so the code flow is protected with PKCE
# instead (react-oidc-context does it). generate_secret is left out on purpose: no secret is the
# default, and the attribute forces a new client (new ID, every session ends) even when set to false
# on an imported client.
resource "aws_cognito_user_pool_client" "web" {
  user_pool_id                  = aws_cognito_user_pool.main.id
  name                          = "${var.project_name}-web"
  explicit_auth_flows           = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # A reference, not a literal "Google": the client waits for the provider to exist.
  supported_identity_providers = concat(["COGNITO"], aws_cognito_identity_provider.google[*].provider_name)

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  # aws.cognito.signin.user.admin lets the profile page change the user's own name, email and
  # password with the access token.
  allowed_oauth_scopes = ["openid", "email", "profile", "aws.cognito.signin.user.admin"]

  # Must match the app's URLs exactly, trailing slash included.
  callback_urls = [for url in var.app_urls : "${url}/auth/callback"]
  logout_urls   = [for url in var.app_urls : "${url}/"]
}
