"""First call to Claude on Bedrock: make llm-hello (PARSER_MODEL=... to try another model)."""

from app.ai.agenda import client, runtime, uses_converse
from app.config import settings

QUESTION = "In one sentence: what is an ISO week?"


def main() -> None:
    if uses_converse(settings.parser_model):
        # The Converse API: AWS's own request shape, the same for every provider.
        resp = runtime().converse(
            modelId=settings.parser_model,
            messages=[{"role": "user", "content": [{"text": QUESTION}]}],
            inferenceConfig={"maxTokens": 200},
        )
        print(resp["output"]["message"]["content"][0]["text"])
        print(resp["stopReason"], resp["usage"]["inputTokens"], resp["usage"]["outputTokens"])
        return
    # The Anthropic Messages API, served by Bedrock.
    msg = client().messages.create(
        model=settings.parser_model,
        max_tokens=1024,
        output_config={"effort": "low"},
        messages=[{"role": "user", "content": QUESTION}],
    )
    print(next(b.text for b in msg.content if b.type == "text"))
    print(msg.stop_reason, msg.usage.input_tokens, msg.usage.output_tokens)


if __name__ == "__main__":
    main()
