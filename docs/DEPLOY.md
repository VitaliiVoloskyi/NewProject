# Deploying Spry to AWS

The result looks like `https://d1234abcd.cloudfront.net`: a live site anyone can open, with
email and Google sign-in. No domain is needed (you can add one later with `make add-domain`).

```
browser ──► CloudFront (HTTPS, *.cloudfront.net) ──► S3 bucket (private): the React app
   │
   ├──► Lambda function URL (HTTPS) ──► FastAPI in a container ──► RDS PostgreSQL (db.t4g.micro)
   │                                     (image in ECR, tag = commit SHA)      (private subnets)
   └──► Cognito (email + password, "Continue with Google")

GitHub push to main ──► lint + tests ──► OIDC role ──► make deploy-backend && make deploy-frontend
```

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
(step 5), GitHub runs them for you on every push, so you rarely need them locally.

Tools: **Docker** (running), **Node.js 24**, **AWS CLI v2**, `make`, `git`. On Ubuntu:

```sh
sudo apt update && sudo apt install -y make git unzip curl
curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER   # then log out/in
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - && sudo apt install -y nodejs
cd /tmp && curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip \
  && unzip -q awscliv2.zip && sudo ./aws/install
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

## 3. Sign-in: email + Google

### 3.1 Create Cognito

```sh
make deploy-auth
```

It prints and writes `COGNITO_*` into `.env`. Note **COGNITO_DOMAIN**, e.g.
`spry-123456789012.auth.us-east-1.amazoncognito.com` — Google needs it.

(Already created `spry-auth` from PowerShell? That's the same stack; this just updates it.)

### 3.2 Create the Google OAuth client

1. <https://console.cloud.google.com> → create a project (e.g. "Spry").
2. **APIs & Services → OAuth consent screen** (Google Auth Platform): app name "Spry", your
   email as support and developer contact, audience **External**.
   While the app is in **Testing**, only the Google accounts you add under **Test users** can
   sign in. To let anyone sign in, click **Publish app** (with only the basic
   `openid email profile` scopes no Google review is needed).
3. **Clients → Create client → Web application**:
   - **Authorized JavaScript origins:** `https://<COGNITO_DOMAIN>`
   - **Authorized redirect URIs:** `https://<COGNITO_DOMAIN>/oauth2/idpresponse`
4. Copy the **Client ID** and **Client secret** into `.env`:

   ```
   GOOGLE_CLIENT_ID=1234-abc.apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=GOCSPX-...
   ```

5. Apply it:

   ```sh
   make deploy-auth      # now prints "Google sign-in: enabled", sets COGNITO_GOOGLE_ENABLED=true
   ```

`.env` is gitignored; the Google secret goes to AWS (Cognito) and nowhere else. The
"Continue with Google" button shows **Soon** until this step is done; the next frontend build
enables it.

## 4. Deploy

```sh
make deploy-backend     # ~15 min the first time (RDS), then ~2 min
make deploy-frontend    # ~5 min the first time (CloudFront), then ~2 min
```

`deploy-backend`: stores a random DB password in SSM, creates ECR, builds and pushes the image
tagged with the commit SHA, deploys Lambda + RDS in private subnets, waits for
`/api/health`. `deploy-frontend`: builds the bundle against the Lambda URL, creates the bucket
and CloudFront, allows the new address in the API's CORS list and in Cognito's redirect URLs,
uploads, and invalidates the CloudFront cache.

The last lines print your two URLs:

```
App: https://d1234abcd.cloudfront.net          <- frontend URL for the submission
API: https://abc123.lambda-url.us-east-1.on.aws/api   <- backend URL (+ /docs)
```

Open the app → **Create account** (email code) or **Continue with Google** → add a meeting →
reload. Take the submission screenshot.

## 5. CI/CD: deploy on every push (OIDC, no stored keys)

```sh
make deploy-ci
```

It creates a role only **your repository's `main` branch** can assume
(`infra/github-oidc.yaml`), and prints the values to add in GitHub → Settings → Secrets and
variables → Actions → **Variables**: `AWS_ROLE_ARN`, `AWS_REGION`, `PROJECT_NAME`
(and `DOMAIN_NAME` / `HOSTED_ZONE_ID` if you use a domain). These are variables, not secrets —
no AWS keys are stored in GitHub.

Then every push to `main`: lint and backend tests run; only if both pass, the deploy job runs
`make deploy-backend` and `make deploy-frontend`. Watch it in the **Actions** tab.

To see it fail on purpose: add `import os` at the end of `backend/app/main.py`, push, watch
lint go red and deploy never start; then `git revert HEAD && git push`.

## 6. Own domain (optional)

```
DOMAIN_NAME=app.example.com
HOSTED_ZONE_ID=Z0123456789ABC     # only if the domain is in Route 53
```

`make add-domain` requests the certificate (it prints the validation CNAME if the DNS is not in
Route 53), attaches the domain to CloudFront, and adds it to CORS and Cognito.

## 7. Everyday

| Want to… | Do |
|---|---|
| Deploy | push to `main`, or `make deploy-backend` / `make deploy-frontend` |
| Backend logs | `aws logs tail /spry/backend --follow` |
| Roll back | Actions → the *Deploy* run of an earlier commit → **Re-run all jobs** (its image is still in ECR) |
| First request is slow | Lambda cold start (a few seconds) |

## 8. Tear down

```sh
make destroy        # frontend, then backend (keeps a final DB snapshot)
make destroy-auth   # Cognito stack (the user pool itself is kept)
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `The AWS CLI has no working credentials` | `aws configure` in *this* terminal (Ubuntu, WSL and Windows each have their own) |
| Google: `redirect_uri_mismatch` | The redirect URI in Google must be exactly `https://<COGNITO_DOMAIN>/oauth2/idpresponse` |
| Google: "Access blocked / app not verified" | Add your account under Test users, or Publish the app |
| After Google you land on login again | Run `make deploy-frontend` after `make deploy-auth`, so Cognito allows `https://<cloudfront>/login` |
| "Continue with Google" shows **Soon** | `COGNITO_GOOGLE_ENABLED=true` must be in `.env` before the build; rebuild the frontend |
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
