# Deploying Spry to AWS

The result looks like `https://d1234abcd.cloudfront.net`: a live site anyone can open, with
email and Google sign-in. No domain is needed (you can add one later with `make add-domain`).

```
browser ──► CloudFront (HTTPS, *.cloudfront.net) ──► S3 bucket (private): the React app
   │
   ├──► Lambda function URL (HTTPS) ──► FastAPI in a container ──► RDS PostgreSQL (db.t4g.micro)
   │                                     (image in ECR, tag = commit SHA)      (private subnets)
   └──► Cognito (email + password, "Continue with Google")

GitHub push to main  ──► lint + tests ──► OIDC role ──► make deploy-backend && make deploy-frontend
GitHub merge to main ──► HCP Terraform ──► OIDC role ──► plan + apply of infra/*.tf
```

Two roads, two tools. **Terraform** (`infra/*.tf`, state in HCP Terraform) owns Cognito, the
weekly report and the agenda parser. **CloudFormation** (`infra/*.yaml`) still owns the network,
API, database, ECR and site stacks; Terraform reads their outputs with the
`aws_cloudformation_stack` data source. Why: [ADR 0007](adr/0007-terraform.md).

| Piece | Why it is there |
|---|---|
| **S3** | Stores the built frontend. Private: nobody reads it directly. |
| **CloudFront** | Serves the files over HTTPS from edge locations; the only thing allowed to read the bucket. |
| **ECR** | Stores backend images, one per commit SHA. |
| **Lambda** | Runs the backend container only when a request comes in (Lambda Web Adapter lets the unchanged FastAPI app run there). Its **function URL** is a free HTTPS address — that is why no domain is needed. |
| **RDS PostgreSQL** | A small (db.t4g.micro, free-tier eligible) PostgreSQL 17 in private subnets. Free plan accounts can't create Aurora from CloudFormation, so this is a plain instance. |
| **Cognito** | Accounts: email + password, and Google via OAuth. |

**Cost:** small. Lambda has a big free tier; db.t4g.micro is free-tier eligible (on a free
plan account it is paid from your credits, roughly $0.40/day); there is no load balancer or NAT
gateway. Set a budget
alert anyway (Billing → Budgets → $10).

## 0. Where to run the commands

The deploy commands (`make …`) are **bash scripts**. Run them in a Linux terminal: your
**Ubuntu**, **WSL** on Windows, or macOS. Windows PowerShell can't run them. Once CI is set up
(step 6), GitHub runs them for you on every push, so you rarely need them locally.

Tools: **Docker** (running), **Node.js 24**, **AWS CLI v2**, **Terraform 1.10+**, `make`, `git`. On Ubuntu:

```sh
sudo apt update && sudo apt install -y make git unzip curl
curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER   # then log out/in
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - && sudo apt install -y nodejs
cd /tmp && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip \
  && unzip -q awscliv2.zip && sudo ./aws/install
# Terraform: https://developer.hashicorp.com/terraform/install (or OpenTofu, same files)
```

## 1. AWS access (once)

1. AWS account → enable **MFA** on root → stop using root.
2. IAM → Users → **Create user** → attach **AdministratorAccess**.
3. The user → Security credentials → **Create access key** → *Command Line Interface*.
4. `aws configure` (the two keys, `us-east-1`, `json`), then `aws sts get-caller-identity`.

The keys stay in `~/.aws/credentials`. Never put them in `.env`, the repository, or GitHub.

## 2. Settings

```sh
make env        # creates .env if it does not exist
nano .env
```

```
AWS_REGION=us-east-1
PROJECT_NAME=spry
GITHUB_REPO=<you>/NewProject
```

## 3. HCP Terraform (once)

1. Sign up at <https://app.terraform.io>, create an organization (here `ooad-voloskyi`;
   yours goes into `infra/versions.tf`) and run `terraform login`.
2. Let HCP Terraform runs reach AWS without keys: apply the bootstrap once, from your laptop.
   It creates an IAM OIDC provider for `app.terraform.io` and a role only the workspace
   `spry-dev` can assume.

   ```sh
   terraform -chdir=infra/bootstrap init
   terraform -chdir=infra/bootstrap apply -var tfc_organization=<your org>
   ```

