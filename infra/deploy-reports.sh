#!/usr/bin/env bash
# Deploys the weekly meetings report (infra/reports.yaml): the schedule, the queue, the S3
# bucket and the builder and mailer Lambdas. Run via `make deploy-reports` after
# `make deploy-backend`; later backend deploys (and CI) refresh the builder's code by running
# this script again. Settings come from REPORTS_* in .env.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$BACKEND_STACK" || {
    echo "Stack $BACKEND_STACK not found; run make deploy-backend first." >&2
    exit 1
  }
  recipients="${REPORTS_RECIPIENTS:-}"
  if [ -z "$recipients" ] && ! stack_exists "$REPORTS_STACK"; then
    echo "Set REPORTS_RECIPIENTS in .env (your own email address) first." >&2
    exit 1
  fi
  TAG="$(image_tag)-reports"

  echo "==> [1/4] SES identities"
  # In the SES sandbox mail goes only to verified addresses. Verifying one sends a link to it.
  IFS=',' read -r -a addresses <<<"$recipients"
  for address in "${addresses[@]}"; do
    address="${address//[[:space:]]/}"
    [ -n "$address" ] || continue
    status="$(aws sesv2 get-email-identity --email-identity "$address" \
      --query VerificationStatus --output text 2>/dev/null || true)"
    if [ -z "$status" ]; then
      aws sesv2 create-email-identity --email-identity "$address" \
        --tags "Key=$TAG_KEY,Value=$PROJECT_NAME" >/dev/null
      echo "    $address: verification email sent; open the link in it before the first report"
    else
      echo "    $address: $status"
    fi
  done

  echo "==> [2/4] Build and push the builder image (the backend at its 'app' target)"
  repository="$(output "$ECR_STACK" RepositoryUri)"
  image="$repository:$TAG"
  if aws ecr describe-images --repository-name "$PROJECT_NAME-backend" --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
    echo "    $image already in ECR, skipping"
  else
    docker build --platform linux/amd64 --provenance=false --sbom=false --target app \
      --tag "$image" backend
    aws ecr get-login-password | docker login --username AWS --password-stdin "${repository%%/*}"
    docker push "$image"
  fi

  echo "==> [3/4] Report stack ($REPORTS_STACK)"
  # The builder reads the same database as the API, with the same connection string.
  database_url="$(aws lambda get-function-configuration \
    --function-name "$(output "$BACKEND_STACK" FunctionName)" \
    --query Environment.Variables.DATABASE_URL --output text)"
  params=(
    "ProjectName=$PROJECT_NAME"
    "ImageUri=$image"
    "DatabaseUrl=$database_url"
    "VpcId=$(output "$BACKEND_STACK" VpcId)"
    "SubnetIds=$(output "$BACKEND_STACK" PrivateSubnetIds)"
    "SecurityGroupId=$(output "$BACKEND_STACK" FunctionSecurityGroupId)"
    "RouteTableId=$(output "$BACKEND_STACK" PrivateRouteTableId)"
    # Always passed, so removing them from .env restores the defaults.
    "ScheduleExpression=${REPORTS_SCHEDULE:-cron(0 7 ? * MON *)}"
    "BreakWeek=${REPORTS_BREAK_WEEK:-}"
  )
  # Kept from the previous deploy when unset (e.g. in CI).
  [ -n "$recipients" ] && params+=("Recipients=$recipients")
  [ -n "${REPORTS_DOMAIN:-}" ] && params+=("SenderDomain=$REPORTS_DOMAIN" "HostedZoneId=${HOSTED_ZONE_ID:-}")
  aws cloudformation deploy \
    --stack-name "$REPORTS_STACK" \
    --template-file infra/reports.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides "${params[@]}" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  echo "==> [4/4] Summary"
  schedule="$(aws cloudformation describe-stacks --stack-name "$REPORTS_STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='ScheduleExpression'].ParameterValue" --output text)"
  echo "    Bucket:   s3://$(output "$REPORTS_STACK" BucketName)/reports/"
  echo "    Schedule: $schedule (Europe/Kyiv)"
  echo "    Sender:   $(output "$REPORTS_STACK" Sender)"
  [ -n "${REPORTS_BREAK_WEEK:-}" ] && echo "    Broken on purpose for $REPORTS_BREAK_WEEK (REPORTS_BREAK_WEEK)"
  dkim="$(output "$REPORTS_STACK" DkimRecords)"
  if [ -n "$dkim" ] && [ "$dkim" != "None" ] && [ -z "${HOSTED_ZONE_ID:-}" ]; then
    echo "    Add these DKIM records at your DNS provider to verify the sender domain:"
    echo "$dkim" | tr '|' '\n' | sed 's/^ */      /'
  fi
  echo
  echo "Build a report now: make report-now WEEK=$(python3 -c \
    'import datetime as d; print((d.date.today() - d.timedelta(weeks=1)).strftime("%G-W%V"))')"
}

main "$@"
