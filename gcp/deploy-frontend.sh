#!/usr/bin/env bash
# Builds the frontend for Firebase Hosting and deploys it. The API is not a separate origin here:
# Firebase rewrites /api/** to the Cloud Run service, so the bundle calls /api on its own origin
# (VITE_API_URL empty, no CORS), as it does behind CloudFront on AWS.
#
# Sign-in stays on Cognito (AWS). Its public ids come from .env (make auth-env); the Firebase
# addresses must be in app_urls in infra/terraform.tfvars, or Cognito refuses to send users back.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source gcp/common.sh

  local out=gcp/.firebase-deploy
  rm -rf "$out" && mkdir -p "$out"

  echo "==> [1/2] Build the frontend (API: /api on the Firebase origin, via a rewrite)"
  (cd frontend && npm ci && \
    VITE_API_URL="" \
    VITE_PARSER_URL="${VITE_PARSER_URL:-}" \
    COGNITO_USER_POOL_ID="${COGNITO_USER_POOL_ID:?set it in .env (make auth-env)}" \
    COGNITO_CLIENT_ID="${COGNITO_CLIENT_ID:?}" \
    COGNITO_DOMAIN="${COGNITO_DOMAIN:?}" \
    COGNITO_GOOGLE_ENABLED="${COGNITO_GOOGLE_ENABLED:-false}" \
    npm run build)
  cp -r frontend/dist "$out/public"

  # Generated, because the rewrite names the service and region of this project.
  cat > "$out/firebase.json" <<EOF
{
  "hosting": {
    "site": "$HOSTING_SITE",
    "public": "public",
    "cleanUrls": true,
    "rewrites": [
      { "source": "/api/**", "run": { "serviceId": "$API_SERVICE", "region": "$GCP_REGION" } },
      { "source": "**", "destination": "/index.html" }
    ],
    "headers": [
      { "source": "/assets/**", "headers": [{ "key": "Cache-Control", "value": "public, max-age=31536000, immutable" }] },
      { "source": "**/*.html", "headers": [{ "key": "Cache-Control", "value": "no-cache" }] }
    ]
  }
}
EOF

  echo "==> [2/2] Deploy to Firebase Hosting ($HOSTING_SITE)"
  # firebase-tools uses your application default credentials (gcloud auth application-default
  # login), or `npx firebase-tools login` if you prefer.
  (cd "$out" && npx --yes firebase-tools@14 deploy --only hosting --project "$GCP_PROJECT" --non-interactive)

  echo
  echo "App: https://$HOSTING_SITE.web.app"
  echo "API: https://$HOSTING_SITE.web.app/api/health"
}

main "$@"
