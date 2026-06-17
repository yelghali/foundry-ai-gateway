"""
Scenario 1 — AGENT FRAMEWORK (Microsoft Agent Framework) on the APIM load-balanced gateway.

Same scenario as agent_apim.py (which uses the OpenAI Agents SDK), but driven by the
**Microsoft Agent Framework** (`agent-framework`). It shows that MAF can use the APIM AI
gateway as its model backend:
  - MAF runs the tool-calling loop (model call -> tool -> final answer).
  - The model backend is the APIM AI gateway, which load balances across two Foundry
    regions and authenticates to them with its managed identity (no model keys in client).

Prereq: pip install -r requirements.txt   (installs agent-framework)

Usage (PowerShell):
    $env:APIM_GATEWAY_URL = "https://apim-xxxx.azure-api.net"
    $env:APIM_API_KEY      = "<subscription key>"
    python agent_maf_apim.py
"""
import asyncio
import os

from agent_framework.openai import OpenAIChatCompletionClient

GATEWAY_URL = os.environ["APIM_GATEWAY_URL"].rstrip("/")
API_KEY = os.environ["APIM_API_KEY"]
API_PATH = os.environ.get("INFERENCE_API_PATH", "inference")
MODEL = os.environ.get("MODEL", "gpt-4o-mini")
API_VERSION = os.environ.get("API_VERSION", "2024-10-21")


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
    # OpenAIChatCompletionClient supports Azure routing: pass azure_endpoint + api_version
    # and it builds Azure-style routes against the APIM inference base
    #   {azure_endpoint}/openai/deployments/{model}/chat/completions?api-version=...
    # sending the api-key header -- exactly what the APIM gateway expects.
    client = OpenAIChatCompletionClient(
        model=MODEL,
        azure_endpoint=f"{GATEWAY_URL}/{API_PATH}",
        api_key=API_KEY,
        api_version=API_VERSION,
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
    print("\n=> Microsoft Agent Framework ran on the APIM load-balanced AI gateway.")


if __name__ == "__main__":
    asyncio.run(main())
