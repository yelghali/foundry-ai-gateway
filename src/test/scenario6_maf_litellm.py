"""Scenario 6a: local Microsoft Agent Framework consumes LiteLLM model, MCP, and A2A."""

import asyncio
import os
import sys

import httpx
from a2a.client import A2ACardResolver
from agent_framework import MCPStreamableHTTPTool
from agent_framework.a2a import A2AAgent
from agent_framework.openai import OpenAIChatCompletionClient

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402

BASE_URL = cfg.require("litellmBaseUrl", "LITELLM_BASE_URL").rstrip("/")
MCP_URL = cfg.require("litellmMcpUrl", "LITELLM_MCP_URL")
A2A_URL = cfg.require("litellmA2aShimUrl", "LITELLM_A2A_URL")
MODEL = cfg.get("litellmModel", "LITELLM_MODEL", "gpt-5.1").split("/", 1)[-1]
API_KEY = os.environ.get("LITELLM_API_KEY") or os.environ.get("LITELLM_MASTER_KEY")
if not API_KEY:
    raise SystemExit("Set LITELLM_API_KEY (preferred) or LITELLM_MASTER_KEY.")


def response_text(response) -> str:
    text = getattr(response, "text", None)
    if not text and getattr(response, "messages", None):
        text = response.messages[-1].text
    return str(text or response).strip().replace("\n", " ")


async def main() -> None:
    mcp_request_count = 0

    async def observe_request(request: httpx.Request) -> None:
        nonlocal mcp_request_count
        if "/mcp" in request.url.path:
            mcp_request_count += 1

    print("Scenario 6a - local MAF -> LiteLLM BYO gateway")
    print(f"  Model : {BASE_URL}/v1 ({MODEL})")
    print(f"  MCP   : {MCP_URL}")
    print(f"  A2A   : {A2A_URL}")
    print("  Auth  : bearer credential -> LiteLLM; LiteLLM MI -> private Foundry models")

    model_client = OpenAIChatCompletionClient(
        model=MODEL,
        base_url=f"{BASE_URL}/v1",
        api_key=API_KEY,
    )
    model_agent = model_client.as_agent(
        name="sc6-maf-litellm-model",
        instructions="Answer in one concise sentence.",
    )
    model_result = await model_agent.run("What does an AI gateway do?")
    model_text = response_text(model_result)
    if not model_text:
        raise RuntimeError("The LiteLLM model returned an empty response.")
    print(f"  MODEL : PASS - {model_text}")

    async with httpx.AsyncClient(
        headers={"Authorization": f"Bearer {API_KEY}"},
        follow_redirects=True,
        timeout=httpx.Timeout(180.0),
        event_hooks={"request": [observe_request]},
    ) as http_client:
        mcp = MCPStreamableHTTPTool(
            name="mslearn",
            url=MCP_URL,
            description="Microsoft Learn MCP exposed through LiteLLM.",
            http_client=http_client,
            approval_mode="never_require",
        )
        async with mcp:
            baseline_mcp_requests = mcp_request_count
            tool_agent = model_client.as_agent(
                name="sc6-maf-litellm-mcp",
                instructions=(
                    "Always use the Microsoft Learn MCP search tool, then answer in one sentence."
                ),
                tools=mcp,
            )
            tool_result = await tool_agent.run(
                "Search Microsoft Learn: what is Azure API Management?"
            )
        tool_text = response_text(tool_result)
        if not tool_text or mcp_request_count <= baseline_mcp_requests:
            raise RuntimeError("The MAF agent did not complete a LiteLLM MCP tool call.")
        print(f"  MCP   : PASS - {tool_text}")

        resolver = A2ACardResolver(httpx_client=http_client, base_url=A2A_URL)
        card = await resolver.get_agent_card()
        specialist = A2AAgent(agent_card=card, http_client=http_client)
        a2a_result = await specialist.run(
            "Should an enterprise expose agents through an AI gateway?"
        )
        a2a_text = response_text(a2a_result)
        if not a2a_text:
            raise RuntimeError("The LiteLLM A2A path returned an empty response.")
        print(f"  A2A   : PASS - {a2a_text}")


if __name__ == "__main__":
    asyncio.run(main())
