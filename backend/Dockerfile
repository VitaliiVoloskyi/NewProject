# Two targets from one build:
#   app (--target app)  the code and dependencies; the report-builder Lambda runs it with a
#                       plain Python handler (ImageConfig in infra/reports.yaml)
#   api (default)       app + the Lambda Web Adapter, which serves the unchanged uvicorn app on
#                       Lambda. The builder cannot use this one: the adapter is an extension that
#                       starts in every container of the image and takes the invocations itself.
FROM python:3.14-slim AS app

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-install-project

COPY . .

# On Lambda, the runtime interface client calls the handler named by the function's
# ImageConfig Command, e.g. app.reports.lambda_handler.handler.
ENTRYPOINT ["python", "-m", "awslambdaric"]
CMD ["app.reports.lambda_handler.handler"]

FROM app AS api

# Lets the unchanged uvicorn app run on AWS Lambda; inert everywhere else.
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter

EXPOSE 8000
ENTRYPOINT []
CMD ["sh", "-c", "alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 8000"]
