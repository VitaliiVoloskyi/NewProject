#!/usr/bin/env bash
# Deletes the backend stacks (ECS, load balancer, RDS, VPC), the images and the API
# certificate. The database is kept as a final RDS snapshot (DeletionPolicy: Snapshot),
# whose storage is billed until you delete it.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  if stack_exists "$FRONTEND_STACK"; then
    echo "Note: $FRONTEND_STACK still exists; the app will fail to load data until you run make destroy-frontend."
  fi
  read -r -p "Delete $BACKEND_STACK, $ECR_STACK and $API_CERT_STACK in $AWS_REGION? Type the project name to confirm: " answer
  [ "$answer" = "$PROJECT_NAME" ] || { echo "Aborted."; exit 1; }

  echo "==> Deleting $BACKEND_STACK (the final DB snapshot takes several minutes)"
  aws cloudformation delete-stack --stack-name "$BACKEND_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$BACKEND_STACK"

  echo "==> Deleting images and $ECR_STACK"
  aws ecr delete-repository --repository-name "$PROJECT_NAME-backend" --force >/dev/null 2>&1 || true
  aws cloudformation delete-stack --stack-name "$ECR_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$ECR_STACK"

  if stack_exists "$API_CERT_STACK"; then
    echo "==> Deleting $API_CERT_STACK"
    aws cloudformation delete-stack --stack-name "$API_CERT_STACK"
    aws cloudformation wait stack-delete-complete --stack-name "$API_CERT_STACK"
  fi

  echo "Done."
  echo "Kept: the final database snapshot and the password in /$PROJECT_NAME/db-password."
  echo "  aws rds describe-db-snapshots --db-instance-identifier $PROJECT_NAME-db"
  echo "  aws rds delete-db-snapshot --db-snapshot-identifier <id>   # stops the storage bill"
  echo "  aws ssm delete-parameter --name /$PROJECT_NAME/db-password"
}

main "$@"
