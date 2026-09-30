# Deploying Spry to AWS

This takes the app that runs on your laptop (`make up`) and puts it on AWS behind your own
domain, then makes every push to `main` deploy itself.

```
                       ┌──────────────────────────── AWS (one region, e.g. us-east-1) ─────────────────────────────┐
browser ── app.<domain> ──► CloudFront ──► S3 bucket (private)                                                     │
        │               (HTTPS, cert in us-east-1)                                                                  │
        └─ api.<domain> ──► Application Load Balancer ──► ECS Fargate task(s) ──► RDS PostgreSQL 17 (private subnets)
                        (HTTPS :443, :80 → 301)        (image from ECR, tag = commit SHA)                          │
                       └────────────────────────────────────────────────────────────────────────────────────────────┘
GitHub push to main ──► lint + tests ──► OIDC → temporary role ──► make deploy-backend && make deploy-frontend
```

| Piece | Why it is there |
|---|---|
| **S3** | Stores the built frontend (static files). Private: nobody can read it directly. |
| **CloudFront** | Serves those files from edge locations, terminates HTTPS with your certificate, and is the only thing allowed to read the bucket. |
| **ECR** | The registry: stores backend images, one per commit SHA. |
| **ECS Fargate** | Runs the backend container without you managing servers. |
| **ALB** | A stable address in front of containers that come and go; its health check replaces a container that stops answering. |
| **RDS** | Managed PostgreSQL in private subnets; only the backend's security group can connect. |
| **ACM** | Free TLS certificates, issued once a DNS record proves you own the domain. |
| **Cognito** | User accounts (sign up / sign in). Already part of this repo. |

## 0. What it costs

