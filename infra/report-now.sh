#!/usr/bin/env bash
# Requests one week's report on demand: `make report-now WEEK=2026-W39` (default: last week).
# Sends the same message the schedule sends, so the builder cannot tell who asked. Rebuilding a
# week overwrites reports/<week>.csv, and the new object is emailed again.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$REPORTS_STACK" || { echo "Stack $REPORTS_STACK not found; run make deploy-reports first." >&2; exit 1; }
  week="${WEEK:-$(python3 -c 'import datetime as d; print((d.date.today() - d.timedelta(weeks=1)).strftime("%G-W%V"))')}"
  [[ "$week" =~ ^[0-9]{4}-W[0-9]{2}$ ]] || { echo "WEEK must look like 2026-W39, got '$week'." >&2; exit 1; }

  message_id="$(aws sqs send-message \
    --queue-url "$(output "$REPORTS_STACK" QueueUrl)" \
    --message-body "{\"week\": \"$week\", \"source\": \"make report-now\"}" \
    --query MessageId --output text)"
  echo "Requested the report for $week (message $message_id)."
  echo "Within a minute:"
  echo "  aws s3 ls s3://$(output "$REPORTS_STACK" BucketName)/reports/ --recursive"
  echo "  make report-logs"
}

main "$@"
