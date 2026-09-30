#!/usr/bin/env bash
# Deletes the Cognito stack (app client, domain, Google provider). The user pool itself is
# retained (DeletionPolicy: Retain) because deleting it deletes every account; the command
# prints how to delete it for good. A later make deploy-auth creates a new, empty pool.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  require_auth_stack
  pool_id="$(output "$AUTH_STACK" UserPoolId)"
  read -r -p "Delete stack $AUTH_STACK in $AWS_REGION (the user pool $pool_id is kept)? Type the app name to confirm: " answer
  [ "$answer" = "$PROJECT_NAME" ] || { echo "Aborted."; exit 1; }

  aws cloudformation delete-stack --stack-name "$AUTH_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$AUTH_STACK"

  echo "Done. Kept: user pool $pool_id with its accounts. To delete it and every account:"
  echo "  aws cognito-idp delete-user-pool --user-pool-id $pool_id"
}

main "$@"