3. Create the workspace `spry-dev` (Remote execution), and add its **variables**:

   | Key | Kind | Value |
   |---|---|---|
   | `TFC_AWS_PROVIDER_AUTH` | env | `true` |
   | `TFC_AWS_RUN_ROLE_ARN` | env | the bootstrap's `role_arn` output |
   | `google_client_secret` | terraform, **sensitive** | the Google client secret (step 4.2), or empty |
   | `report_recipients` | terraform | who gets the weekly report |
   | `budget_email` | terraform | where the $5 budget alarm goes, or empty |

   Everything else (project name, allowed origins, Google client id, model) is in
   `infra/terraform.tfvars`, in Git.
4. Settings → **Version Control**: connect the workspace to this GitHub repository, branch
   `main`, working directory `infra`. Now every pull request gets a plan as a check, and every
   merge to `main` applies it.

The order for a new environment: `make deploy-backend` needs Cognito, and `reports.tf` needs the
backend's network. So the first run applies Cognito alone (HCP Terraform: **New run**, with
`-target` resources `aws_cognito_user_pool_client.web` and `aws_cognito_managed_login_branding.main`),
then `make deploy-backend`, then a full run.

## 4. Sign-in: email + Google

### 4.1 Cognito

Cognito is `infra/auth.tf`, created by HCP Terraform. Write its ids to `.env` for local runs:

```sh
make auth-env
```

Note **COGNITO_DOMAIN**, e.g. `spry-123456789012.auth.us-east-1.amazoncognito.com`: Google needs it.

### 4.2 Create the Google OAuth client

1. <https://console.cloud.google.com> → create a project (e.g. "Spry").
2. **APIs & Services → OAuth consent screen** (Google Auth Platform): app name "Spry", your
   email as support and developer contact, audience **External**.
   While the app is in **Testing**, only the Google accounts you add under **Test users** can
   sign in. To let anyone sign in, click **Publish app** (with only the basic
   `openid email profile` scopes no Google review is needed).
3. **Clients → Create client → Web application**:
   - **Authorized JavaScript origins:** `https://<COGNITO_DOMAIN>`
   - **Authorized redirect URIs:** `https://<COGNITO_DOMAIN>/oauth2/idpresponse`
4. Put the **Client ID** into `google_client_id` in `infra/terraform.tfvars`, and the **Client
   secret** into the workspace variable `google_client_secret` (sensitive).
5. Open a pull request with the tfvars change. The plan shows `+ aws_cognito_identity_provider.google[0]`.
   Merge it, then run `make auth-env` (sets `COGNITO_GOOGLE_ENABLED=true`).

The secret is in three places: the workspace variable (write-only), the Terraform state in HCP
Terraform (encrypted, readable by whoever can read the state), and Cognito itself. Plans print
`(sensitive value)`. Cognito's managed login shows **Continue with Google** from now on; the next
frontend build also shows the app's own Google button on the signed-out page.

## 5. Deploy

```sh
make deploy-backend     # ~15 min the first time (RDS), then ~2 min
make deploy-frontend    # ~5 min the first time (CloudFront), then ~2 min
```

`deploy-backend`: stores a random DB password in SSM, creates ECR, builds and pushes the image
tagged with the commit SHA, deploys Lambda + RDS in private subnets, waits for
`/api/health`, then ships the same code to the report builder and the agenda parser
(`make deploy-functions`). `deploy-frontend`: builds the bundle against the Lambda URL and
Terraform's outputs (Cognito ids, parser URL), creates the bucket and CloudFront, allows the new
address in the API's CORS list, uploads, and invalidates the CloudFront cache. The first time it
prints the new CloudFront address to add to `app_urls` in `infra/terraform.tfvars` (a pull
request), so Cognito redirects back to it and the parser accepts it.

The last lines print your two URLs:

```
App: https://d1234abcd.cloudfront.net          <- frontend URL for the submission
API: https://abc123.lambda-url.us-east-1.on.aws/api   <- backend URL (+ /docs)
```

Open `https://<app>/login/`: it goes straight to Cognito's managed login → **Create an account**
(email code) or **Continue with Google** → back on the site, signed in, with your email in the
sidebar → add a meeting → reload. Try both kinds of sign-in in private windows, with a Google
account that is not one of your test users (proves the Google app is published).

## 6. CI/CD: deploy on every push (OIDC, no stored keys)

```sh
make deploy-ci
```

