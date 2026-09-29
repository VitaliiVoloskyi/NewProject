#!/usr/bin/env bash
# Builds the frontend against the backend's address and deploys it to a private S3 bucket
# behind CloudFront, then invalidates the CloudFront cache. Run via `make deploy-frontend`
# (after deploy-backend), locally or in GitHub Actions.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$BACKEND_STACK" || { echo "Stack $BACKEND_STACK not found; run make deploy-backend first." >&2; exit 1; }
  require_auth_stack
  api_base_url="$(output "$BACKEND_STACK" ApiBaseUrl)"

  echo "==> [1/6] Build the frontend (API: $api_base_url)"
  if [[ "$api_base_url" == http://* ]]; then
    echo "    WARNING: the API has no HTTPS yet. Browsers block an https:// page from calling it,"
    echo "    so the deployed app cannot load meetings until API_DOMAIN is set and deployed."
  fi
  (cd frontend && npm ci --no-audit --no-fund && \
    VITE_API_URL="$api_base_url" \
    COGNITO_USER_POOL_ID="$(output "$AUTH_STACK" UserPoolId)" \
    COGNITO_CLIENT_ID="$(output "$AUTH_STACK" UserPoolClientId)" \
    COGNITO_DOMAIN="$(output "$AUTH_STACK" Domain)" \
    COGNITO_GOOGLE_ENABLED="$(output "$AUTH_STACK" GoogleEnabled)" \
    npm run build)

  echo "==> [2/6] Certificate for the app domain (CloudFront needs it in $APP_CERT_REGION)"
  cert_arn=""
  if [ -n "$APP_DOMAIN" ]; then
    cert_arn="$(ensure_certificate "$APP_CERT_STACK" "$APP_CERT_REGION" "$APP_DOMAIN" | tail -n1)"
    echo "    $APP_DOMAIN: $cert_arn"
  else
    echo "    APP_DOMAIN is empty: the app is served on its *.cloudfront.net address"
  fi

  echo "==> [3/6] S3 bucket + CloudFront ($FRONTEND_STACK)"
  echo "    The first run creates the CloudFront distribution and takes about 5 minutes."
  aws cloudformation deploy \
    --stack-name "$FRONTEND_STACK" \
    --template-file infra/frontend.yaml \
    --parameter-overrides \
      "ProjectName=$PROJECT_NAME" \
      "DomainName=$APP_DOMAIN" \
      "CertificateArn=$cert_arn" \
      "HostedZoneId=$HOSTED_ZONE_ID" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
  bucket="$(output "$FRONTEND_STACK" BucketName)"
  distribution="$(output "$FRONTEND_STACK" DistributionId)"

  echo "==> [4/6] Let the frontend call the API, and Cognito redirect back to it"
  update_backend_cors
  update_auth_urls

  echo "==> [5/6] Upload to s3://$bucket"
  # Hashed assets never change, so browsers may cache them forever; everything else is revalidated.
  aws s3 sync frontend/dist/assets "s3://$bucket/assets" --delete \
    --cache-control "public, max-age=31536000, immutable"
  aws s3 sync frontend/dist "s3://$bucket" --delete --exclude "assets/*" \
    --cache-control "no-cache"

  echo "==> [6/6] Invalidate the CloudFront cache"
  # Without this, edge locations keep serving the old index.html until it expires.
  # "/*" counts as a single path against the 1,000 free invalidation paths per month.
  invalidation="$(aws cloudfront create-invalidation --distribution-id "$distribution" \
    --paths "/*" --query Invalidation.Id --output text)"
  aws cloudfront wait invalidation-completed --distribution-id "$distribution" --id "$invalidation"

  echo
  echo "App: $(output "$FRONTEND_STACK" AppUrl)"
  [ -z "$APP_DOMAIN" ] || echo "     https://$APP_DOMAIN"
  echo "API: $api_base_url/api"
  if [ -n "$APP_DOMAIN" ] && [ -z "$HOSTED_ZONE_ID" ]; then
    echo
    echo "Point the app domain at CloudFront at your DNS provider (once):"
    echo "  CNAME  $APP_DOMAIN  ->  $(output "$FRONTEND_STACK" DistributionDomain)"
  fi
}

main "$@"
