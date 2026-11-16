# Deploy Spry's core to Google Cloud

```
https://<project>-app.web.app  ->  Firebase Hosting (React bundle, CDN, HTTPS)
                               ->  /api/**  rewrite  ->  Cloud Run spry-api (FastAPI, scales to 0)
                                                         -> Cloud SQL PostgreSQL 17 db-f1-micro
                                                            (connector over IAM, password in Secret Manager)
still on AWS:  Cognito sign-in · agenda parser (Bedrock) · weekly report (SES)
HCP Terraform workspace spry-gcp  --WIF, no keys-->  Google Cloud (gcp/*.tf)
```

Why these services: [ADR 0008](adr/0008-google-cloud.md). What it costs: [LAB9-REPORT.md](LAB9-REPORT.md).

## 0. Tools and login (once)

```sh
curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts && exec -l $SHELL
gcloud auth login                        # the CLI, as you
gcloud auth application-default login    # Terraform and firebase-tools, as you
```

No service account key is ever downloaded: on the laptop you are yourself, and HCP Terraform
uses Workload Identity Federation.

## 1. Account, budget, project (console, once)

1. Start the Free Trial ($300 for 90 days) at <https://console.cloud.google.com>.
2. **Billing → Budgets & alerts → Create budget**: $5 a month, thresholds 50 / 90 / 100 %.
   This only sends e-mails. It does not stop anything.
3. Create the project **`spry-voloskyi-2026`** and link the trial billing account. The ID is
   permanent and can never be reused. If it is taken, pick another and change it in
   `gcp/terraform.tfvars` (`project_id`) and in `infra/terraform.tfvars` (the two Firebase URLs
   in `app_urls`).

```sh
gcloud config set project spry-voloskyi-2026
gcloud auth application-default set-quota-project spry-voloskyi-2026
```

## 2. The HCP Terraform workspace (once)

In app.terraform.io, organization `ooad-voloskyi`: **New workspace → Version control workflow**,
the same repository, workspace name **`spry-gcp`**, **Working directory `gcp`**, and under
Settings → General **Auto-apply: on** (a merge to `main` applies). Note two immutable ids:

- the workspace id, `ws-…` (workspace → Settings → General → ID)
- the organization id, `org-…` (Organization settings → General → ID)

## 3. Bootstrap: service accounts and Workload Identity Federation (laptop, once)

```sh
terraform -chdir=gcp/bootstrap init
terraform -chdir=gcp/bootstrap apply \
  -var project_id=spry-voloskyi-2026 -var tfc_organization_id=org-XXXX -var tfc_workspace_id=ws-XXXX
```

It enables the IAM, STS and Firebase APIs, adds Firebase to the project, and creates
`spry-terraform` (the roles `gcp/*.tf` needs, no Owner or Editor) and `spry-api` (Cloud SQL
Client). It also creates the pool `hcp-terraform`, which admits only that workspace. Copy the
`workspace_env` output into the workspace as **environment variables**:

| Key | Value |
|---|---|
| `TFC_GCP_PROVIDER_AUTH` | `true` |
| `TFC_GCP_RUN_SERVICE_ACCOUNT_EMAIL` | `spry-terraform@<project>.iam.gserviceaccount.com` |
| `TFC_GCP_WORKLOAD_PROVIDER_NAME` | `projects/<number>/locations/global/workloadIdentityPools/hcp-terraform/providers/app-terraform-io` |

The state of the bootstrap stays local and gitignored, like `infra/bootstrap`.

## 4. The infrastructure: pull request → plan, merge → apply

`gcp/*.tf` is applied by HCP Terraform, never from a laptop. A pull request that touches `gcp/` gets a
plan from `spry-gcp` as a check. Merging applies it: the APIs, the Artifact Registry repository,
Cloud SQL (about 10 minutes the first time), the secret, the Cloud Run service (on a placeholder
image) and the Firebase site. `make gcp-plan` runs a speculative plan from the laptop
(`terraform login` first).

The same pull request adds the Firebase origins to `app_urls` in `infra/terraform.tfvars`, so
`spry-dev` lets Cognito redirect back to them and the parser accept calls from them.

## 5. The code

```sh
make gcp-deploy-backend    # docker build --target cloudrun, push to Artifact Registry, update Cloud Run
make gcp-deploy-frontend   # npm run build with the Cognito ids from .env, firebase deploy
```

The container runs `alembic upgrade head` before uvicorn, so the first start creates the schema
in the empty database. The data was not copied from RDS (`pg_dump`), because RDS has no public
endpoint and holds only test data. Users appear again on first sign-in, keyed by the same
Cognito `sub`.

Check: open `https://spry-voloskyi-2026-app.web.app` in a private window, sign in, create a
meeting, reload. `/api/health` runs `SELECT 1` on Cloud SQL without signing in.

## Stop the database (every evening)

```sh
make gcp-db-stop     # compute stops billing ($0.25/day); the 10 GB SSD still bills ($1.70/month)
make gcp-db-start    # 1–2 minutes; the API fails until it is up
```

## Clean up

1. HCP Terraform → `spry-gcp` → Settings → Destruction and Deletion → **Queue destroy plan**,
   confirm. This deletes Cloud SQL, Cloud Run, the registry, the secret and the site.
2. `terraform -chdir=gcp/bootstrap destroy -var …` (the service accounts and the pool).
3. Remove the two Firebase URLs from `app_urls` (pull request).
4. Delete the BigQuery dataset `spry_lab9` and the Document AI processor. After a day, check
   **Billing → Reports**. Shutting down the project (IAM & Admin → Settings) removes
   everything at once.
