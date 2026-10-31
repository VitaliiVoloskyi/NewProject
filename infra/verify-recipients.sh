#!/usr/bin/env bash
# Requests SES verification for every report recipient: in the SES sandbox mail goes only to
# verified addresses, and verifying one sends a link to it. Run via `make verify-recipients`.
# The addresses are REPORTS_RECIPIENTS in .env, or else the ones the mailer sends to now
# (report_recipients in the HCP Terraform workspace).
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  recipients="${REPORTS_RECIPIENTS:-}"
  if [ -z "$recipients" ]; then
    recipients="$(aws lambda get-function-configuration --function-name "$PROJECT_NAME-report-mailer" \
      --query Environment.Variables.RECIPIENTS --output text 2>/dev/null || true)"
  fi
  [ -n "$recipients" ] && [ "$recipients" != "None" ] || {
    echo "Set REPORTS_RECIPIENTS in .env (your own email address) first." >&2
    exit 1
  }

  IFS=',' read -r -a addresses <<<"$recipients"
  for address in "${addresses[@]}"; do
    address="${address//[[:space:]]/}"
    [ -n "$address" ] || continue
    status="$(aws sesv2 get-email-identity --email-identity "$address" \
      --query VerificationStatus --output text 2>/dev/null || true)"
    if [ -z "$status" ]; then
      aws sesv2 create-email-identity --email-identity "$address" \
        --tags "Key=$TAG_KEY,Value=$PROJECT_NAME" >/dev/null
      echo "$address: verification email sent; open the link in it before the first report"
    else
      echo "$address: $status"
    fi
  done
}

main "$@"
