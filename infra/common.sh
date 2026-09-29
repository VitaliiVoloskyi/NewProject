# Shared setup for the infra scripts. Settings come from .env via make (or from the
# environment in GitHub Actions). Credentials never come from .env: locally the AWS CLI uses
# your `aws configure` profile (optionally AWS_PROFILE), in CI the OIDC role's temporary keys.
: "${AWS_REGION:?Set AWS_REGION in .env}"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""
[ -n "${AWS_PROFILE:-}" ] || unset AWS_PROFILE

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "The AWS CLI has no working credentials. Run 'aws configure' (or 'aws sso login')," >&2
  echo "or set AWS_PROFILE in .env to the profile you want to use." >&2
  exit 1
fi

PROJECT_NAME="${PROJECT_NAME:-meetings}"
ECR_STACK="$PROJECT_NAME-ecr"
BACKEND_STACK="$PROJECT_NAME-backend"
FRONTEND_STACK="$PROJECT_NAME-frontend"
AUTH_STACK="$PROJECT_NAME-auth"
CI_STACK="$PROJECT_NAME-github-oidc"
# CloudFront only accepts certificates from us-east-1; the load balancer needs one in its own
# region. Two small stacks, even when both regions are us-east-1.
APP_CERT_STACK="$PROJECT_NAME-cert-app"
APP_CERT_REGION="us-east-1"
API_CERT_STACK="$PROJECT_NAME-cert-api"

APP_DOMAIN="${APP_DOMAIN:-}"
API_DOMAIN="${API_DOMAIN:-}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"

# Every resource is tagged PROJECT_NAME=<PROJECT_NAME>: explicitly in the templates, and via
# the stack tags (which also cover resources CloudFormation creates implicitly).
TAG_KEY="PROJECT_NAME"
STACK_TAGS=("$TAG_KEY=$PROJECT_NAME")

# output STACK KEY [REGION]: prints one CloudFormation stack output (empty if absent).
output() {
  local value
  value="$(aws cloudformation describe-stacks --stack-name "$1" --region "${3:-$AWS_REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null || true)"
  [ "$value" = "None" ] && value=""
  echo "$value"
}

# parameter STACK KEY [REGION]: prints the current value of one stack parameter.
parameter() {
  aws cloudformation describe-stacks --stack-name "$1" --region "${3:-$AWS_REGION}" \
    --query "Stacks[0].Parameters[?ParameterKey=='$2'].ParameterValue" --output text 2>/dev/null || true
}

# stack_exists STACK [REGION]
stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" --region "${2:-$AWS_REGION}" >/dev/null 2>&1
}

# ensure_certificate STACK REGION DOMAIN: requests (or keeps) an ACM certificate for DOMAIN
# and prints its ARN on the last line. With HOSTED_ZONE_ID the validation CNAME is created in
# Route 53; otherwise the record to add at your DNS provider is printed, and this waits
# (the stack only finishes once ACM sees the record).
ensure_certificate() {
  local stack="$1" region="$2" domain="$3" current arn record shown="" deploy_pid
  if stack_exists "$stack" "$region"; then
    current="$(parameter "$stack" DomainName "$region")"
    if [ "$current" != "$domain" ]; then
      echo "    $stack is for $current; deleting it to request one for $domain" >&2
      aws cloudformation delete-stack --stack-name "$stack" --region "$region"
      aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$region"
    fi
  fi

  # In the background: without Route 53 the stack waits for the validation record, and that
  # record is only known once the certificate has been requested.
  aws cloudformation deploy \
    --stack-name "$stack" \
    --region "$region" \
    --template-file infra/certificate.yaml \
    --parameter-overrides "ProjectName=$PROJECT_NAME" "DomainName=$domain" "HostedZoneId=$HOSTED_ZONE_ID" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset >/dev/null &
  deploy_pid=$!

  while kill -0 "$deploy_pid" 2>/dev/null; do
    if [ -z "$shown" ]; then
      arn="$(aws cloudformation describe-stack-resource --stack-name "$stack" --region "$region" \
        --logical-resource-id Certificate --query StackResourceDetail.PhysicalResourceId \
        --output text 2>/dev/null || true)"
      if [[ "$arn" == arn:* ]]; then
        record="$(aws acm describe-certificate --certificate-arn "$arn" --region "$region" \
          --query "Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Type,Value]" \
          --output text 2>/dev/null || true)"
        if [ -n "$record" ] && [ "$record" != "None" ]; then
          read -r rec_name rec_type rec_value <<<"$record"
          if [ -n "$HOSTED_ZONE_ID" ]; then
            echo "    Route 53 validation record is created automatically; waiting for ACM..." >&2
          else
            echo "    Add this DNS record at your DNS provider (proves you own $domain):" >&2
            echo "      $rec_type  $rec_name  ->  $rec_value" >&2
            echo "    Waiting until ACM sees it (usually 2-10 minutes)..." >&2
          fi
          shown=1
        fi
      fi
    fi
    sleep 10
  done
  wait "$deploy_pid"
  output "$stack" CertificateArn "$region"
}

