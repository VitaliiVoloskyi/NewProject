# Paste an agenda

A user pastes an agenda the way it arrives (an email, a chat message, a few lines of notes) into
a meeting. Claude on Amazon Bedrock turns it into a structured agenda, the app shows the normal
agenda form pre-filled, and the user checks it and presses Save. The model suggests and the
person decides.

```
            parse (suggest)                                   save (decide)
 Browser ──POST text, today, tz──▶ agenda-parser Lambda     Browser ──PUT /api/meetings/{id}/agenda──▶ API Lambda
   │        Bearer <Cognito ID token>  (no VPC, function URL)   agenda + ai_suggestion                │ (VPC)
   │                                   │ checks the token, ≤10,000 chars                              ▼
   │                                   ▼                                                    RDS PostgreSQL
   │                       Claude on Bedrock (bedrock-mantle)                          meetings.agenda,
   ◀──── {agenda, model, prompt_version} ─┘                                           meetings.agenda_ai_suggestion
```

| Piece | Where |
|---|---|
| The parser (plain Python: schema, prompt, one retry) | [`backend/app/ai/agenda.py`](../backend/app/ai/agenda.py) |
| Lambda handler (auth, limits, errors, the log line) | [`backend/app/ai/agenda_lambda.py`](../backend/app/ai/agenda_lambda.py) |
| Saving: `PUT /api/meetings/{id}/agenda` | [`backend/app/routers/meetings.py`](../backend/app/routers/meetings.py), migration `0003` |
| The screen | [`frontend/src/components/agenda-dialog.tsx`](../frontend/src/components/agenda-dialog.tsx) |
| Infrastructure (+ the $5 budget alarm; Terraform, applied by HCP Terraform) | [`infra/ai.tf`](../infra/ai.tf); the parser's code: [`infra/deploy-functions.sh`](../infra/deploy-functions.sh) |
| Tests (the model is faked) | [`backend/tests/test_agenda.py`](../backend/tests/test_agenda.py) |
| Decision record | [`docs/adr/0006-llm-agenda-parsing.md`](adr/0006-llm-agenda-parsing.md) |

## Run it

Once, in the AWS console (us-east-1): **Bedrock → Model catalog → (the model) → Open in
playground**, send "hi". The first call of an account submits the Anthropic use-case form.

`PARSER_MODEL` picks the model and the API. A plain `anthropic.*` ID (`anthropic.claude-opus-5-5`)
uses the Anthropic Messages API (`bedrock-mantle`). An inference profile
(`us.anthropic.claude-opus-4-5-20251101-v1:0`) uses the Converse API (`bedrock-runtime`). This
account may not use the Claude 5 models, so `.env` uses Opus 4.5 through Converse.

```bash
make llm-hello                       # one question; prints the answer, stop_reason and usage
make parse TEXT="Пн 10:00, синк по прайсингу, 45 хв. 1) нові тарифи Pro — Олена, 15 хв"
make parse TEXT="..." PARSER_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0
make parse-eval                      # the five test inputs of the lab, as table rows

# The parser, its URL and the budget are infra/ai.tf: HCP Terraform applies them after a merge.
# parser_model is in infra/terraform.tfvars, budget_email is a workspace variable.
make deploy-frontend                 # the app is rebuilt with the parser's URL (a Terraform output)
make parser-logs                     # one JSON line per parse: tokens, latency, cost
```

`make deploy-backend` (and CI) ships the parser's new code (`make deploy-functions`).
For `make dev-frontend`, `make auth-env` writes the parser's URL to `VITE_PARSER_URL` in `.env`.

## What the parser answers

| Status | When | The screen says |
|---|---|---|
| 200 | `{"agenda": {...}, "model": ..., "prompt_version": "agenda-v1"}` | the form, pre-filled, with "suggested" badges |
| 400 | body is not `{"text", "today", "tz"}` | — |
| 401 | no token, or not a valid Cognito ID token of this app | session expired |
| 413 | text over 10,000 characters (checked before the model is called) | text too long |
| 422 | no tool call (e.g. a refusal), or invalid output twice | no agenda found |
| 429 | Bedrock throttled, after the SDK's retries | service busy |
| 502 | any other Bedrock error | service unavailable |

In every case the form stays usable: the user can type the agenda by hand.

## The log line

```bash
aws logs filter-log-events --log-group-name /spry/agenda-parser \
  --filter-pattern '{ $.message = "agenda_parsed" }' --query 'events[].message' --output text
```

Each parse writes one JSON line with `user` (Cognito sub), `model`, `prompt_version`,
`input_tokens`, `output_tokens`, `latency_ms` and `cost_usd` (list prices from `PRICES` in
`agenda.py`). With the logs in JSON, CloudWatch Logs Insights can add them up:

```
filter message = "agenda_parsed"
| stats count() as parses, sum(cost_usd) as cost, avg(latency_ms) as latency by model
```

## The quality signal

Save sends what the model suggested (`ai_suggestion`: its agenda, model and prompt version)
with the agenda the user kept. The API stores it in `meetings.agenda_ai_suggestion` and never
returns it. Comparing the two columns tells you how often, and where, users corrected the model:

```sql
SELECT agenda_ai_suggestion->>'prompt_version' AS prompt, count(*) AS saved,
       avg((agenda_ai_suggestion->'agenda'->'items' = agenda->'items')::int) AS items_kept_as_is
FROM meetings WHERE agenda_ai_suggestion IS NOT NULL GROUP BY 1;
```