It creates a role only **your repository's `main` branch** can assume
(`infra/github-oidc.yaml`), and prints the values to add in GitHub → Settings → Secrets and
variables → Actions → **Variables**: `AWS_ROLE_ARN`, `AWS_REGION`, `PROJECT_NAME`
(and `DOMAIN_NAME` / `HOSTED_ZONE_ID` if you use a domain). These are variables, not secrets —
no AWS keys are stored in GitHub. The deploy reads Terraform's outputs (Cognito ids, parser URL)
from HCP Terraform, so it also needs one **secret**, `TF_API_TOKEN`: an HCP Terraform team token
(Organization settings → Teams → API token).

Then every push to `main`: lint and backend tests run; only if both pass, the deploy job runs
`make deploy-backend` and `make deploy-frontend`. Watch it in the **Actions** tab.

To see it fail on purpose: add `import os` at the end of `backend/app/main.py`, push, watch
lint go red and deploy never start; then `git revert HEAD && git push`.

## 7. Own domain (optional)

```
DOMAIN_NAME=app.example.com
HOSTED_ZONE_ID=Z0123456789ABC     # only if the domain is in Route 53
```

`make add-domain` requests the certificate (it prints the validation CNAME if the DNS is not in
Route 53), attaches the domain to CloudFront and adds it to the API's CORS, then reminds you to
add `https://<domain>` to `app_urls` in `infra/terraform.tfvars` (for Cognito and the parser).

## 8. Everyday

| Want to… | Do |
|---|---|
| Deploy code | push to `main`, or `make deploy-backend` / `make deploy-frontend` |
| Change infrastructure | edit `infra/*.tf` or `infra/terraform.tfvars`, pull request, read the plan, merge |
| A change needs both (e.g. a new env var the code reads) | infrastructure first: merge the Terraform PR, wait for the apply, then push the code |
| Backend logs | `aws logs tail /spry/backend --follow` |
| Roll back | Actions → the *Deploy* run of an earlier commit → **Re-run all jobs** (its image is still in ECR) |
| First request is slow | Lambda cold start (a few seconds) |

## 9. Tear down

1. HCP Terraform → `spry-dev` → Settings → Destruction and Deletion → **Queue destroy plan**.
   The user pool and the reports bucket have `prevent_destroy`: remove those lines in a pull
   request first if you really mean to delete every account and every report.
2. `make destroy`: frontend, then backend (keeps a final DB snapshot).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `The AWS CLI has no working credentials` | `aws configure` in *this* terminal (Ubuntu, WSL and Windows each have their own) |
| Google: `redirect_uri_mismatch` | The redirect URI in Google must be exactly `https://<COGNITO_DOMAIN>/oauth2/idpresponse` |
| Google: "Access blocked / app not verified" | Add your account under Test users, or Publish the app |
| Cognito says `redirect_mismatch` | The site's origin is missing from `app_urls` in `infra/terraform.tfvars`; add it in a pull request |
| No **Continue with Google** on Cognito's page | `google_client_id` (tfvars) or `google_client_secret` (workspace) is empty |
| `terraform output`: "Required token could not be found" | `terraform login` (locally), or the `TF_API_TOKEN` secret (CI) |
| HCP Terraform run: "No valid credential sources found" | `TFC_AWS_PROVIDER_AUTH` / `TFC_AWS_RUN_ROLE_ARN` are missing in the workspace, or the bootstrap trusts another organization/workspace |
| Google: "Access blocked" for other people | The Google app is still in **Testing**; publish it (Audience → **Publish app**) |
| Callback page: "No matching state found in storage" | The login started on a copied Cognito URL; start it on `/login/` instead |
| Meetings don't load, CORS error | Deploy the frontend after the backend (it adds its address to CORS) |
| Deploy job: not authorized for AssumeRoleWithWebIdentity | `GITHUB_REPO` did not match the repository, or the push wasn't to `main`; `make deploy-ci` again |

## For the class discussion

The lab text describes ECS + a load balancer. This project runs the **same container image** on
Lambda instead: no servers or load balancer to pay for while idle, and a free HTTPS URL. The
trade-offs: cold starts, a 15-minute request limit, and one
request per instance (so the DB pool is 1). The Dockerfile survives either way; only the
"how it runs" template changes (`infra/backend.yaml`).

- **CloudFront vs S3 alone:** HTTPS, edge caching, and a private bucket.
- **ECR vs Lambda/ECS:** ECR stores images; Lambda/ECS run them.
- **Health check:** the deploy waits for `GET /api/health` (which also runs `SELECT 1`).
- **OIDC vs access key:** a leaked key works from anywhere until deleted; the OIDC role is
  only for GitHub-signed tokens from this repo's `main` and expires within the hour.
