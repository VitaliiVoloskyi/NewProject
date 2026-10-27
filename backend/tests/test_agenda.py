import json
from datetime import date
from types import SimpleNamespace

import pytest
from botocore.exceptions import ClientError
from httpx import AsyncClient

from app.ai import agenda as agenda_module
from app.ai import agenda_lambda
from app.ai.agenda import (
    AgendaParseError,
    ModelUnavailableError,
    ParsedAgenda,
    cost_usd,
    parse_agenda,
)
from app.auth import TokenVerifier
from tests.conftest import CLIENT_ID, JWKS, POOL_ID, make_token
from tests.test_api import meeting_payload

AGENDA = {
    "items": [
        {"topic": "New Pro pricing", "owner": "Олена", "minutes": 15},
        {"topic": "Customer feedback", "owner": "Taras", "minutes": None},
    ],
    "action_items": [{"task": "Compare competitors", "owner": "Taras", "due": "2026-10-30"}],
}
SUGGESTION = {
    "agenda": {"items": [{"topic": "New Pro pricing", "owner": "Olena", "minutes": 15}]},
    "model": "anthropic.claude-opus-5-5",
    "prompt_version": "agenda-v1",
}

# ------------------------------------------------------------------ Saving (the API)


async def make_meeting(client: AsyncClient) -> dict:
    response = await client.post("/api/meetings", json=meeting_payload())
    assert response.status_code == 201, response.text
    return response.json()


async def test_new_meeting_has_no_agenda(client: AsyncClient) -> None:
    assert (await make_meeting(client))["agenda"] is None


async def test_save_agenda_with_ai_suggestion(client: AsyncClient, engine) -> None:
    meeting = await make_meeting(client)

    response = await client.put(
        f"/api/meetings/{meeting['id']}/agenda", json={**AGENDA, "ai_suggestion": SUGGESTION}
    )

    assert response.status_code == 200, response.text
    assert response.json()["agenda"] == AGENDA
    assert (await client.get(f"/api/meetings/{meeting['id']}")).json()["agenda"] == AGENDA
    # The suggestion is stored next to the agenda, but never sent back to the browser.
    assert "agenda_ai_suggestion" not in response.json()
    async with engine.connect() as conn:
        stored = (await conn.exec_driver_sql("SELECT agenda_ai_suggestion FROM meetings")).scalar()
    assert stored == SUGGESTION


async def test_editing_the_meeting_keeps_its_agenda(client: AsyncClient) -> None:
    meeting = await make_meeting(client)
    await client.put(f"/api/meetings/{meeting['id']}/agenda", json=AGENDA)

    response = await client.put(
        f"/api/meetings/{meeting['id']}", json=meeting_payload(title="Renamed")
    )

    assert response.json()["agenda"] == AGENDA


async def test_empty_agenda_removes_it(client: AsyncClient) -> None:
    meeting = await make_meeting(client)
    await client.put(f"/api/meetings/{meeting['id']}/agenda", json=AGENDA)

    response = await client.put(f"/api/meetings/{meeting['id']}/agenda", json={"items": []})

    assert response.json()["agenda"] is None


@pytest.mark.parametrize(
    "agenda",
    [
        {"items": [{"topic": "  "}]},
        {"items": [{"topic": "Pricing", "minutes": 0}]},
        {"items": [{"topic": "Pricing", "minutes": 481}]},
        {"action_items": [{"task": "Compare", "due": "by Friday"}]},
        {"items": [{"topic": "x"}] * 51},
    ],
)
async def test_save_agenda_validation(client: AsyncClient, agenda: dict) -> None:
    meeting = await make_meeting(client)
    response = await client.put(f"/api/meetings/{meeting['id']}/agenda", json=agenda)
    assert response.status_code == 422


async def test_save_agenda_of_someone_elses_meeting(client: AsyncClient) -> None:
    meeting = await make_meeting(client)
    response = await client.put(
        f"/api/meetings/{meeting['id']}/agenda",
        json=AGENDA,
        headers={"Authorization": f"Bearer {make_token('bob')}"},
    )
    assert response.status_code == 404


# ------------------------------------------------------------------ The parser (model faked)

VALID = {"items": [{"topic": "Pricing", "owner": "Olena", "minutes": 15}], "language": "en"}


def message(*blocks, stop_reason: str = "tool_use") -> SimpleNamespace:
    return SimpleNamespace(
        content=list(blocks),
        stop_reason=stop_reason,
        usage=SimpleNamespace(input_tokens=1000, output_tokens=200),
    )


