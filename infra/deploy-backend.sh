#!/usr/bin/env bash
# Deploys the backend: builds the image, pushes it to ECR tagged with the commit SHA, and
# rolls the ECS service to it (RDS + ALB + ECS in infra/backend.yaml). Run via
# `make deploy-backend` locally, and by GitHub Actions on every push to main.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  require_auth_stack
  PASSWORD_PARAM="/$PROJECT_NAME/db-password"

  # The commit SHA, plus a timestamp when backend/ has uncommitted changes (tags are immutable).
  TAG="$(git rev-parse --short=12 HEAD)"
  if [ -n "$(git status --porcelain -- backend)" ]; then
    TAG="$TAG-dirty-$(date +%Y%m%d%H%M%S)"
  fi

  account="$(aws sts get-caller-identity --query Account --output text)"
  echo "==> Deploying '$PROJECT_NAME' backend $TAG to account $account in $AWS_REGION"

  echo "==> [1/6] Database password ($PASSWORD_PARAM)"
  if aws ssm get-parameter --name "$PASSWORD_PARAM" >/dev/null 2>&1; then
    echo "    exists, keeping it"
  else
    # Hex only: no characters that need escaping anywhere.
    aws ssm put-parameter --name "$PASSWORD_PARAM" --type SecureString \
      --value "$(openssl rand -hex 24)" \
      --tags "Key=$TAG_KEY,Value=$PROJECT_NAME" >/dev/null
    echo "    created"
  fi

  echo "==> [2/6] Container registry ($ECR_STACK)"
  aws cloudformation deploy \
    --stack-name "$ECR_STACK" \
    --template-file infra/ecr.yaml \
    --parameter-overrides "ProjectName=$PROJECT_NAME" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
  repository="$(output "$ECR_STACK" RepositoryUri)"
  image="$repository:$TAG"

  echo "==> [3/6] Build and push $image"
  if aws ecr describe-images --repository-name "$(output "$ECR_STACK" RepositoryName)" \
    --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
    echo "    already in ECR, skipping the build"
  else
    # Fargate runs X86_64 (see RuntimePlatform); --platform makes Apple Silicon build that too.
    docker build --platform linux/amd64 --provenance=false --tag "$image" backend
    aws ecr get-login-password | docker login --username AWS --password-stdin "${repository%%/*}"
    docker push "$image"
  fi

  echo "==> [4/6] Certificate for the API domain"
  cert_arn=""
  if [ -n "$API_DOMAIN" ]; then
    cert_arn="$(ensure_certificate "$API_CERT_STACK" "$AWS_REGION" "$API_DOMAIN" | tail -n1)"
    echo "    $API_DOMAIN: $cert_arn"
  else
    echo "    API_DOMAIN is empty: the API is served over plain HTTP on the load balancer address"
  fi

  echo "==> [5/6] RDS + load balancer + ECS service ($BACKEND_STACK)"
  echo "    The first run creates the database and takes about 10-15 minutes."
  echo "    Later runs register a new task definition and roll the service (a few minutes)."
  aws cloudformation deploy \
    --stack-name "$BACKEND_STACK" \
    --template-file infra/backend.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      "ProjectName=$PROJECT_NAME" \
      "ImageUri=$image" \
      "CorsOrigins=$(cors_origins)" \
      "CognitoUserPoolId=$(output "$AUTH_STACK" UserPoolId)" \
      "CognitoClientId=$(output "$AUTH_STACK" UserPoolClientId)" \
      "ApiDomain=$API_DOMAIN" \
      "CertificateArn=$cert_arn" \
      "HostedZoneId=$HOSTED_ZONE_ID" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  alb="$(output "$BACKEND_STACK" LoadBalancerDns)"
  api_base_url="$(output "$BACKEND_STACK" ApiBaseUrl)"

  # Straight at the load balancer, so this works before the api DNS record exists
  # (-k: its own hostname is not on the certificate).
  echo "==> [6/6] Health check through the load balancer"
  if [ -n "$cert_arn" ]; then check="https://$alb/api/health"; else check="http://$alb/api/health"; fi
  for _ in $(seq 30); do
    if curl -fsSk --max-time 10 "$check" >/dev/null 2>&1; then
      echo "    healthy: $check"
      echo
      echo "Image: $image"
      echo "API:   $api_base_url/api"
      echo "Docs:  $api_base_url/api/docs"
      if [ -n "$API_DOMAIN" ] && [ -z "$HOSTED_ZONE_ID" ]; then
        echo
        echo "Point the API domain at the load balancer at your DNS provider (once):"
        echo "  CNAME  $API_DOMAIN  ->  $alb"
      fi
      exit 0
    fi
    sleep 5
  done
  echo "Backend did not become healthy. Logs: aws logs tail /$PROJECT_NAME/backend --follow" >&2
  exit 1
}

main "$@"
