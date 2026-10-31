#!/usr/bin/env bash
# Ships the backend's code to the report builder and the agenda parser: builds the backend image
# at its `app` target (no Lambda Web Adapter), pushes it to ECR and points both functions at it.
# Run via `make deploy-functions`; make deploy-backend (and CI) run it after every backend deploy.
# The functions themselves are Terraform (infra/reports.tf, infra/ai.tf), which ignores the image.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  functions=()
  for f in "$REPORT_BUILDER" "$AGENDA_PARSER"; do
    function_exists "$f" && functions+=("$f")
  done
  if [ ${#functions[@]} -eq 0 ]; then
    echo "Neither $REPORT_BUILDER nor $AGENDA_PARSER exists yet; HCP Terraform creates them (infra/)."
    exit 0
  fi
  TAG="$(image_tag)-app"

  echo "==> [1/2] Build and push the app image (the backend at its 'app' target)"
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

  echo "==> [2/2] Point the functions at $TAG"
  for f in "${functions[@]}"; do
    aws lambda update-function-code --function-name "$f" --image-uri "$image" >/dev/null
    aws lambda wait function-updated-v2 --function-name "$f"
    echo "    $f"
  done
}

main "$@"
