# Weekly meetings report

Every Monday at 07:00 Kyiv time the system builds last week's meetings report as a CSV, saves
it to S3 and emails it through SES. Nobody clicks anything.

```
EventBridge Scheduler ──┐  {"week": null, "source": "schedule"}
make report-now ────────┤  {"week": "2026-W39", "source": "make report-now"}
                        ▼
              SQS report-requests ──(3 failures)──▶ report-requests-dlq
                        │ event source mapping, BatchSize 1
                        ▼
  ┌──────── VPC, no NAT ──────────────────────────────┐
  │ report-builder Lambda ──▶ RDS PostgreSQL          │
  │   (backend image, app target)                     │
  │        │ S3 gateway endpoint                      │
  └────────┼──────────────────────────────────────────┘
           ▼
  S3 reports/<week>.csv ──ObjectCreated──▶ report-mailer Lambda (no VPC) ──▶ SES ──▶ inbox
```

| Piece | Where |
|---|---|
| The report (plain Python, no AWS) | [`backend/app/reports/weekly.py`](../backend/app/reports/weekly.py) |
| Builder handler (schedule / SQS / direct) | [`backend/app/reports/lambda_handler.py`](../backend/app/reports/lambda_handler.py) |
| Mailer handler (S3 event) | inline in [`infra/reports.yaml`](../infra/reports.yaml) |
| Infrastructure | [`infra/reports.yaml`](../infra/reports.yaml), [`infra/deploy-reports.sh`](../infra/deploy-reports.sh) |
| Tests | [`backend/tests/test_reports.py`](../backend/tests/test_reports.py) |

The week is always a parameter (`2026-W40`, Monday to Sunday in Europe/Kyiv). The handler, not
the report, decides that "no week" means the previous one. One week always maps to the same
file, `reports/2026-W40.csv`, so building it twice overwrites one object.

**Why the builder has its own image target.** It reuses the backend's Dockerfile and code but
is built with `--target app`, which leaves out the Lambda Web Adapter. The adapter is a Lambda
extension: it starts in every container of an image that contains it and takes the
invocations itself, so a plain Python handler in the API image would never receive them.

## Run it

```sh
make report-local WEEK=2026-W40   # the CSV from your local compose database, no AWS
```

On AWS, after `make deploy-backend`:

1. Set `REPORTS_RECIPIENTS=you@example.com` in `.env` (and optionally `REPORTS_DOMAIN`).
2. `make deploy-reports`. The first run emails each recipient a verification link from AWS.
   Open it: the SES sandbox only delivers to verified addresses.
