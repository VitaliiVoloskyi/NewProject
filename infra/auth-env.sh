#!/usr/bin/env bash
# Writes the Cognito settings from Terraform's outputs (infra/auth.tf) to .env, for local runs
# against the same user pool as AWS. Run via `make auth-env`. None of them are secrets: the
# browser receives all of them.
set -euo pipefail

# set_env KEY VALUE: sets KEY=VALUE in .env, replacing an existing line or appending one.
set_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if grep -q "^$key=" .env; then
    awk -v k="$key" -v v="$value" 'index($0, k "=") == 1 { print k "=" v; next } { print }' .env >"$tmp"
  else
    cat .env >"$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  cat "$tmp" >.env
  rm -f "$tmp"
}

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  pool_id="$(tf_output cognito_user_pool_id)"
  client_id="$(tf_output cognito_client_id)"
  domain="$(tf_output cognito_domain)"
  google="$(tf_output cognito_google_enabled)"
  parser_url="$(tf_output parser_url)"

  set_env COGNITO_USER_POOL_ID "$pool_id"
  set_env COGNITO_CLIENT_ID "$client_id"
  set_env COGNITO_DOMAIN "$domain"
  set_env COGNITO_GOOGLE_ENABLED "$google"
  set_env VITE_PARSER_URL "$parser_url"

  echo "Written to .env:"
  echo
  echo "  COGNITO_USER_POOL_ID=$pool_id"
  echo "  COGNITO_CLIENT_ID=$client_id"
  echo "  COGNITO_DOMAIN=$domain"
  echo "  COGNITO_GOOGLE_ENABLED=$google"
  echo "  VITE_PARSER_URL=$parser_url"
  echo
  echo "  Issuer:  $(tf_output cognito_issuer)"
  echo "  Console: https://$AWS_REGION.console.aws.amazon.com/cognito/v2/idp/user-pools/$pool_id/users?region=$AWS_REGION"
}

main "$@"
