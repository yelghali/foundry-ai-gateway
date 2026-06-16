"""
Scenario 1 — AGENT FRAMEWORK (OpenAI Agents SDK) on the APIM load-balanced AI gateway.

Demonstrates that an agent framework can use the APIM AI gateway as its model backend:
  - The OpenAI Agents SDK drives a multi-step tool-calling loop.
  - The model backend is the APIM AI gateway, which load balances across two Foundry
    regions and authenticates to them with its managed identity (no keys in the client).
  - The agent calls a local Python tool (function calling), then composes a final answer.

This shows the "Agents — as a model backend for frameworks" row of the README matrix:
APIM is not an agent runtime, but it is a perfectly good OpenAI-compatible model backend
for any agent framework.

Prereq: pip install -r requirements.txt   (installs openai + openai-agents)

Usage (PowerShell):
    $env:APIM_GATEWAY_URL = "https://apim-xxxx.azure-api.net"
    $env:APIM_API_KEY      = "<subscription key>"
    python agent_apim.py
"""
import asyncio
import os

from openai import AsyncAzureOpenAI
from agents import (
    Agent,
    OpenAIChatCompletionsModel,
    Runner,
    function_tool,
    set_tracing_disabled,
)

# No OpenAI-platform key is needed for this lab; disable the SDK's tracing exporter.
set_tracing_disabled(True)

GATEWAY_URL = os.environ["APIM_GATEWAY_URL"].rstrip("/")
API_KEY = os.environ["APIM_API_KEY"]
API_PATH = os.environ.get("INFERENCE_API_PATH", "inference")
MODEL = os.environ.get("MODEL", "gpt-4o-mini")
API_VERSION = os.environ.get("API_VERSION", "2024-10-21")

# AzureOpenAI client pointed at the APIM inference API (Azure-style routes + api-key header).
client = AsyncAzureOpenAI(
    api_key=API_KEY,
    azure_endpoint=f"{GATEWAY_URL}/{API_PATH}",
    api_version=API_VERSION,
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
    model=OpenAIChatCompletionsModel(model=MODEL, openai_client=client),
)


async def main() -> None:
    result = await Runner.run(agent, "How many euros and pounds is 250 US dollars?")
    print("Agent answer:", result.final_output)
    print("\n=> Agent framework (OpenAI Agents SDK) ran on the APIM load-balanced AI gateway.")


if __name__ == "__main__":
    asyncio.run(main())
