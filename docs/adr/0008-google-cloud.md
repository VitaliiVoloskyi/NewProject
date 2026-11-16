# 8. Run Spry's core on Google Cloud: Firebase Hosting, Cloud Run, Cloud SQL; sign-in stays on AWS

Date: 2026-11-16 · Status: accepted

## Context

Labs 4–7 put Spry on AWS: a React bundle on S3 + CloudFront, FastAPI in a container on Lambda
(function URL, Lambda Web Adapter), RDS PostgreSQL db.t4g.micro in private subnets, Cognito
sign-in, a weekly report (EventBridge Scheduler → SQS → Lambda → S3 → SES) and an agenda parser
(Claude on Bedrock). Lab 9 asks what the same system would take on Google Cloud, and what it would
cost. We move the core (frontend, API, database) and keep the rest on AWS for now.

## Decision: one row per piece

| Spry on AWS | On Google Cloud | Decision | Why |
|---|---|---|---|
| S3 + CloudFront, static frontend | **Firebase Hosting** | **replace** | CDN, HTTPS and a certificate on `*.web.app` included, free up to 10 GB stored and 360 MB a day out. A rewrite sends `/api/**` to Cloud Run, so the browser sees one origin and needs no CORS, as with CloudFront |
| Lambda + function URL (FastAPI, Lambda Web Adapter) | **Cloud Run** | **replace** | The same Docker image with the Lambda adapter left out (`--target cloudrun`). Cloud Run sends plain HTTP to `$PORT`, scales to zero, and has no 15-minute limit. One instance serves up to 80 requests at once, where Lambda serves one |
| ECR | **Artifact Registry** | **replace** | A cleanup policy keeps the last 3 images, within the free 0.5 GB |
| RDS PostgreSQL db.t4g.micro, private subnets | **Cloud SQL for PostgreSQL 17, db-f1-micro, 10 GB SSD** | **replace** | No code changes (the next section compares the options). No VPC: the instance has a public IP with no authorized networks, so nobody can connect to it directly. Cloud Run reaches it through the Cloud SQL connector, with IAM (`roles/cloudsql.client`) and encryption |
| DynamoDB | Firestore | **not used** | Spry never left SQL |
| Cognito user pool + Google | Identity Platform | **keep on AWS** | The API only verifies Cognito ID tokens (it downloads the pool's public keys once), so it works the same from Cloud Run. Cognito cannot export password hashes: moving would make every user with a password reset it. Identity Platform is a stretch goal |
| EventBridge Scheduler + SQS + report Lambdas | Cloud Scheduler + Pub/Sub or Cloud Tasks + Cloud Run | **keep on AWS for now** | Stretch goal. Caveat: the builder reads the AWS database, so while users work on GCP, the report covers only the AWS data |
| S3 (report CSVs) | Cloud Storage | **keep on AWS** | Goes with the report |
| SES | none on GCP | **keep SES** (multicloud) | See "E-mail" below |
| Bedrock (Claude), agenda parser Lambda | Vertex AI (Gemini, or Claude through Model Garden) | **keep on AWS** | The parser reads no data and writes nothing. The browser calls its function URL directly with the Cognito token, and its CORS list (`app_urls`) now includes the Firebase origins. The trial credit does not pay for Claude on Vertex |
| SSM Parameter Store (database password) | **Secret Manager** | **replace** | Terraform generates the password and stores the whole `DATABASE_URL` as one secret (1 active version; 6 are free). Only `spry-api` can read it |
| CloudWatch Logs | **Cloud Logging** | **replace** (automatic) | Cloud Run sends stdout to it. `make gcp-logs` |
| IAM roles | **Service accounts** | **replace** | `spry-terraform` for HCP Terraform and `spry-api` for the service. No Owner or Editor, no keys, and not the default compute account |
| Terraform `aws` provider, workspace `spry-dev` | `google` provider, **workspace `spry-gcp`** | **replace** | `gcp/`, with separate state, so one plan cannot break both clouds. The APIs are enabled from Terraform |
| HCP Terraform → AWS dynamic credentials | **Workload Identity Federation** | **replace** | `gcp/bootstrap`: a pool trusting `app.terraform.io`, admitting only our organization and workspace by their immutable ids |
| GitHub Actions → AWS OIDC role | GitHub Actions → WIF | **later** | For now the image and the bundle are deployed from a laptop (`make gcp-deploy`) with my own Google login |

## The database: four options

| Option | Latency from the API | Bill per month | Code |
|---|---|---|---|
| **Cloud SQL around the clock** | ~1 ms (same region, Unix socket via the connector) | $7.67 compute + $1.70 disk = **$9.37** | none: same PostgreSQL, same Alembic migrations |
| **Cloud SQL, stopped when unused** (`make gcp-db-stop` / `gcp-db-start`) | same while running. A request while it is stopped fails, and starting takes 1–2 minutes | $1.70 disk + $0.0105 per running hour: **$1.91** for class demos, **$3.55** for office hours | none. Starting and stopping is a chore, or 2 Cloud Scheduler jobs (within the 3 free) |
| **Firestore** | 10–30 ms per document read, and several reads per screen | **$0** at student traffic (50k reads, 20k writes a day free) | rewrite: meetings ↔ participants is many-to-many, every query is scoped by owner, migrations go away, and the data layer and its tests are rewritten. The bill then depends on how many reads the code does |
| **Keep RDS on AWS, call it across clouds** | us-central1 → us-east-1 is ~35 ms a round trip, and one request runs 3–5 queries: **+100–200 ms** | RDS $13.98 + egress both ways. RDS is private, so this needs a public endpoint or a VPN (HA VPN alone is about $73) | none, but a database on the internet, or a VPN to run |

**Chosen: Cloud SQL, stopped when nobody uses it.** The point of the move is that the code doesn't
change. Turning it on and off is one command, and the trial credit covers $9 a month many times
over. Firestore would save that $9 but costs a rewrite of the data layer. The cross-cloud database
is the worst of both: slow, still billed, and it opens the private database. Terraform leaves
`activation_policy` alone (`ignore_changes`), so stopping the database is an operating decision,
not a configuration change.

**Data:** migrations, not `pg_dump`. RDS sits in private subnets with no public access, and the
data is test data. The container runs `alembic upgrade head` on start against the empty Cloud SQL
database. Users and their meetings are created again on first sign-in, since the user row is keyed
by the Cognito `sub`, which is the same on both clouds.

## E-mail

Google has no SES. **Keep SES** for the weekly report while the report stays on AWS. When the
report moves to Cloud Run, it should still call SES, with no key: the `spry-reports` service
account's Google ID token is exchanged for an AWS role (`AssumeRoleWithWebIdentity`, an AWS role
that trusts `accounts.google.com` for that service account's unique id). If a provider is wanted
instead, use **Mailgun** or SendGrid. Its API key then lives in **Secret Manager** as
`spry-mail-api-key`, readable only by the report's service account, and is never in the
repository or the image.

## What we would not move, and why

- **Sign-in (Cognito).** Users cannot be moved with their passwords, and Google sign-in would need
  a new OAuth client. It works from Cloud Run unchanged, so moving it buys nothing and makes every
  user with a password reset it.
- **The agenda parser (Bedrock).** It holds no data, so leaving it on AWS adds no latency to
  anything else, and Claude on Vertex AI is not covered by the trial credit. Moving it would only
  be about price (see the Lab 9 report).
- **The weekly report.** It must follow the database eventually (it reads all meetings of the
  week), but it needs a scheduler, a queue, a bucket and e-mail, which is four rows of this table
  for one CSV a week. It is the first stretch goal.

## Consequences

- Spry now runs in two clouds. The browser talks to Firebase/Cloud Run for data, and to Cognito and
  the parser Lambda on AWS. A Cognito outage signs everyone out on both.
- Two workspaces, two bootstraps, two sets of dynamic credentials. `app_urls` in
  `infra/terraform.tfvars` must list the Firebase origins, or Cognito refuses to send users back.
- On GCP the database does not pause. Someone has to run `make gcp-db-stop`, or the instance
  bills $0.25 a day.
