-include .env

COMPOSE := docker compose
DB_PORT ?= 5432
LOCAL_DATABASE_URL := $(subst @db:5432,@localhost:$(DB_PORT),$(DATABASE_URL))
s ?=

.DEFAULT_GOAL := help
.PHONY: help env build up down restart logs ps migrate migration seed psql test lint format \
	dev-backend dev-frontend install clean deploy deploy-backend deploy-frontend deploy-ci \
	add-domain remove-domain destroy destroy-backend destroy-frontend infra-lint infra-init infra-plan \
	infra-output auth-env deploy-functions verify-recipients report-local report-now report-logs \
	llm-hello parse parse-eval parser-logs

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(firstword $(MAKEFILE_LIST)) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from .env.example if missing
	@test -f .env || (cp .env.example .env && echo "Created .env")

build: env ## Build all images
	$(COMPOSE) build

up: env ## Build and start the whole stack
	$(COMPOSE) up -d --build
	@echo "App:      http://localhost:3000"
	@echo "API docs: http://localhost:8000/api/docs"

down: ## Stop the stack
	$(COMPOSE) down

restart: down up ## Restart the stack

logs: ## Follow logs (optionally: make logs s=backend)
	$(COMPOSE) logs -f $(s)

ps: ## Show running services
	$(COMPOSE) ps

migrate: ## Apply database migrations
	$(COMPOSE) exec backend alembic upgrade head

migration: ## Generate a migration: make migration m="add something" (db must be up)
	@test -n "$(m)" || (echo 'Usage: make migration m="message"' && exit 1)
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run alembic revision --autogenerate -m "$(m)"

seed: ## Insert sample participants and meetings
	$(COMPOSE) exec backend python -m app.seed

psql: ## Open psql in the db container
	$(COMPOSE) exec db psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

test: env ## Run backend tests locally against the <db>_test database (db runs in Docker)
	$(COMPOSE) up -d --wait db
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run pytest -v

lint: ## Lint backend and frontend
	cd backend && uv run ruff check . && uv run ruff format --check .
	cd frontend && npm run lint && npx prettier --check .

format: ## Format backend and frontend
	cd backend && uv run ruff check --fix . && uv run ruff format .
	cd frontend && npm run format

install: ## Install local dev dependencies (uv + npm)
	cd backend && uv sync
	cd frontend && npm install

dev-backend: env ## Run backend locally with reload (db runs in Docker)
	$(COMPOSE) up -d db
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run alembic upgrade head
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) CORS_ORIGINS="$(CORS_ORIGINS)" \
		COGNITO_USER_POOL_ID="$(COGNITO_USER_POOL_ID)" COGNITO_CLIENT_ID="$(COGNITO_CLIENT_ID)" \
		uv run uvicorn app.main:app --reload --port 8000

dev-frontend: ## Run Vite dev server on http://localhost:5173 (proxies /api to :8000)
	cd frontend && npm run dev

report-local: env ## Print a week's report CSV from the local database: make report-local WEEK=2026-W40
	$(COMPOSE) up -d --wait db
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run python -m app.reports.weekly $(WEEK)

llm-hello: env ## Ask Claude on Bedrock one question; prints the answer, stop_reason and usage
	@$(AWS_ENV) bash -c 'source infra/common.sh; cd backend && uv run python -m app.ai.hello'

parse: env ## Parse an agenda with Claude on Bedrock: make parse TEXT="Mon 10:00, pricing sync..."
	@$(AWS_ENV) TEXT="$(TEXT)" bash -c 'source infra/common.sh; \
		cd backend && uv run python -m app.ai.agenda "$$TEXT"'

clean: ## Stop the stack and delete the database volume
	$(COMPOSE) down -v

# AWS settings come from .env locally and from repository variables in GitHub Actions.
# Credentials never do: the AWS CLI uses your `aws configure` profile, CI an OIDC role.
AWS_ENV := AWS_REGION="$(AWS_REGION)" AWS_PROFILE="$(AWS_PROFILE)" \
	PROJECT_NAME="$(or $(PROJECT_NAME),$(APP_NAME))" CORS_ORIGINS_AWS="$(CORS_ORIGINS_AWS)" \
	LAMBDA_MEMORY="$(LAMBDA_MEMORY)" DOMAIN_NAME="$(DOMAIN_NAME)" HOSTED_ZONE_ID="$(HOSTED_ZONE_ID)" \
	GITHUB_REPO="$(GITHUB_REPO)" REPORTS_RECIPIENTS="$(REPORTS_RECIPIENTS)" \
	PARSER_MODEL="$(PARSER_MODEL)" WEEK="$(WEEK)"

