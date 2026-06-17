"""
Scenario 4 — OpenAI SDK calling the BYO LiteLLM gateway (load-balanced Foundry models).

Uses the official `openai` SDK (OpenAI client) pointed at the LiteLLM proxy, which is
OpenAI-compatible and load balances across two Foundry regions with Entra ID auth.
This mirrors sample_openai_apim.py, but targets the LiteLLM gateway instead of APIM
(plain OpenAI-style routes + bearer key, rather than Azure-style routes + api-key).

Usage (PowerShell):
    $env:LITELLM_BASE_URL   = "http://localhost:4000"
    $env:LITELLM_MASTER_KEY = "sk-litellm-local-poc"
    python sample_openai_litellm.py
"""
import os

from openai import OpenAI

BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000").rstrip("/")
API_KEY = os.environ["LITELLM_MASTER_KEY"]
MODEL = os.environ.get("MODEL", "gpt-4o-mini")
RUNS = int(os.environ.get("RUNS", "6"))

# Plain OpenAI client; LiteLLM exposes OpenAI-compatible routes at {base_url}/chat/completions.
client = OpenAI(base_url=BASE_URL, api_key=API_KEY)

for i in range(RUNS):
    completion = client.chat.completions.create(
        model=MODEL,
        messages=[{"role": "user", "content": "Reply with a single word: hello"}],
        max_tokens=5,
    )
    print(f"Run {i + 1}/{RUNS}  -> {completion.choices[0].message.content!r}")

print("\n=> OpenAI SDK ran against the BYO LiteLLM gateway (load-balanced Foundry models).")