def tool_use(payload: dict) -> SimpleNamespace:
    return SimpleNamespace(type="tool_use", id="toolu_1", name="record_agenda", input=payload)


class FakeMessages:
    def __init__(self, *replies: SimpleNamespace) -> None:
        self.replies = list(replies)
        self.requests: list[dict] = []

    def create(self, **request) -> SimpleNamespace:
        self.requests.append({**request, "messages": list(request["messages"])})
        return self.replies.pop(0)


@pytest.fixture
def fake_model(monkeypatch):
    """Fakes the Messages API (bedrock-mantle): the lab's default model ID."""
    monkeypatch.setattr(agenda_module.settings, "parser_model", "anthropic.claude-opus-5-5")

    def install(*replies: SimpleNamespace) -> FakeMessages:
        messages = FakeMessages(*replies)
        monkeypatch.setattr(agenda_module, "client", lambda: SimpleNamespace(messages=messages))
        return messages

    return install


def test_parse_agenda(fake_model) -> None:
    messages = fake_model(message(tool_use(VALID)))

    agenda, usage = parse_agenda("Pricing sync, Olena 15 min", date(2026, 10, 26), "Europe/Kyiv")

    assert agenda == ParsedAgenda.model_validate(VALID)
    assert usage == {"input_tokens": 1000, "output_tokens": 200}
    prompt = messages.requests[0]["messages"][0]["content"]
    assert "Today is Monday 2026-10-26, time zone Europe/Kyiv." in prompt
    assert "<pasted_text>\nPricing sync, Olena 15 min\n</pasted_text>" in prompt


def test_parse_agenda_retries_once_with_the_validation_error(fake_model) -> None:
    invalid = {"items": [{"topic": "Pricing", "minutes": 0}], "language": "en"}
    messages = fake_model(message(tool_use(invalid)), message(tool_use(VALID)))

    agenda, usage = parse_agenda("...", date(2026, 10, 26), "Europe/Kyiv")

    assert agenda.items[0].minutes == 15
    assert usage == {"input_tokens": 2000, "output_tokens": 400}
    feedback = messages.requests[1]["messages"][-1]["content"][0]
    assert feedback["type"] == "tool_result" and feedback["is_error"]
    assert "minutes" in feedback["content"]


def test_parse_agenda_gives_up_after_two_invalid_answers(fake_model) -> None:
    invalid = message(tool_use({"items": "none", "language": "en"}))
    fake_model(invalid, invalid)
    with pytest.raises(AgendaParseError, match="invalid agenda twice"):
        parse_agenda("...", date(2026, 10, 26), "Europe/Kyiv")


def test_parse_agenda_without_a_tool_call(fake_model) -> None:
    fake_model(message(SimpleNamespace(type="text", text="No."), stop_reason="refusal"))
    with pytest.raises(AgendaParseError, match="refusal"):
        parse_agenda("...", date(2026, 10, 26), "Europe/Kyiv")


def test_cost_usd() -> None:
    usage = {"input_tokens": 1_500, "output_tokens": 500}
    assert cost_usd("anthropic.claude-opus-5-5", usage) == 0.016
    assert cost_usd("anthropic.claude-haiku-5-5", usage) == 0.0004
    assert cost_usd("us.anthropic.claude-opus-4-5-20251101-v1:0", usage) == 0.02
    assert cost_usd("some.other-model", usage) is None


# The Converse API (bedrock-runtime), used for inference profiles such as Opus 4.5.

CONVERSE_MODEL = "us.anthropic.claude-opus-4-5-20251101-v1:0"


def converse_reply(payload: dict) -> dict:
    return {
        "output": {
            "message": {
                "role": "assistant",
                "content": [
                    {"toolUse": {"toolUseId": "t1", "name": "record_agenda", "input": payload}}
                ],
            }
        },
        "stopReason": "tool_use",
        "usage": {"inputTokens": 1000, "outputTokens": 200},
    }


class FakeRuntime:
    def __init__(self, *replies) -> None:
        self.replies = list(replies)
        self.requests: list[dict] = []

    def converse(self, **request) -> dict:
        self.requests.append({**request, "messages": list(request["messages"])})
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


@pytest.fixture
def fake_runtime(monkeypatch):
    monkeypatch.setattr(agenda_module.settings, "parser_model", CONVERSE_MODEL)

    def install(*replies) -> FakeRuntime:
        runtime = FakeRuntime(*replies)
        monkeypatch.setattr(agenda_module, "runtime", lambda: runtime)
        return runtime

    return install


