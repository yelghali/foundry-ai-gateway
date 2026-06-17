"""
Scenario 4 (MCP) — Local tool + REMOTE MS Learn MCP tool, both governed by the LiteLLM gateway.

Builds on agent_litellm.py. The agent keeps its **local** Python tool (get_exchange_rate)
AND gains a **remote MCP toolset** — the public MS Learn MCP server — reached THROUGH LiteLLM.
LiteLLM is configured as an **MCP gateway** (see `mcp_servers:` in config.foundry.yaml), so the
*same* proxy + master key front BOTH:
  - model (inference) traffic -> load-balanced Foundry backends   ({base_url}/chat/completions)
  - tool  (MCP) traffic       -> MS Learn MCP, proxied by LiteLLM ({base_url}/mcp/)

LiteLLM aggregates the registered MCP servers and re-exposes them at /mcp. The client selects
the "mslearn" server with the `x-mcp-servers` header and authenticates with the master key.

Prereqs:
  1. LiteLLM running WITH the mcp_servers config (cd ../litellm; docker compose up, or the
     deployed Container App after redeploy with the updated config.foundry.yaml).
  2. pip install -r requirements.txt   (installs openai-agents + mcp)

Usage (PowerShell):
    $env:LITELLM_BASE_URL   = "http://localhost:4000"
    $env:LITELLM_MASTER_KEY = "sk-litellm-local-poc"
    python agent_mcp_litellm.py
"""
import asyncio
import os

from openai import AsyncOpenAI
from agents import Agent, OpenAIChatCompletionsModel, Runner, function_tool, set_tracing_disabled
from agents.mcp import MCPServerStreamableHttp

set_tracing_disabled(True)

BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000").rstrip("/")
API_KEY = os.environ["LITELLM_MASTER_KEY"]
MODEL = os.environ.get("MODEL", "gpt-4o-mini")
# LiteLLM re-exposes its registered MCP servers at /mcp/. "mslearn" is the alias from config.
# NOTE: the trailing slash matters — LiteLLM 307-redirects /mcp -> /mcp/, and the streamable-HTTP
# MCP client refuses to follow that redirect (it can downgrade https->http behind the proxy).
MCP_URL = os.environ.get("MCP_URL", f"{BASE_URL}/mcp/")
MCP_SERVER_ALIAS = os.environ.get("MCP_SERVER_ALIAS", "mslearn")

# AsyncOpenAI client pointed at the LiteLLM proxy (plain OpenAI-style routes).
client = AsyncOpenAI(base_url=BASE_URL, api_key=API_KEY)


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
    # The MCP server is reached THROUGH LiteLLM: the master key authenticates to LiteLLM,
    # and the x-mcp-servers header selects the registered "mslearn" server, which LiteLLM
    # proxies to https://learn.microsoft.com/api/mcp.
    mslearn = MCPServerStreamableHttp(
        name="MS Learn (via LiteLLM)",
        params={
            "url": MCP_URL,
            "headers": {
                "Authorization": f"Bearer {API_KEY}",
                "x-mcp-servers": MCP_SERVER_ALIAS,
            },
        },
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
            mcp_servers=[mslearn],              # REMOTE MCP tools, via LiteLLM
        )

        result = await Runner.run(
            agent,
            "Use MS Learn to tell me in one sentence what Azure API Management is, "
            "then convert 100 USD to EUR using the exchange-rate tool.",
        )
        print("Agent answer:\n", result.final_output)

    print("\n=> LiteLLM governed BOTH the model calls and the MS Learn MCP tool calls.")


if __name__ == "__main__":
    asyncio.run(main())
