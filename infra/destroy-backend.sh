#!/usr/bin/env bash
# Deletes the backend stacks. The database is kept as a final Aurora cluster snapshot
# (DeletionPolicy: Snapshot), whose storage is billed until you delete it.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  if stack_exists "$FRONTEND_STACK"; then
    echo "Note: $FRONTEND_STACK still exists; the app will fail to load data until you run make destroy-frontend."
  fi
  read -r -p "Delete stacks $PROJECT_NAME-backend and $PROJECT_NAME-ecr in $AWS_REGION? Type the app name to confirm: " answer
  [ "$answer" = "$PROJECT_NAME" ] || { echo "Aborted."; exit 1; }

  echo "==> Deleting $PROJECT_NAME-backend (Lambda's VPC network interfaces can take up to ~20 minutes to release)"
  aws cloudformation delete-stack --stack-name "$BACKEND_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$BACKEND_STACK"

  echo "==> Deleting images and $PROJECT_NAME-ecr"
  aws ecr delete-repository --repository-name "$BACKEND_STACK" --force >/dev/null 2>&1 || true
  aws cloudformation delete-stack --stack-name "$ECR_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$ECR_STACK"

  echo "Done."
  echo "Kept: the final database snapshot (restoring it needs the password in /$PROJECT_NAME/db-password)."
  echo "  aws rds describe-db-cluster-snapshots --db-cluster-identifier $PROJECT_NAME-db"
  echo "  aws ssm delete-parameter --name /$PROJECT_NAME/db-password   # once you no longer need it"
}

main "$@"