Roughly **$1.5–2 per day** while the backend is up (approximate us-east-1 prices, check the
[pricing pages](https://aws.amazon.com/pricing/) for your region): the load balancer (~$0.55/day),
Fargate 0.25 vCPU / 0.5 GB (~$0.30/day), RDS db.t4g.micro (~$0.40/day, free-tier eligible on
older accounts), and public IPv4 addresses ($0.005/hour each; the ALB uses two, the task one).
CloudFront, S3, ECR and Cognito are pennies or free at this size. A Route 53 hosted zone is
$0.50/month. **Run `make destroy` when the lab is graded.** Set a budget alert first:
Billing → Budgets → Create budget → "Zero spend" or e.g. $10.

## 1. One-time setup on your machine

You need: **Docker** (running), **Node.js 24**, **uv**, **git**, and **AWS CLI v2**
(`aws --version`; install from <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html>).

### Your repository

The lab wants your own copy, not the course repository:

```sh
# on GitHub: create an empty repository, e.g. <you>/spry (no README)
git remote rename origin upstream
git remote add origin https://github.com/<you>/spry.git
git push -u origin main
```

If it is private: Settings → Collaborators → add the lecturer.

### AWS account and credentials

1. Create the AWS account. Sign in as **root** once, then: top-right menu → *Security credentials* → **Assign MFA device**.
2. IAM → Users → **Create user** (e.g. `vitalii`). Attach the policy **AdministratorAccess** (fine for a personal lab account; this is *your* user, CI gets its own narrower role later). Enable console access if you like.
3. That user → *Security credentials* → **Create access key** → "Command Line Interface".
4. On your machine:

   ```sh
   aws configure
   # AWS Access Key ID:     <from step 3>
   # AWS Secret Access Key: <from step 3>
   # Default region name:   us-east-1
   # Default output format: json
   aws sts get-caller-identity   # should print your user's ARN, not root
   ```

   The keys live in `~/.aws/credentials`, **never** in the repository. `.env` has no key fields
   any more; the deploy scripts use this profile.
5. Stop using root.

### A domain

You need one domain; the app uses two names in it: `app.<domain>` and `api.<domain>`.

- **Easiest: buy it in Route 53** (Route 53 → Registered domains → Register; cheap TLDs like
  `.click` or `.link` are a few dollars a year). A hosted zone is created for you; copy its
  **Hosted zone ID** (e.g. `Z0123456789ABC`) — then every DNS record below is created automatically.
- **Elsewhere** (Namecheap, Cloudflare, …; students get a free `.me` via the GitHub Student
  Developer Pack): leave `HOSTED_ZONE_ID` empty. The scripts print the exact CNAME records to add
  at your provider. On Cloudflare, set these records to **DNS only** (grey cloud), not proxied.

## 2. Configure

```sh
make env          # creates .env from .env.example (skip if you already have one)
```

Edit `.env` — the AWS part:

```sh
AWS_REGION=us-east-1
PROJECT_NAME=spry                 # prefix for every stack and resource
APP_DOMAIN=app.example.com
API_DOMAIN=api.example.com
HOSTED_ZONE_ID=Z0123456789ABC     # empty if the DNS is not in Route 53
GITHUB_REPO=<you>/spry
```

If an older `.env` still has `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` lines, delete them.

## 3. Deploy by hand first (`make` is the contract)

CI will later run exactly these targets, so get them working on your machine first — a failed
deploy is much easier to debug here than in a GitHub Actions log.

### 3.1 Sign-in (Cognito), once

```sh
make deploy-auth
```

Creates the user pool and writes `COGNITO_*` ids into `.env` (public ids, not secrets).

### 3.2 Backend

```sh
make deploy-backend
```

What happens (numbered like the script's output):

1. A random database password is stored in SSM Parameter Store (`/spry/db-password`, encrypted).
2. The ECR repository is created.
3. The image is built for `linux/amd64` and pushed as `…/spry-backend:<commit-sha>`.
4. An ACM certificate for `api.<domain>` is requested. **Without Route 53** the script prints a
   record like
   `CNAME  _3f1c….api.example.com.  ->  _9a2b….acm-validations.aws.`
   — add it at your DNS provider; the script waits until ACM sees it (usually 2–10 minutes).
   This first CNAME only **proves you own the domain**.
5. The big stack: VPC, security groups, RDS, the ALB with its target group and health check
   (`GET /api/health` every 15 s), the HTTPS listener (port 80 redirects to 443), the ECS
   cluster, task definition and service. **First run: 10–15 minutes** (RDS is slow to create).
6. It calls `/api/health` through the load balancer until it answers.

Without Route 53 it finally prints the second kind of CNAME — the one that **routes traffic**:

```
CNAME  api.example.com  ->  spry-alb-123456.us-east-1.elb.amazonaws.com
```

Add it, then check (DNS can take a few minutes; don't assume it's broken before this resolves):

```sh
dig +short api.example.com
curl https://api.example.com/api/health      # {"status":"ok"}
```

Open `https://api.example.com/api/docs` — this is your **backend URL** for the submission.

### 3.3 Frontend

```sh
make deploy-frontend
```

Builds the bundle with `VITE_API_URL=https://api.<domain>`, requests the certificate for
`app.<domain>` in **us-east-1** (the only region CloudFront accepts; add its validation CNAME the
same way), creates the bucket and distribution (~5 minutes the first time), uploads the files,
lets the new address call the API (CORS) and **invalidates the CloudFront cache** so visitors get
the new bundle immediately. Without Route 53, add the last printed record:

```
CNAME  app.example.com  ->  d1234abcd.cloudfront.net
```

Open `https://app.example.com` → **Create account** → enter the emailed code → add a meeting →
reload. If it is still there, the whole chain works. Take the **screenshot** for the submission
here. `https://app.example.com` is your **frontend URL**.

> Deployed without a domain? Then the API is `http://<alb>` and the browser blocks the `https://`
> CloudFront page from calling it (mixed content). The domain is part of the lab, so set
> `APP_DOMAIN`/`API_DOMAIN` and re-run both targets.

## 4. CI/CD with GitHub Actions (OIDC, no stored keys)

Two workflows in `.github/workflows/`:

- `lint.yml` — ruff (backend), oxlint + Prettier (frontend). Runs on pull requests, and is
  called by `deploy.yml`.
- `deploy.yml` — on every push to `main`: **lint** and **backend tests** (against a Postgres
  service container) in parallel; only if both pass, **deploy** runs `make deploy-backend` then
  `make deploy-frontend`. The image tag is the commit SHA, so you always know what is running,
  and a rollback is "deploy the previous tag".

### 4.1 Create the role GitHub may assume

```sh
make deploy-ci
```

Creates GitHub's OIDC provider in your account (once per account) and the role
`spry-github-deploy`. Read its trust policy in `infra/github-oidc.yaml` and say what it permits:

```yaml
Principal: { Federated: arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com }
Action: sts:AssumeRoleWithWebIdentity
Condition:
  StringEquals:
    token.actions.githubusercontent.com:aud: sts.amazonaws.com
    token.actions.githubusercontent.com:sub: repo:<you>/spry:ref:refs/heads/main
```

Only a workflow **in your repository, on `main`** can get credentials, and they expire with the
job. With `repo:*` there, any repository on GitHub could deploy into your account.

### 4.2 Repository variables

The command prints them. GitHub → your repo → Settings → Secrets and variables → Actions →
**Variables** tab → New repository variable:

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::<account>:role/spry-github-deploy` |
| `AWS_REGION` | `us-east-1` |
| `PROJECT_NAME` | `spry` |
| `APP_DOMAIN` | `app.example.com` |
| `API_DOMAIN` | `api.example.com` |
| `HOSTED_ZONE_ID` | your zone id, or leave unset |

Variables, not secrets: a role ARN is not a credential. There are no AWS keys in GitHub at all.

### 4.3 Watch it go green — and red

```sh
git commit --allow-empty -m "Trigger deploy" && git push
```

Actions tab → *Deploy*: lint ✓, test ✓, deploy ✓ (a few minutes: ECS starts the new task,
waits until the ALB health check passes, then stops the old one).

Then break it on purpose (the lab asks for this):

```sh
echo "import os" >> backend/app/main.py    # unused import → ruff F401
git commit -am "Fail the linter on purpose" && git push
```

Lint goes red and **deploy never starts**. Revert and push again:
`git revert HEAD && git push`.

## 5. Everyday

| Want to… | Do |
|---|---|
| Deploy | push to `main` (or `make deploy-backend` / `make deploy-frontend` locally) |
| See backend logs | `aws logs tail /spry/backend --follow` |
| See why ECS isn't healthy | ECS console → cluster `spry` → service `backend` → **Events** / **Tasks** (stopped reason) |
| Roll back | Actions → the *Deploy* run of the previous good commit → **Re-run all jobs** (its image tag is still in ECR), or `git revert` + push |
| Open psql | not directly: RDS is private on purpose |

A failing new version rolls itself back: the ECS **deployment circuit breaker** notices the new
task never passes the health check and returns to the previous task definition.

## 6. Tear down

```sh
make destroy          # CloudFront + S3 + app cert, then ECS + ALB + RDS + VPC + ECR + api cert
```

It keeps a **final RDS snapshot** (billed for storage — delete it with the command it prints if
you don't need the data), the SSM password, the Cognito user pool (`make destroy-auth` for the
stack), the CI role (`aws cloudformation delete-stack --stack-name spry-github-oidc`) and your
domain / hosted zone. Check Resource Groups & Tag Editor for anything tagged `PROJECT_NAME=spry`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `The AWS CLI has no working credentials` | `aws configure`, or set `AWS_PROFILE` in `.env` |
| Script sits at "Waiting until ACM sees it" | The validation CNAME is missing or wrong. Copy name and value exactly; on Cloudflare use "DNS only". `dig +short CNAME _3f1c….api.example.com` should print the value. |
| Backend stack rolls back, ECS event "unhealthy" | `aws logs tail /spry/backend` — usually a migration or DB error. Fix, commit, deploy again. |
| App loads but "Could not load meetings" / CORS error | Deploy the frontend after the backend (it adds its address to the API's CORS list), and check `APP_DOMAIN` is exactly the host you open. |
| `exec format error` in ECS logs | The image was built for ARM. The script passes `--platform linux/amd64`; don't build it by hand without that. |
| Deploy job: "Not authorized to perform sts:AssumeRoleWithWebIdentity" | `GITHUB_REPO` in `.env` didn't match the repository (case matters) or the push wasn't to `main`. Fix and `make deploy-ci` again. |
| Old frontend after deploy | The script invalidates `/*`; hard-reload once (Cmd/Ctrl+Shift+R). |

## For the class discussion

- **Why CloudFront if S3 can serve files?** HTTPS on your own domain (S3 website endpoints are
  HTTP only), caching at edge locations near users, and the bucket stays private (Origin Access
  Control: only this distribution may read it).
- **ECR vs ECS?** ECR stores images (a registry); ECS runs containers (an orchestrator). Separate
  because you build once and run many times, in many places — the same image could go to EKS,
  Lambda or App Runner.
- **What does the health check check?** An HTTP `GET /api/health` from the ALB to each task every
  15 s; the endpoint also runs `SELECT 1`. Three failures → the target is drained, gets no
  traffic, and ECS replaces the task. It proves "process up and DB reachable", not "the app is
  correct".
- **Why a CNAME both to prove ownership and to route?** Both are "this name points at that
  name". ACM asks you to publish a random name only the domain owner can create; routing uses
  the same mechanism to point `api.` at the ALB and `app.` at CloudFront.
- **Leaked access key vs OIDC role?** A key works from anywhere until someone notices and
  deletes it. The OIDC role can only be assumed by a GitHub-signed token for *this* repo and
  *this* branch, and yields credentials that expire in an hour — nothing to steal from `.env` or
  from repository secrets.
- **At 1,000 organisations?** Keep: CloudFront + S3, ECR, ECS behind an ALB (add autoscaling),
  commit-SHA tags, OIDC. Breaks first: the single small RDS instance (connections and CPU) —
  then Multi-AZ, read replicas, connection pooling (RDS Proxy), and tasks moving to private
  subnets behind NAT/VPC endpoints.
