#!/usr/bin/env bash
# Deletes the Paste an agenda stack: the parser, its URL and logs, and the budget alarm.
# Saved agendas are kept: they live in the database.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$AI_STACK" || { echo "Stack $AI_STACK not found, nothing to delete."; exit 0; }
  read -r -p "Delete $AI_STACK in $AWS_REGION? Type the app name to confirm: " answer
  [ "$answer" = "$PROJECT_NAME" ] || { echo "Aborted."; exit 1; }

  echo "==> Deleting $AI_STACK"
  aws cloudformation delete-stack --stack-name "$AI_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$AI_STACK"
  echo "Done. Run make deploy-frontend to hide Paste an agenda in the app."
}

main "$@"