def test_parse_agenda_with_converse(fake_runtime) -> None:
    invalid = {"items": [{"topic": "Pricing", "minutes": 0}], "language": "en"}
    runtime = fake_runtime(converse_reply(invalid), converse_reply(VALID))

    agenda, usage = parse_agenda("...", date(2026, 10, 26), "Europe/Kyiv")

    assert agenda == ParsedAgenda.model_validate(VALID)
    assert usage == {"input_tokens": 2000, "output_tokens": 400}
    first = runtime.requests[0]
    assert first["modelId"] == CONVERSE_MODEL
    assert first["toolConfig"]["toolChoice"] == {"tool": {"name": "record_agenda"}}
    feedback = runtime.requests[1]["messages"][-1]["content"][0]["toolResult"]
    assert feedback["toolUseId"] == "t1" and feedback["status"] == "error"


def test_converse_throttling(fake_runtime) -> None:
    error = ClientError({"Error": {"Code": "ThrottlingException", "Message": "slow"}}, "Converse")
    fake_runtime(error)
    with pytest.raises(ModelUnavailableError) as raised:
        parse_agenda("...", date(2026, 10, 26), "Europe/Kyiv")
    assert raised.value.throttled


# ------------------------------------------------------------------ The Lambda handler


@pytest.fixture
def parser(monkeypatch):
    """The handler with test tokens, and parse_agenda replaced by whatever a test sets."""
    monkeypatch.setattr(agenda_lambda, "_verifier", TokenVerifier(POOL_ID, CLIENT_ID, JWKS))
    state = SimpleNamespace(calls=[])

    def fake_parse(text, today, tz):
        state.calls.append((text, today, tz))
        if isinstance(state.result, Exception):
            raise state.result
        return state.result

    state.result = (ParsedAgenda.model_validate(VALID), {"input_tokens": 10, "output_tokens": 5})
    monkeypatch.setattr(agenda_lambda, "parse_agenda", fake_parse)
    return state


def event(body: dict | str, token: str | None = None, method: str = "POST") -> dict:
    return {
        "requestContext": {"http": {"method": method}},
        "headers": {"authorization": f"Bearer {token or make_token()}"},
        "body": body if isinstance(body, str) else json.dumps(body),
        "isBase64Encoded": False,
    }


BODY = {"text": "Pricing sync", "today": "2026-10-26", "tz": "Europe/Kyiv"}


def test_handler_parses(parser) -> None:
    response = agenda_lambda.handler(event(BODY), None)

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["agenda"]["items"][0]["owner"] == "Olena"
    assert body["prompt_version"] == "agenda-v1"
    assert parser.calls == [("Pricing sync", date(2026, 10, 26), "Europe/Kyiv")]


@pytest.mark.parametrize("token", ["not-a-jwt", make_token(token_use="access")])
def test_handler_rejects_bad_tokens(parser, token: str) -> None:
    assert agenda_lambda.handler(event(BODY, token), None)["statusCode"] == 401
    assert parser.calls == []


def test_handler_rejects_a_missing_token(parser) -> None:
    request = event(BODY)
    request["headers"] = {}
    assert agenda_lambda.handler(request, None)["statusCode"] == 401


def test_handler_rejects_long_text_before_calling_the_model(parser) -> None:
    response = agenda_lambda.handler(event({**BODY, "text": "x" * 10_001}), None)
    assert response["statusCode"] == 413
    assert parser.calls == []


@pytest.mark.parametrize(
    "body",
    ["not json", {"text": "x"}, {**BODY, "today": "Monday"}, {**BODY, "tz": "Mars/Base"}],
)
def test_handler_rejects_malformed_requests(parser, body) -> None:
    assert agenda_lambda.handler(event(body), None)["statusCode"] == 400


def test_handler_only_accepts_post(parser) -> None:
    assert agenda_lambda.handler(event(BODY, method="GET"), None)["statusCode"] == 405


def test_handler_no_agenda(parser) -> None:
    parser.result = AgendaParseError("no agenda returned (stop_reason=refusal)")
    assert agenda_lambda.handler(event(BODY), None)["statusCode"] == 422


def test_handler_throttled(parser) -> None:
    parser.result = ModelUnavailableError("ThrottlingException", throttled=True)
    assert agenda_lambda.handler(event(BODY), None)["statusCode"] == 429


def test_handler_bedrock_down(parser) -> None:
    parser.result = ModelUnavailableError("AccessDeniedException")
    assert agenda_lambda.handler(event(BODY), None)["statusCode"] == 502
