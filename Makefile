-include .env

COMPOSE := docker compose
DB_PORT ?= 5432
LOCAL_DATABASE_URL := $(subst @db:5432,@localhost:$(DB_PORT),$(DATABASE_URL))
s ?=

.DEFAULT_GOAL := help
.PHONY: help env build up down restart logs ps migrate migration seed psql test lint format \
	dev-backend dev-frontend install clean deploy deploy-auth deploy-backend deploy-frontend deploy-ci \
	destroy destroy-auth destroy-backend destroy-frontend infra-lint

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

test: ## Run backend tests (against the <db>_test database)
	$(COMPOSE) exec backend pytest -v

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
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run uvicorn app.main:app --reload --port 8000

dev-frontend: ## Run Vite dev server on http://localhost:5173 (proxies /api to :8000)
	cd frontend && npm run dev

clean: ## Stop the stack and delete the database volume
	$(COMPOSE) down -v

# AWS settings come from .env locally and from repository variables in GitHub Actions.
# Credentials never do: the AWS CLI uses your `aws configure` profile, CI an OIDC role.
AWS_ENV := AWS_REGION="$(AWS_REGION)" AWS_PROFILE="$(AWS_PROFILE)" PROJECT_NAME="$(PROJECT_NAME)" \
	CORS_ORIGINS_AWS="$(CORS_ORIGINS_AWS)" APP_DOMAIN="$(APP_DOMAIN)" API_DOMAIN="$(API_DOMAIN)" \
	HOSTED_ZONE_ID="$(HOSTED_ZONE_ID)" GITHUB_REPO="$(GITHUB_REPO)" \
	GOOGLE_CLIENT_ID="$(GOOGLE_CLIENT_ID)" GOOGLE_CLIENT_SECRET="$(GOOGLE_CLIENT_SECRET)"

# The deploy targets are the contract: GitHub Actions runs exactly these, nothing else.
deploy: deploy-backend deploy-frontend ## Deploy backend, then frontend (after make deploy-auth)

deploy-auth: env ## Deploy Cognito (user pool + app client) and write its ids to .env (once)
	@$(AWS_ENV) ./infra/deploy-auth.sh

deploy-backend: ## Build the image, push it to ECR (tag = commit SHA), roll the ECS service
	@$(AWS_ENV) ./infra/deploy-backend.sh

deploy-frontend: ## Build the bundle, sync it to S3, invalidate CloudFront
	@$(AWS_ENV) ./infra/deploy-frontend.sh

deploy-ci: env ## Create the IAM role GitHub Actions assumes via OIDC (once)
	@$(AWS_ENV) ./infra/deploy-ci.sh

destroy-auth: env ## Delete the Cognito stack (the user pool and its accounts are kept)
	@$(AWS_ENV) ./infra/destroy-auth.sh

destroy-backend: env ## Delete ECS, ALB, RDS (final snapshot kept), VPC, ECR, API certificate
	@$(AWS_ENV) ./infra/destroy-backend.sh

destroy-frontend: env ## Delete the S3 bucket, CloudFront distribution and app certificate
	@$(AWS_ENV) ./infra/destroy-frontend.sh

destroy: destroy-frontend destroy-backend ## Tear down everything that bills by the hour

infra-lint: ## Lint the CloudFormation templates
	uvx cfn-lint infra/*.yaml
