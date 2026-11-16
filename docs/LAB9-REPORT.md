# Lab 9: Spry on Google Cloud (submission)

| What | Where |
|---|---|
| `gcp/` Terraform + ADR | `gcp/*.tf`, `gcp/bootstrap/main.tf`, [ADR 0008](adr/0008-google-cloud.md), pull request: <https://github.com/VitaliiVoloskyi/NewProject/pull/3> |
| Spry on Google Cloud | <https://spry-voloskyi-2026-app.web.app> · `/api/health` reads the database (`SELECT 1` on Cloud SQL) |
| Cost table | Part 3 below |
| Demo screenshots | `lab9/screenshots/`: BigQuery, Looker Studio, OCR |

## Part 0: the project

- Free Trial ($300 / 90 days), with a **$5 budget** at 50 / 90 / 100 % before anything else.
- Project **`spry-voloskyi-2026`**, region **us-central1**.
- **Service accounts, one per program, no keys:**
  - `spry-terraform`: what HCP Terraform runs as. Cloud Run Admin, Cloud SQL Admin, Artifact
    Registry Administrator, Secret Manager Admin, Service Usage Admin, Firebase Hosting Admin, and
    Service Account User **only on `spry-api`**, not on the project. That last one means it can
    deploy a service that runs as `spry-api`, but cannot act as any other account.
  - `spry-api`: what the Cloud Run service runs as. Cloud SQL Client, and Secret Accessor on the
    one secret it reads.
- **Workload Identity Federation** (`gcp/bootstrap`): pool `hcp-terraform`, OIDC provider for
  `https://app.terraform.io`. The attribute condition admits only our organization and workspace
  `spry-gcp` by their immutable ids (`org-…`, `ws-…`), and only that workspace's principal set
  has Workload Identity User on `spry-terraform`. The laptop uses my own login (application
  default credentials). Nothing secret is stored anywhere.

## Part 1: service choices

In [ADR 0008](adr/0008-google-cloud.md). In short:

- **Replaced:** S3 + CloudFront → Firebase Hosting, Lambda → Cloud Run, ECR → Artifact Registry,
  RDS → Cloud SQL, SSM → Secret Manager, CloudWatch → Cloud Logging, IAM roles → service accounts,
  `aws` → `google` provider in a second workspace.
