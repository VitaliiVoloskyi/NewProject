# 6. Parse pasted agendas with Claude on Bedrock, outside the VPC, and save through the API

Date: 2026-10-27 · Status: accepted

## Context

Agendas reach our users as emails, chat messages and notes, not as forms. Retyping them into
the agenda form is the slowest part of preparing a meeting. We want users to paste the text and
get the form pre-filled, in Ukrainian and English, with relative dates ("Monday", "by Friday")
resolved.

Constraints:

- **No NAT, $0 when idle.** The API and the database are in a VPC without a NAT gateway (Lab 4).
  Anything new that is always on, such as a NAT gateway (~$33/month) or an interface endpoint
  (~$7.30/month), has to justify itself.
- **Every call costs money.** An open LLM endpoint is a wallet without a lock.
- **The text comes from outside.** Users paste emails other people wrote. That text can contain
  instructions ("ignore your instructions and…"): prompt injection.
- **A model can be wrong.** It can give a confident, plausible and wrong answer, with a 200 status.

## Decision

- **Model:** Claude Opus 5.5 (`anthropic.claude-opus-5-5`) through the Anthropic Messages API on
  Bedrock (`bedrock-mantle`), `effort: low`, was the plan. This AWS account is not allowed to use
  Opus 5.5 or any other Claude 5 model (`AccessDeniedException`), so the parser runs **Claude
  Opus 4.5** (`us.anthropic.claude-opus-4-5-20251101-v1:0`) through the **Converse API**
  (`bedrock-runtime`). `bedrock-mantle` serves only the newest Claude models. `agenda.py` picks
  the API from the model ID, so moving to Opus 5.5 once access is granted, or to Haiku 4.5 for
  cost, is a change to `PARSER_MODEL`. The provider-neutral API proved its worth here.
- **Structured output by validation.** The model answers by calling one tool, `record_agenda`,
  whose input schema is our Pydantic model. On the Messages API, Opus 5.5 accepts no forced tool
  choice, so the prompt asks for the tool. On Converse, Opus 4.5 is forced to use it. In both
  cases the code validates the answer.
  It retries once with the validation error, then fails with 422. Invalid output never leaves
  the function. The schema allows `null` everywhere the text may be silent, and the prompt says
  "leave it empty rather than invent".
- **A separate Lambda, outside the VPC.** The parser needs text in and JSON out, not the
  database. Outside the VPC it reaches Bedrock (and Cognito's keys) over the internet, with no
  NAT and no endpoint, and costs nothing while nobody parses. It reuses the backend image with
  another handler, as the report builder does.
- **The model never writes.** The parser only returns a suggestion. The user checks it, and Save
  goes through the existing API (`PUT /api/meetings/{id}/agenda`), with its validation, its
  ownership check and its database access. The API stores the suggestion (with model and prompt
  version) next to the saved agenda as the quality signal.
- **Guard rails on the endpoint:** a valid Cognito ID token of our app is required (401), text is
  capped at 10,000 characters before the model is called (413), CORS allows only our sites and
  POST, and an AWS Budgets alarm emails us above $5 a month.

## Alternatives considered

| Alternative | Why it lost |
|---|---|
| Call Bedrock from the API Lambda, inside the VPC, through a `bedrock-mantle` interface endpoint | ~$7.30/month per endpoint (per AZ) even with no traffic, which breaks "$0 when idle"; and a slow LLM call would hold an API instance and a database connection for seconds. The parser needs no data, so it does not need the VPC. |
| Call the Claude API (api.anthropic.com) directly | Needs an API key stored and rotated in Secrets Manager, and a second bill and second set of logs outside AWS. Bedrock uses the Lambda's IAM role, bills through AWS (Budgets, tags) and logs to CloudWatch/CloudTrail. The request shape is the same Messages API, so moving later is cheap. |
| A regular-expression parser | Free and deterministic, but agendas have no fixed format: two languages, numbering styles, owners as names or emails, durations as "15 хв", "15 min", "a quarter of an hour", and relative dates. It would handle the examples we wrote it for and nothing else. |
| Only one of the two APIs | The Messages API gets new Claude features first, but on this account it serves no model we may use. Converse serves every provider. Supporting both costs one extra function in `agenda.py`, behind the same `parse_agenda` interface. |
| Let the model call a `save_agenda` tool | A wrong or injected answer would be written without anyone looking at it. Writes stay on the validated path that already exists. |

## Consequences

- **Cost per parse**, measured on five test inputs (~1,330 tokens in, ~200 out): $0.0117 with
  Opus 4.5 and $0.0023 with Haiku 4.5. 20 organisations × 30 agendas a week is ~2,600 parses a
  month: ~$30 (Opus 4.5) or ~$6 (Haiku 4.5). One idle VPC interface endpoint costs $7.30.
- **Logged:** one JSON line per parse in `/<project>/agenda-parser`: user (Cognito sub), model,
  prompt version, input and output tokens, latency, cost in dollars. Not logged: the text
  itself, which may contain personal data. Failures log the reason.
- **When Bedrock is down or throttling,** the parse fails with a clear message (502 / 429), and
  the user types the agenda by hand. Everything else in Spry (meetings, agendas, reports) does
  not depend on the parser and keeps working.
- **Prompt injection** cannot be fully prevented. The damage is limited by the design: the
  pasted text is delimited and declared to be data, the parser can read nothing but that text,
  it can write nothing, and the user reviews every field (marked "suggested") before Save.
- **Not yet done:** per-user rate limits (a user with many accounts can still spend money until
  the budget alarm fires); a narrowed IAM policy (`bedrock-mantle:CreateInference` on `*` allows
  every model, including the most expensive one); an evaluation set to compare `agenda-v2`
  against `agenda-v1` before switching.
