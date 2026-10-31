# Shared setup for the infra scripts. Settings come from .env via make (or from repository
# variables in GitHub Actions). Credentials never come from .env: locally the AWS CLI uses your
# `aws configure` profile (optionally AWS_PROFILE), in CI the OIDC role's temporary keys.
: "${AWS_REGION:?Set AWS_REGION in .env}"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""
[ -n "${AWS_PROFILE:-}" ] || unset AWS_PROFILE

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "The AWS CLI has no working credentials. Run 'aws configure' (or 'aws sso login')," >&2
  echo "or set AWS_PROFILE in .env to the profile you want to use." >&2
  exit 1
fi

# APP_NAME is the old name of the setting and still works.
PROJECT_NAME="${PROJECT_NAME:-${APP_NAME:-meetings}}"
ECR_STACK="$PROJECT_NAME-ecr"
BACKEND_STACK="$PROJECT_NAME-backend"
FRONTEND_STACK="$PROJECT_NAME-frontend"
# CloudFront only accepts certificates from us-east-1.
CERT_STACK="$PROJECT_NAME-certificate"
CERT_REGION="us-east-1"
CI_STACK="$PROJECT_NAME-github-oidc"
# Cognito, the weekly report and the agenda parser are Terraform (infra/*.tf), not stacks.
REPORT_BUILDER="$PROJECT_NAME-report-builder"
AGENDA_PARSER="$PROJECT_NAME-agenda-parser"

# Every resource is tagged PROJECT_NAME=<PROJECT_NAME>: explicitly in the templates, via the
# stack tags (which also cover resources CloudFormation creates implicitly), by the AWS
# provider's default_tags in infra/versions.tf, and by the scripts for everything else.
TAG_KEY="PROJECT_NAME"
STACK_TAGS=("$TAG_KEY=$PROJECT_NAME")

# output STACK KEY [REGION]: prints one CloudFormation stack output (empty if absent).
output() {
  aws cloudformation describe-stacks --stack-name "$1" --region "${3:-$AWS_REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

# tf_output NAME: prints one output of the Terraform configuration in infra/, read from its
# state in HCP Terraform. Needs an HCP Terraform token: `terraform login` locally, the
# TF_TOKEN_app_terraform_io secret in CI.
tf_output() {
  if [ ! -d infra/.terraform ]; then
    terraform -chdir=infra init -input=false >/dev/null
  fi
  terraform -chdir=infra output -raw "$1"
}

# function_exists NAME
function_exists() {
  aws lambda get-function --function-name "$1" >/dev/null 2>&1
}

# image_tag: the backend image tag: the git SHA, plus a timestamp when backend/ has uncommitted
# changes (ECR tags are immutable).
image_tag() {
  local tag
  tag="$(git rev-parse --short HEAD)"
  if [ -n "$(git status --porcelain -- backend)" ]; then
    tag="$tag-dirty-$(date +%Y%m%d%H%M%S)"
  fi
  echo "$tag"
}

# stack_exists STACK [REGION]
stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" --region "${2:-$AWS_REGION}" >/dev/null 2>&1
}

# cors_origins: the sites allowed to call the API: the CloudFront address and custom domain
# (once the frontend stack exists) plus CORS_ORIGINS_AWS.
cors_origins() {
  local candidates="" origins="" origin
  if stack_exists "$FRONTEND_STACK"; then
    candidates="$(output "$FRONTEND_STACK" AppUrl),$(output "$FRONTEND_STACK" CustomDomainUrl)"
  fi
  # Read line by line rather than word-splitting, so "*" (allow any origin) is not
  # expanded into file names.
  while IFS= read -r origin; do
    origin="${origin//[[:space:]]/}"
    [ -n "$origin" ] && origins="${origins:+$origins,}$origin"
  done < <(echo "$candidates,${CORS_ORIGINS_AWS:-}" | tr ',' '\n')
  echo "${origins:-http://localhost:5173}"
}

# update_backend_cors: points the backend's CORS_ORIGINS at the current frontend addresses.
# Every other backend parameter keeps its previous value.
update_backend_cors() {
  local origins
  origins="$(cors_origins)"
  echo "    CORS origins: $origins"
  aws cloudformation deploy \
    --stack-name "$BACKEND_STACK" \
    --template-file infra/backend.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides "CorsOrigins=$origins" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
}

# app_urls: the origins the frontend runs on (local dev servers, CloudFront, custom domain).
app_urls() {
  local urls="http://localhost:5173,http://localhost:3000" url
  if stack_exists "$FRONTEND_STACK"; then
    for url in "$(output "$FRONTEND_STACK" AppUrl)" "$(output "$FRONTEND_STACK" CustomDomainUrl)"; do
      [ -n "$url" ] && [ "$url" != "None" ] && urls="$urls,$url"
    done
  fi
  echo "$urls"
}

# check_app_urls: Cognito's redirect URLs and the parser's CORS come from app_urls in
# infra/terraform.tfvars. A script cannot change them (only HCP Terraform applies), so it says
# which origin to add there, in a pull request.
check_app_urls() {
  local known missing="" url
  known=",$(tf_output app_urls),"
  while IFS= read -r url; do
    if [ -n "$url" ] && [[ "$known" != *",$url,"* ]]; then
      missing="${missing:+$missing, }\"$url\""
    fi
  done < <(app_urls | tr ',' '\n')
  if [ -n "$missing" ]; then
    echo "    Sign-in and Paste an agenda do not know $missing yet. Add it to app_urls in"
    echo "    infra/terraform.tfvars and merge the pull request; HCP Terraform applies it."
  else
    echo "    app_urls in infra/terraform.tfvars covers every frontend address."
  fi
}