# Cognito, the weekly report and the agenda parser are Terraform in infra/*.tf. Their state and
# runs live in HCP Terraform: a pull request gets a plan, a merge to main applies it. There is
# no apply target on purpose. The targets below need an HCP Terraform token (`terraform login`).
TF := terraform -chdir=infra

infra-init: ## Connect infra/ to its HCP Terraform workspace and download the providers
	$(TF) init -input=false

infra-plan: ## Speculative plan of infra/*.tf in HCP Terraform (changes nothing)
	@test -d infra/.terraform || $(TF) init -input=false >/dev/null
	$(TF) plan

infra-output: ## Show the outputs of infra/*.tf (Cognito ids, parser URL, queue, bucket, ...)
	@test -d infra/.terraform || $(TF) init -input=false >/dev/null
	$(TF) output

auth-env: env ## Write the Cognito ids and the parser URL from Terraform's outputs to .env
	@$(AWS_ENV) ./infra/auth-env.sh

# The deploy targets are the contract: GitHub Actions runs exactly these, nothing else.
deploy: deploy-backend deploy-frontend ## Deploy backend (+ builder and parser code), then frontend

deploy-backend: ## Build the image (tag = commit SHA), push to ECR, deploy Lambda + RDS PostgreSQL
	@$(AWS_ENV) ./infra/deploy-backend.sh

deploy-frontend: ## Build the bundle against the Lambda URL, sync to S3, invalidate CloudFront
	@$(AWS_ENV) ./infra/deploy-frontend.sh

deploy-functions: env ## Ship the backend's code to the report builder and the agenda parser
	@$(AWS_ENV) ./infra/deploy-functions.sh

verify-recipients: env ## Send SES verification links to REPORTS_RECIPIENTS (the SES sandbox needs them)
	@$(AWS_ENV) ./infra/verify-recipients.sh

report-now: env ## Build and email a report on demand: make report-now WEEK=2026-W39 (default: last week)
	@$(AWS_ENV) ./infra/report-now.sh

report-logs: env ## Show the last hour of report-builder and report-mailer logs
	@$(AWS_ENV) bash -c 'source infra/common.sh; for f in report-builder report-mailer; do echo "== $$f"; \
		aws logs tail /$${PROJECT_NAME}/$$f --since 1h --format short; done'

parse-eval: env ## Run the five test inputs of the lab; prints table rows (tokens, cost, latency)
	@$(AWS_ENV) bash -c 'source infra/common.sh; cd backend && uv run python -m app.ai.evaluate'

parser-logs: env ## Show the last hour of agenda-parser logs (one JSON line per parse)
	@$(AWS_ENV) bash -c 'source infra/common.sh; aws logs tail /$${PROJECT_NAME}/agenda-parser --since 1h --format short'

deploy-ci: env ## Create the IAM role GitHub Actions assumes via OIDC (once)
	@$(AWS_ENV) ./infra/deploy-ci.sh

add-domain: env ## Attach DOMAIN_NAME from .env to the deployed frontend
	@$(AWS_ENV) ./infra/add-domain.sh

remove-domain: env ## Detach the custom domain and delete its certificate
	@$(AWS_ENV) ./infra/remove-domain.sh

destroy-backend: env ## Delete the AWS backend stacks (keeps a final DB snapshot)
	@$(AWS_ENV) ./infra/destroy-backend.sh

destroy-frontend: env ## Delete the S3 bucket, CloudFront distribution and domain certificate
	@$(AWS_ENV) ./infra/destroy-frontend.sh

# Terraform's resources are destroyed in HCP Terraform (a destroy run), not from here.
destroy: destroy-frontend destroy-backend ## Delete frontend and backend (destroy infra/*.tf first)

infra-lint: ## Lint the CloudFormation templates and the Terraform files
	uvx cfn-lint infra/*.yaml
	terraform fmt -check -recursive infra
	$(TF) init -backend=false -input=false >/dev/null && $(TF) validate