- **Kept on AWS:** Cognito (users can't be moved with their passwords, and the API verifies
  Cognito tokens from anywhere), the Bedrock agenda parser (it holds no data, and the trial credit
  doesn't pay for Claude on Vertex), and the weekly report with SES.
- **Database:** Cloud SQL, stopped when unused. No code changes; about $1.90–3.60 a month for
  class use. Firestore would be $0 but means rewriting the data layer. Leaving RDS on AWS adds
  100–200 ms per request and opens a private database.
- **E-mail:** SES stays. When the report moves, Cloud Run calls SES through an AWS role federated
  to the service account's Google identity, with no key. A Mailgun key, if used, would live in
  Secret Manager.

## Part 2: what moved and how

| Step | What was done |
|---|---|
| Terraform | `gcp/`, workspace `spry-gcp`, `google` + `google-beta` providers, APIs enabled by `google_project_service` |
| Database | `spry-db`: PostgreSQL 17, db-f1-micro (Enterprise edition), 10 GB SSD, public IP with no authorized networks, `ENCRYPTED_ONLY`. Database `meetings`, user `meetings`. The password comes from `random_password`, and the full `DATABASE_URL` is in Secret Manager |
| Data | **Migrations**, not `pg_dump`. RDS has no public endpoint and holds only test data. `alembic upgrade head` runs at container start |
| API | `backend/Dockerfile` target `cloudrun`: the same `app` stage without the Lambda Web Adapter, uvicorn on `$PORT`. Runs as `spry-api`, Cloud SQL socket mounted at `/cloudsql`, `DATABASE_URL` from Secret Manager, min 0 / max 2 instances, pool 4 + 4 (db-f1-micro allows ~25 connections). Public (`invoker_iam_disabled`), because every route but `/api/health` checks a Cognito ID token |
| Frontend | Firebase Hosting site `spry-voloskyi-2026-app`. `/api/**` is rewritten to Cloud Run, so there is one origin and no CORS. The build uses `VITE_API_URL=""`, the Cognito ids from `.env`, and the parser URL on AWS |
| AWS change | The two Firebase origins were added to `app_urls` (`infra/terraform.tfvars`), so Cognito redirects back to them and the parser accepts their calls |
| Local test | The `cloudrun` image ran against PostgreSQL 17 over a Unix socket at `/cloudsql/<connection name>`, as on Cloud Run: migrations applied, `/api/health` → `{"status":"ok"}`, `/api/meetings` → 401 without a token |

## Part 3: the minimal setup on both clouds, and what it costs

List prices from 5 November 2026: AWS us-east-1, GCP us-central1, 730 h a month, no tax. Spry's
AWS side is **RDS db.t4g.micro** ($0.016/h, 20 GB gp2 at $0.115), not Aurora: free-plan accounts
cannot create Aurora from CloudFormation (Lab 4). Free-tier assumptions are listed under the table.

### Nobody using it for a month

| Piece | AWS (as deployed) | Google Cloud (this lab) |
|---|---|---|
| Frontend + CDN + HTTPS | CloudFront Free plan → $0 | Firebase Hosting free quota → $0 |
| API | Lambda, idle → $0 | Cloud Run, scaled to zero → $0 |
| Database compute | RDS db.t4g.micro running → **$11.68** | Cloud SQL db-f1-micro running → **$7.67** |
| Database storage | 20 GB gp2 → $2.30 | 10 GB SSD → $1.70 |
| Registry, secrets, logs | ECR ~0.3 GB → $0.03, SSM free, logs ~$0.05 | within the free tier (0.5 GB registry, 6 secret versions, 50 GiB logs) |
| **Total** | **≈ $14.06** | **≈ $9.37**, or **$1.70** with the instance stopped |

### The four traffic profiles

Assumptions: an API request takes 100 ms. Lambda has 512 MB. Cloud Run has 1 vCPU and 512 MiB,
request-based billing and concurrency 80, so busy time is `hours × (1 − e^(−rate × 0.1 s))`. A
response is 5 KB.

| Profile | Requests / month | AWS API (Lambda) | GCP API (Cloud Run) | AWS DB on 24/7 | GCP DB on 24/7 | AWS DB stopped when idle | GCP DB stopped when idle |
|---|---|---|---|---|---|---|---|
| Nobody | 0 | $0 | $0 | $13.98 | $9.37 | $2.30¹ | $1.70 |
| Class demos (10 × 2 h, 1 req/s) | 72 k | $0 (in free tier) | $0 (in free tier) | $13.98 | $9.37 | $2.62 | $1.91 |
| Office hours (8 h × 22 d, 2 req/s) | 1.27 M | $0.05 | $0 (115 k vCPU-s < 180 k free) | $13.98 | $9.37 | $5.12 | $3.55 |
| Busy, around the clock (10 req/s) | 26.3 M | **$20.29**² | **$46.44**³ | $13.98 | $9.37 | n/a (always on) | n/a |

| Totals (DB on 24/7) | AWS | GCP | Cheaper | Deciding line |
|---|---|---|---|---|
| Nobody | $14.06 | $9.37 | **GCP** | database compute ($11.68 vs $7.67) |
| Class demos | $14.06 | $9.37 | **GCP** | database compute |
| Office hours | $14.11 | $9.37 | **GCP** | database compute |
| Busy | $37.14⁴ | $73.87⁴ | **AWS** | API compute, then egress |

With the database stopped when idle, GCP is cheaper for the first three profiles too: $1.70 /
$1.91 / $3.55 against $2.33 / $2.70 / $5.20. On both clouds the **database line** decides every
profile except "busy".

1. RDS can be stopped for at most 7 days. Then AWS starts it again by itself, so "nobody" means
   stopping it every week or deleting it. Cloud SQL stays stopped.
2. Lambda: (26.3 M − 1 M free) × $0.20/M = $5.06, plus 1.31 M GB-s − 0.4 M free = 0.91 M ×
   $0.0000166667 = $15.23.
3. Cloud Run: busy time 2.628 M s × 0.632 = 1.66 M s. vCPU (1.66 M − 180 k) × $0.000024 = $35.55,
   memory (0.83 M − 360 k GiB-s) × $0.0000025 = $1.18, requests (26.3 M − 2 M) × $0.40/M = $9.71.
   Request-based billing charges a whole vCPU per busy instance, where Lambda's 512 MB is about
   0.3 vCPU. Instance-based billing (1 instance, CPU always on) would be ≈ $50 with no request fee.
4. Plus egress: 26.3 M × 5 KB = 131 GB. AWS: the function URL serves it directly (100 GB a month
   free, then $0.09/GB) → $2.79. GCP: it goes through the Firebase rewrite at $0.15/GB after
   360 MB a day → $18.06.

Free-tier assumptions used: Lambda 1 M requests + 400 k GB-s a month (always free). Cloud Run
2 M requests, 180 k vCPU-s, 360 k GiB-s. CloudFront flat-rate Free plan. Firebase Hosting 10 GB
stored / 360 MB a day. Artifact Registry 0.5 GB. Secret Manager 6 versions / 10 k accesses.
Cloud Logging 50 GiB. **No** 12-month RDS free tier and **no** $300 trial credit, which hide both
database lines for a while but end.

**The trap on the GCP side.** On AWS, Aurora costs more than an instance if something keeps it
awake. On GCP:

- **Cloud SQL never sleeps.** The trap is forgetting to stop it, and a stopped instance still
  bills its disk.
- **Cloud Run with instance-based billing** (`cpu_idle = false`) or **min instances ≥ 1**. An
  uptime check or a frontend poll every few minutes keeps an instance billed around the clock:
  1 vCPU + 512 MiB ≈ $50 a month for an app nobody uses. With request-based billing, the same
  pings cost almost nothing. The setting decides it, not the traffic.
- **Firestore, if chosen.** The bill follows the code. A list page that reads 500 documents spends
  the 50 k free reads after 100 visits, and a `refetchInterval` (Spry has none:
  `refetchOnWindowFocus: false`) would multiply it.

## Part 4: what else Google Cloud is good at

### Demos (screenshots in `lab9/screenshots/`)

| Demo | How | Result |
|---|---|---|
| **BigQuery** | `lab9/bigquery_payments.sql`: trips and money per payment type, Chicago taxi trips 2023 (public dataset, sandbox). The Lab 8 question on other data | **7.01 GB** processed (dry run: 7,007,864,543 bytes). Four columns of a ~75 GB table, because only the columns named are read. $0 within the free 1 TiB a month, ≈ $0.04 at $6.25/TiB beyond it |
| **Looker Studio** | `lab9/bigquery_for_looker.sql` creates `spry_lab9.taxi_payments_monthly`. Looker Studio → BigQuery source → time series: month × trips, breakdown by `payment_type` | `looker.png` |
| **Document AI / Vision OCR** | Document AI → Create processor → **Enterprise Document OCR** (us) → upload one PDF (a receipt or a handwritten page) | `ocr.png` |
| Gemini on Vertex AI (optional) | Vertex AI Studio → the Lab 6 agenda prompt (`backend/app/ai/agenda.py`) with one test input | |

### When a specialised service beats a general model

**Document AI is better** when the input is a *document* and the output is *what is printed on
it*: scanned PDFs, receipts, forms, tables, handwriting. It returns text with coordinates and
confidence per word, key-value pairs and table cells, and the price is per page ($1.50 per 1,000
for OCR). The result is the same every time and can be checked against the page. An LLM reading
the same scan costs more per page, can "fix" or invent text, and gives no coordinates.

**A general model is better** when the job is *understanding*, not reading. Lab 6's agenda parser
gets free text from chat and email in two languages, resolves "Monday" against today, guesses
owners and durations, and returns our own JSON schema. No pretrained processor knows that schema.
A custom Document AI extractor would need labelled examples and still couldn't reason about
relative dates. The two combine well: Document AI OCR for a photographed agenda, then the LLM on
the text.

### Lab 8 on Google Cloud

| Lab 8 on AWS | Here | No longer managed |
|---|---|---|
| S3 `payments/dt=…/` JSON | Cloud Storage, or loaded straight into BigQuery | |
| Glue table / Crawler, `MSCK REPAIR` | BigQuery table (or an external table over GCS) with schema auto-detect, partitioned by `dt` | partitions are not registered by hand. No crawler |
| Athena SQL, CTAS → Parquet | **BigQuery SQL**: storage is columnar already, so there is no Parquet step | file formats, the scanned-data-vs-format trade-off (still billed per bytes scanned, so `SELECT` few columns and use partition filters) |
| The dedup view (`row_number()`) | same SQL, or a scheduled query into a deduplicated table | |
| Redpanda + Python consumer, windows, watermarks (Part 3); SQS + Lambda (Part 4) | **Dataflow** (Beam): one pipeline for batch and streaming, event-time windows, watermarks, allowed lateness, exactly-once into BigQuery; Pub/Sub as the log | the consumer, its checkpoints, the `seen` set, scaling consumers per partition |
| (QuickSight, not used) | **Looker Studio** over BigQuery, free | |

### Veo, Looker, Airflow (in class)

An 8-second Veo clip costs $0.40 (Lite, 720p) to $3.20 (Veo 3.1 with audio). A dozen tries for one
usable clip is $5–40, which is why it is not a student demo. A small Airflow environment
(Managed Service for Apache Airflow, or MWAA at $0.49/h ≈ $358 a month) costs more than everything
else in this lab together.

## Part 5: certifications

The closest fit is **Associate Cloud Engineer** ($125): Parts 0–2 are its syllabus (projects, IAM,
service accounts, Cloud Run, Cloud SQL, Terraform). **Associate Data Practitioner** fits Lab 8
and Part 4. For the course bonus (+10), the **OCI Multicloud Architect Associate** costs nothing
through the Bridge program. Any other certification needs the lecturer's written approval first.

## Clean up

`make gcp-db-stop` after every session. At the end: a destroy run in `spry-gcp`,
`terraform -chdir=gcp/bootstrap destroy`, delete the dataset `spry_lab9` and the Document AI
processor, remove the Firebase origins from `app_urls`, and check Billing → Reports a day later.
Steps: [DEPLOY-GCP.md](DEPLOY-GCP.md#clean-up).
