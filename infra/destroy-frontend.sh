#!/usr/bin/env bash
# Deletes the frontend stack (S3 bucket + CloudFront distribution) and the custom domain's
# certificate stack, if any.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$FRONTEND_STACK" || { echo "Stack $FRONTEND_STACK not found."; exit 0; }

  read -r -p "Delete stack $FRONTEND_STACK in $AWS_REGION? Type the app name to confirm: " answer
  [ "$answer" = "$PROJECT_NAME" ] || { echo "Aborted."; exit 1; }

  # CloudFormation cannot delete a bucket that still has objects in it.
  bucket="$(output "$FRONTEND_STACK" BucketName)"
  echo "==> Emptying s3://$bucket"
  aws s3 rm "s3://$bucket" --recursive >/dev/null

  echo "==> Deleting $FRONTEND_STACK (disabling CloudFront takes several minutes)"
  aws cloudformation delete-stack --stack-name "$FRONTEND_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$FRONTEND_STACK"

  # Only possible once no distribution uses the certificate any more.
  if stack_exists "$CERT_STACK" "$CERT_REGION"; then
    echo "==> Deleting $CERT_STACK ($CERT_REGION)"
    aws cloudformation delete-stack --stack-name "$CERT_STACK" --region "$CERT_REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$CERT_STACK" --region "$CERT_REGION"
  fi
  echo "Done."
}

main "$@"
