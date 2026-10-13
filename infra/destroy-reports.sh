#!/usr/bin/env bash
# Deletes the weekly report stack, including every report in its bucket. The SES identities
# (your verified addresses) are kept; the command to delete them is printed at the end.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$REPORTS_STACK" || { echo "Stack $REPORTS_STACK not found, nothing to delete."; exit 0; }
  bucket="$(output "$REPORTS_STACK" BucketName)"
  read -r -p "Delete $REPORTS_STACK and all reports in s3://$bucket in $AWS_REGION? Type the app name to confirm: " answer
  [ "$answer" = "$PROJECT_NAME" ] || { echo "Aborted."; exit 1; }

  # CloudFormation cannot delete a bucket that still has objects in it.
  echo "==> Emptying s3://$bucket"
  aws s3 rm "s3://$bucket" --recursive >/dev/null 2>&1 || true

  echo "==> Deleting $REPORTS_STACK (the builder's VPC network interfaces can take up to ~20 minutes to release)"
  aws cloudformation delete-stack --stack-name "$REPORTS_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$REPORTS_STACK"

  echo "Done. Kept: the SES identities. To delete one:"
  echo "  aws sesv2 delete-email-identity --email-identity <address>"
}

main "$@"
