"""
Scenario 4 — AGENT FRAMEWORK (Microsoft Agent Framework) on the BYO LiteLLM gateway.

Same scenario as agent_litellm.py (which uses the OpenAI Agents SDK), but driven by the
**Microsoft Agent Framework** (`agent-framework`). MAF uses the LiteLLM proxy as its
OpenAI-compatible model backend; LiteLLM load balances across the two Foundry regions
with Entra ID auth. Same agent + tool as the APIM variant -- only the model backend URL
changes.

Prereqs:
  1. LiteLLM reachable -- either local (cd ../litellm; docker compose up) or the deployed
     Container App URL.
  2. pip install -r requirements.txt   (installs agent-framework)

Usage (PowerShell):
    $env:LITELLM_BASE_URL   = "http://localhost:4000"
    $env:LITELLM_MASTER_KEY = "sk-litellm-local-poc"
    python agent_maf_litellm.py
"""
import asyncio
import os

from agent_framework.openai import OpenAIChatCompletionClient

BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000").rstrip("/")
API_KEY = os.environ["LITELLM_MASTER_KEY"]
MODEL = os.environ.get("MODEL", "gpt-4o-mini")


def get_exchange_rate(base: str, quote: str) -> str:
    """Return a (mock) FX rate for a currency pair, e.g. base=USD quote=EUR."""
    rates = {
        ("USD", "EUR"): 0.92,
        ("USD", "GBP"): 0.79,
        ("EUR", "USD"): 1.09,
    }
    rate = rates.get((base.upper(), quote.upper()), 1.0)
    return f"1 {base.upper()} = {rate} {quote.upper()}"


async def main() -> None:
    # OpenAIChatCompletionClient against the LiteLLM proxy (plain OpenAI-style routes + bearer key).
    client = OpenAIChatCompletionClient(
        model=MODEL,
        base_url=BASE_URL,
        api_key=API_KEY,
    )

    agent = client.as_agent(
        name="FX Assistant",
        instructions=(
            "You are a concise FX assistant. Use the get_exchange_rate tool to look up "
            "rates, then answer in one short sentence with the converted amounts."
        ),
        tools=get_exchange_rate,
    )

    result = await agent.run("How many euros and pounds is 250 US dollars?")
    print("Agent answer:", result.text)
    print("\n=> Microsoft Agent Framework ran on the BYO LiteLLM gateway.")


if __name__ == "__main__":
    asyncio.run(main())
