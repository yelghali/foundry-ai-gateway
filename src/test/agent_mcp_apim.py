"""
Scenario 1 (MCP) — Local tool + REMOTE MS Learn MCP tool, both governed by the APIM gateway.

Builds on agent_apim.py. The agent keeps its **local** Python tool (get_exchange_rate)
AND gains a **remote MCP toolset** — the public MS Learn MCP server — reached THROUGH APIM.
So the *same* gateway + subscription key front BOTH:
  - model (inference) traffic -> load-balanced Foundry backends   ({gateway}/inference)
  - tool  (MCP) traffic       -> MS Learn MCP, proxied by APIM     ({gateway}/learn-mcp/mcp)

This is the point of the demo: an AI gateway can govern *tools* (MCP), not just models.
The MS Learn MCP server is public, but here every MCP call still flows through APIM (auth,
throttling, logging) exactly like the model calls.

Prereqs:
  - APIM has the MS Learn MCP passthrough API (added by infra/main.bicep -> "mslearn-mcp").
  - pip install -r requirements.txt   (installs openai-agents + mcp)

Usage (PowerShell):
    $env:APIM_GATEWAY_URL = "https://apim-xxxx.azure-api.net"
    $env:APIM_API_KEY     = "<subscription key>"
    python agent_mcp_apim.py
"""
import asyncio
import os

from openai import AsyncAzureOpenAI
from agents import Agent, OpenAIChatCompletionsModel, Runner, function_tool, set_tracing_disabled
from agents.mcp import MCPServerStreamableHttp

# No OpenAI-platform key is needed for this lab; disable the SDK's tracing exporter.
set_tracing_disabled(True)

GATEWAY_URL = os.environ["APIM_GATEWAY_URL"].rstrip("/")
API_KEY = os.environ["APIM_API_KEY"]
API_PATH = os.environ.get("INFERENCE_API_PATH", "inference")
MODEL = os.environ.get("MODEL", "gpt-4o-mini")
API_VERSION = os.environ.get("API_VERSION", "2024-10-21")
# MS Learn MCP, proxied by APIM (the "mslearn-mcp" API added in infra/main.bicep).
MCP_PATH = os.environ.get("MCP_API_PATH", "learn-mcp/mcp")
MCP_URL = f"{GATEWAY_URL}/{MCP_PATH}"

# AzureOpenAI client pointed at the APIM inference API (Azure-style routes + api-key header).
client = AsyncAzureOpenAI(
    api_key=API_KEY,
    azure_endpoint=f"{GATEWAY_URL}/{API_PATH}",
    api_version=API_VERSION,
)


@function_tool
def get_exchange_rate(base: str, quote: str) -> str:
    """Return a (mock) FX rate for a currency pair, e.g. base=USD quote=EUR. (LOCAL tool)"""
    rates = {
        ("USD", "EUR"): 0.92,
        ("USD", "GBP"): 0.79,
        ("EUR", "USD"): 1.09,
    }
    rate = rates.get((base.upper(), quote.upper()), 1.0)
    return f"1 {base.upper()} = {rate} {quote.upper()}"


async def main() -> None:
    # The MCP server is reached THROUGH APIM: the api-key header authenticates to APIM,
    # which proxies the streamable-HTTP MCP traffic to https://learn.microsoft.com/api/mcp.
    mslearn = MCPServerStreamableHttp(
        name="MS Learn (via APIM)",
        params={"url": MCP_URL, "headers": {"api-key": API_KEY}},
        cache_tools_list=True,
    )

    async with mslearn:
        agent = Agent(
            name="Docs + FX Assistant",
            instructions=(
                "You are a helpful assistant. Use the local get_exchange_rate tool for currency "
                "conversions, and use the MS Learn tools to look up Microsoft/Azure documentation. "
                "When you use MS Learn, cite the doc title or URL."
            ),
            model=OpenAIChatCompletionsModel(model=MODEL, openai_client=client),
            tools=[get_exchange_rate],          # LOCAL tool
            mcp_servers=[mslearn],              # REMOTE MCP tools, via APIM
        )

        result = await Runner.run(
            agent,
            "Use MS Learn to tell me in one sentence what Azure API Management is, "
            "then convert 100 USD to EUR using the exchange-rate tool.",
        )
        print("Agent answer:\n", result.final_output)

    print("\n=> APIM governed BOTH the model calls and the MS Learn MCP tool calls.")


if __name__ == "__main__":
    asyncio.run(main())
