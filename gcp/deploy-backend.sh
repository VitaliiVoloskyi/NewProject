#!/usr/bin/env bash
# Builds the API image (--target cloudrun: no Lambda adapter), pushes it to Artifact Registry
# tagged with the commit SHA, and points the Cloud Run service at it. The service itself, the
# database and the secret are Terraform (gcp/*.tf, applied by HCP Terraform).
# On start, the container runs `alembic upgrade head` against Cloud SQL, then uvicorn.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source gcp/common.sh

  local tag image
  tag="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- backend || echo -dirty)"
  image="$IMAGE_REPO/api:$tag"

  echo "==> [1/3] Build $image"
  docker build --target cloudrun --platform linux/amd64 -t "$image" backend

  echo "==> [2/3] Push to Artifact Registry"
  gcloud auth configure-docker "$GCP_REGION-docker.pkg.dev" --quiet >/dev/null
  docker push "$image"

  echo "==> [3/3] Deploy to Cloud Run ($API_SERVICE)"
  gc run services update "$API_SERVICE" --region "$GCP_REGION" --image "$image"

  local url
  url="$(gc run services describe "$API_SERVICE" --region "$GCP_REGION" --format 'value(status.url)')"
  echo
  echo "API:    $url/api/health"
  curl -fsS "$url/api/health" && echo
}

main "$@"
