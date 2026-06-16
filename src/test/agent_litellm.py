"""
Scenario 4 — AGENT on the BYO LiteLLM gateway (models + tools + agents).

Proves the LiteLLM bring-your-own gateway can back a full agent, not just chat:
  - LiteLLM exposes an OpenAI-compatible endpoint in front of two Foundry regions.
  - The OpenAI Agents SDK runs an agent that calls a Python tool (function calling)
    and composes a final answer — the same agent code as agent_apim.py, just a
    different OpenAI-compatible base URL.

This is the "Agents — as a model backend for frameworks" capability for LiteLLM: it is
not a hosted agent runtime, but it serves models + tool pass-through so an agent framework
runs on top of it unchanged.

Prereqs:
  1. LiteLLM proxy running:  cd ../litellm; docker compose up   (or, without Docker,
     pip install "litellm[proxy]" and run:  litellm --config config.yaml --port 4000)
  2. pip install -r requirements.txt   (installs openai + openai-agents)

Usage (PowerShell):
    $env:LITELLM_BASE_URL   = "http://localhost:4000"
    $env:LITELLM_MASTER_KEY = "sk-litellm-local-poc"
    python agent_litellm.py
"""
import asyncio
import os

from openai import AsyncOpenAI
from agents import (
    Agent,
    OpenAIChatCompletionsModel,
    Runner,
    function_tool,
    set_tracing_disabled,
)

set_tracing_disabled(True)

# AsyncOpenAI client pointed at the LiteLLM proxy (plain OpenAI-style routes).
client = AsyncOpenAI(
    base_url=os.environ.get("LITELLM_BASE_URL", "http://localhost:4000"),
    api_key=os.environ["LITELLM_MASTER_KEY"],
)


@function_tool
def get_exchange_rate(base: str, quote: str) -> str:
    """Return a (mock) FX rate for a currency pair, e.g. base=USD quote=EUR."""
    rates = {
        ("USD", "EUR"): 0.92,
        ("USD", "GBP"): 0.79,
        ("EUR", "USD"): 1.09,
    }
    rate = rates.get((base.upper(), quote.upper()), 1.0)
    return f"1 {base.upper()} = {rate} {quote.upper()}"


agent = Agent(
    name="FX Assistant",
    instructions=(
        "You are a concise FX assistant. Use the get_exchange_rate tool to look up rates, "
        "then answer in one short sentence with the converted amounts."
    ),
    tools=[get_exchange_rate],
    model=OpenAIChatCompletionsModel(
        model=os.environ.get("MODEL", "gpt-4o-mini"),
        openai_client=client,
    ),
)


async def main() -> None:
    result = await Runner.run(agent, "How many euros and pounds is 250 US dollars?")
    print("Agent answer:", result.final_output)
    print("\n=> LiteLLM BYO gateway ran an AGENT (models + tools + agent loop).")


if __name__ == "__main__":
    asyncio.run(main())
