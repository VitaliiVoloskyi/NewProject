#!/usr/bin/env bash
# Deploys Paste an agenda (infra/ai.yml): the agenda-parser Lambda and its function URL, and the
# monthly budget alarm. Run via `make deploy-ai` after `make deploy-backend`; later backend
# deploys (and CI) refresh the parser's code by running this script again. Then run
# `make deploy-frontend`, which builds the app against the parser's URL.
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
  require_auth_stack
  TAG="$(image_tag)-app"

  echo "==> [1/3] Build and push the parser image (the backend at its 'app' target)"
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

  echo "==> [2/3] Parser stack ($AI_STACK)"
  params=(
    "ProjectName=$PROJECT_NAME"
    "ImageUri=$image"
    "CognitoUserPoolId=$(output "$AUTH_STACK" UserPoolId)"
    "CognitoClientId=$(output "$AUTH_STACK" UserPoolClientId)"
    "CorsOrigins=$(ai_cors_origins)"
  )
  # Kept from the previous deploy when unset (e.g. in CI).
  [ -n "${PARSER_MODEL:-}" ] && params+=("ParserModel=$PARSER_MODEL")
  [ -n "${BUDGET_EMAIL:-}" ] && params+=("BudgetEmail=$BUDGET_EMAIL")
  aws cloudformation deploy \
    --stack-name "$AI_STACK" \
    --template-file infra/ai.yml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides "${params[@]}" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  echo "==> [3/3] Summary"
  model="$(aws cloudformation describe-stacks --stack-name "$AI_STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='ParserModel'].ParameterValue" --output text)"
  budget="$(aws cloudformation describe-stacks --stack-name "$AI_STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='BudgetEmail'].ParameterValue" --output text)"
  echo "    Parser:  $(output "$AI_STACK" ParserUrl)"
  echo "    Model:   $model"
  echo "    Logs:    make parser-logs"
  if [ -n "$budget" ] && [ "$budget" != "None" ]; then
    echo "    Budget:  alarm to $budget above \$5 a month"
  else
    echo "    Budget:  none; set BUDGET_EMAIL in .env and run make deploy-ai again"
  fi
  echo
  echo "Next: make deploy-frontend (builds the app against the parser's URL)"
}

main "$@"