# frontend_origins: the addresses the frontend runs on (CloudFront, custom domain).
frontend_origins() {
  local origins="" url
  if stack_exists "$FRONTEND_STACK"; then
    for url in "$(output "$FRONTEND_STACK" AppUrl)" "$(output "$FRONTEND_STACK" CustomDomainUrl)"; do
      [ -n "$url" ] && origins="${origins:+$origins,}$url"
    done
  fi
  if [ -n "$APP_DOMAIN" ] && [[ ",$origins," != *",https://$APP_DOMAIN,"* ]]; then
    origins="${origins:+$origins,}https://$APP_DOMAIN"
  fi
  echo "$origins"
}

# cors_origins: the sites allowed to call the API: the frontend's addresses plus
# CORS_ORIGINS_AWS.
cors_origins() {
  local origins="" origin
  # Read line by line rather than word-splitting, so "*" is not expanded into file names.
  while IFS= read -r origin; do
    origin="${origin//[[:space:]]/}"
    [ -n "$origin" ] && origins="${origins:+$origins,}$origin"
  done < <(echo "$(frontend_origins),${CORS_ORIGINS_AWS:-}" | tr ',' '\n')
  echo "${origins:-http://localhost:5173}"
}

# update_backend_cors: points the backend's CORS_ORIGINS at the current frontend addresses
# (a rolling ECS deployment, so only when they changed). Other parameters keep their values.
update_backend_cors() {
  local origins
  origins="$(cors_origins)"
  if [ "$(parameter "$BACKEND_STACK" CorsOrigins)" = "$origins" ]; then
    echo "    CORS origins unchanged: $origins"
    return 0
  fi
  echo "    CORS origins: $origins"
  aws cloudformation deploy \
    --stack-name "$BACKEND_STACK" \
    --template-file infra/backend.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides "CorsOrigins=$origins" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
}

# app_urls: the origins Cognito may redirect back to after Google sign-in (<origin>/login).
app_urls() {
  local urls="http://localhost:5173,http://localhost:3000" origins
  origins="$(frontend_origins)"
  echo "$urls${origins:+,$origins}"
}

# update_auth_urls: points the Cognito app client's redirect URLs at the current frontend
# addresses. Every other auth parameter (including the Google client) keeps its value.
update_auth_urls() {
  stack_exists "$AUTH_STACK" || return 0
  local urls
  urls="$(app_urls)"
  if [ "$(parameter "$AUTH_STACK" AppUrls)" = "$urls" ]; then
    return 0
  fi
  echo "    App URLs: $urls"
  aws cloudformation deploy \
    --stack-name "$AUTH_STACK" \
    --template-file infra/auth.yaml \
    --parameter-overrides "AppUrls=$urls" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
}

# require_auth_stack: exits with a hint when Cognito has not been deployed yet.
require_auth_stack() {
  stack_exists "$AUTH_STACK" || {
    echo "Stack $AUTH_STACK not found; run make deploy-auth first." >&2
    exit 1
  }
}
