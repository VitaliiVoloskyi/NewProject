"""The agenda-parser Lambda, behind a public function URL: POST {"text", "today", "tz"} with
`Authorization: Bearer <Cognito ID token>` returns {"agenda", "model", "prompt_version"}.

It runs outside the VPC and never touches the database: it only suggests. The browser saves
the agenda through the API, which validates it like any other input. CORS (the allowed sites,
POST only) is configured on the function URL in infra/ai.yml, not here.
"""

import asyncio
import base64
import json
import logging
import time
from datetime import date
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.ai.agenda import (
    MAX_TEXT_CHARS,
    PROMPT_VERSION,
    AgendaParseError,
    ModelUnavailableError,
    cost_usd,
    parse_agenda,
)
from app.auth import InvalidTokenError, TokenVerifier
from app.config import settings

log = logging.getLogger("agenda-parser")
log.setLevel(logging.INFO)

_verifier: TokenVerifier | None = None


def verifier() -> TokenVerifier:
    # Outside the VPC the function can download Cognito's keys itself, on first use.
    global _verifier
    if _verifier is None:
        _verifier = TokenVerifier(settings.cognito_user_pool_id, settings.cognito_client_id)
    return _verifier


def response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def error(status: int, message: str) -> dict[str, Any]:
    return response(status, {"error": message})


def verify_cognito_token(authorization: str) -> dict:
    """The token's claims; raises InvalidTokenError for anything but a valid Cognito ID token."""
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise InvalidTokenError("missing bearer token")
    return asyncio.run(verifier().verify(token))


def read_request(event: dict[str, Any]) -> tuple[str, date, str]:
    """text, today and tz from the JSON body; ValueError if any is missing or malformed."""
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode()
    try:
        body = json.loads(raw)
        text, today, tz = body["text"], date.fromisoformat(body["today"]), body["tz"]
        ZoneInfo(tz)
    except json.JSONDecodeError, KeyError, TypeError, ValueError, ZoneInfoNotFoundError:
        raise ValueError('expected JSON {"text": ..., "today": "YYYY-MM-DD", "tz": ...}') from None
    if not isinstance(text, str) or not text.strip():
        raise ValueError("text is empty")
    return text, today, tz


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    if event.get("requestContext", {}).get("http", {}).get("method", "POST") != "POST":
        return error(405, "Use POST")
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    try:
        claims = verify_cognito_token(headers.get("authorization", ""))
    except InvalidTokenError:
        return error(401, "Sign in to parse an agenda")
    try:
        text, today, tz = read_request(event)
    except ValueError as e:
        return error(400, str(e))
    # Every call costs money: refuse long text before it reaches the model.
    if len(text) > MAX_TEXT_CHARS:
        return error(413, f"The text is too long: at most {MAX_TEXT_CHARS:,} characters")

    started = time.monotonic()
    fields = {
        "user": claims["sub"],
        "model": settings.parser_model,
        "prompt_version": PROMPT_VERSION,
    }
    try:
        agenda, usage = parse_agenda(text, today, tz)
    except AgendaParseError as e:
        log.warning("agenda_parse_failed", extra={**fields, "reason": str(e)})
        return error(422, "No agenda found in this text")
    except ModelUnavailableError as e:
        if e.throttled:
            # Bedrock's quota is used up, even after the SDK's retries with back-off.
            log.warning("agenda_parse_throttled", extra=fields)
            return error(429, "The AI service is busy; try again in a minute")
        log.error("agenda_parse_error", extra={**fields, "reason": str(e)})
        return error(502, "The AI service is not available right now")

    log.info(
        "agenda_parsed",
        extra={
            **fields,
            **usage,
            "chars": len(text),
            "items": len(agenda.items),
            "latency_ms": int((time.monotonic() - started) * 1000),
            "cost_usd": cost_usd(settings.parser_model, usage),
        },
    )
    return response(
        200,
        {
            "agenda": agenda.model_dump(mode="json"),
            "model": settings.parser_model,
            "prompt_version": PROMPT_VERSION,
        },
    )