3. With `REPORTS_DOMAIN` set: add the three DKIM CNAMEs it prints at your DNS provider (made
   automatically when `HOSTED_ZONE_ID` is the domain's Route 53 zone). Without a domain the
   report is sent from your verified address to itself.

From then on `make deploy-backend`, locally or in CI, also ships the builder's new code.

| Command | What it does |
|---|---|
| `make report-now WEEK=2026-W39` | Puts a request on the queue (default: last week) |
| `make report-logs` | The last hour of builder and mailer logs |
| `aws s3 ls s3://<project>-reports-<account>/reports/ --recursive` | The saved reports |
| `make destroy-reports` | Deletes the stack and its reports (run before `make destroy-backend`) |

## The submission checklist

1. **The schedule.** Set `REPORTS_SCHEDULE=rate(5 minutes)`, `make deploy-reports`, wait for a
   run, then empty it again and redeploy (back to `cron(0 7 ? * MON *)`).
2. **On demand.** `make report-now WEEK=<last week>`. Within a minute you get a new object, a
   builder line with `"trigger": "sqs"`, a mailer line with `"trigger": "s3"` and an email.
3. **The bucket.** `aws s3 ls s3://<bucket>/reports/ --recursive` now lists both reports.
4. **The three log lines.** The logs are JSON, so each trigger is a field:

   ```sh
   aws logs filter-log-events --log-group-name /spry/report-builder \
     --filter-pattern '{ $.message = "report-builder triggered" }' --query 'events[].message' --output text
   aws logs filter-log-events --log-group-name /spry/report-mailer \
     --filter-pattern '{ $.trigger = "s3" }' --query 'events[].message' --output text
   ```

   Once the queue sits between the schedule and the builder, the schedule's line reads
   `"trigger": "sqs", "source": "schedule"`. To get `"trigger": "schedule"` exactly as the
   schedule invokes the function directly (Step 3), invoke it with the same payload:

   ```sh
   aws lambda invoke --function-name spry-report-builder \
     --payload '{"source": "schedule", "week": null}' --cli-binary-format raw-in-base64-out /dev/stdout
   ```

5. **Breaking it (DLQ).** `REPORTS_BREAK_WEEK=2026-W13`, `make deploy-reports`,
   `make report-now WEEK=2026-W13`. After three attempts (the visibility timeout is 6 minutes,
   so allow about 20 minutes) the message is in `spry-report-requests-dlq`. Empty the variable,
   redeploy, then in the SQS console: the DLQ → **Start DLQ redrive**.
6. **The same week twice.** `make report-now` twice for one week gives **two emails**. The
   builder is idempotent: the second run overwrites the same `reports/<week>.csv`. But every
   PutObject, including an overwrite, is a new `ObjectCreated:Put` event, and sending an email
   is not idempotent. The file is the same; the side effect happened twice.

## Answers (Part 3, Step 7)

**1. The mailer got the same ObjectCreated event twice. Where do you store "already sent", and
what is the key?**

In a small DynamoDB table, `report_emails`, written with a conditional put
(`attribute_not_exists(pk)`) *before* sending. If the put fails because the item exists, the
email was already sent and the mailer stops. DynamoDB fits because the mailer runs outside the
VPC and cannot reach Postgres, and because a conditional write is atomic: two concurrent
copies of the event cannot both win. A tag on the S3 object would be cheap but is a
read-then-write, so two copies can both read "not sent".

The key decides what counts as "the same":

- `reports/2026-W40.csv#<ETag>` (or `#<versionId>` with versioning on): the same file is
  emailed once. A rebuild that changes the content is a new file and is emailed again. This is
  the right default: it removes duplicate *deliveries* but keeps intentional rebuilds.
- `2026-W40#<recipient>`: each person gets each week once, whatever happens afterwards.

Add a TTL attribute (for example 100 days) so the table does not grow forever. The S3 event's
`sequencer` is not a good key: it identifies the write, and a redelivered event carries the
same one, but an overwrite with identical content gets a new one.

**2. The builder in the VPC cannot reach SES. Three fixes and their monthly cost (us-east-1):**

| Option | Fixed cost per month | Per use |
|---|---|---|
| NAT gateway (one, in one AZ) | $0.045/h × 730 h ≈ **$33** (+ a public IPv4 ≈ $3.65) | $0.045 per GB processed |
| Interface VPC endpoint for SES, in 2 AZs | $0.01/h × 730 h × 2 ≈ **$14.60** | $0.01 per GB |
| The split: a second Lambda outside the VPC | **≈ $0** (free tier; $0.20 per million requests after) | — |

SES itself costs $0.10 per 1,000 emails whichever option you pick.

- **Ten more emails a week:** the split. It costs nothing, and the two others cost $15–33 a
  month to send a few dozen emails.
- **A million emails a week:** still the split. SES is now about $430 a month, and the network
  path is not what costs money: one mailer invocation per report, or a few thousand per
  batch, stays inside the free tier. The NAT gateway would add per-GB charges on top of its
  hourly price. I would revisit the choice only if the builder itself needed many other
  internet services; then an endpoint per service, or one NAT gateway, becomes simpler than
  splitting every call into a separate function.

**3. A link that works for a week instead of an attachment?**

A presigned URL is valid only while the credentials that signed it are, and Lambda's role
credentials last hours. SigV4 also caps any presigned URL at 7 days. Options:

- **Best: a link to your own API**, for example `https://app/reports/2026-W40?token=…`, where
  the token is an HMAC (or a random id stored in the database) with its own expiry. The API
  checks it and redirects to a fresh presigned URL valid for a minute. The link lives as long
  as you decide, can be revoked, and you can log who opened it.
- **CloudFront signed URLs** with a key pair in front of the bucket: any expiry, signed with a
  private key from Secrets Manager rather than with temporary credentials.
- Sign with an IAM user's long-term access key, kept in Secrets Manager, with
  `ExpiresIn=604800`. It works, but it brings back a long-lived secret that has to be rotated,
  and 7 days is the hard maximum.
