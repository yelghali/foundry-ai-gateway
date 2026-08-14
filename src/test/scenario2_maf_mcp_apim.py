"""Local Microsoft Agent Framework agent consumes MCP through APIM without keys."""

import asyncio
import os
import sys

import httpx
from agent_framework import MCPStreamableHTTPTool
from agent_framework.openai import OpenAIChatCompletionClient
from azure.identity.aio import DefaultAzureCredential

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402

GATEWAY_URL = cfg.require("apimGatewayUrl", "APIM_GATEWAY_URL").rstrip("/")
MODEL_API_PATH = cfg.get("modelApimMiPath", "MODEL_APIM_MI_PATH", "inference-mi")
MODEL = cfg.get("enterpriseModel", "MODEL", "gpt-4o-mini")
API_VERSION = cfg.get("inferenceApiVersion", "API_VERSION", "2024-10-21")
MCP_URL = cfg.get(
    "rawMcpApimUrl",
    "MCP_APIM_URL",
    f"{GATEWAY_URL}/learn-mcp-mi/mcp",
)
INBOUND_SCOPE = cfg.get(
    "apimInboundScope",
    "APIM_INBOUND_SCOPE",
    "https://cognitiveservices.azure.com/.default",
)


class EntraAuth(httpx.Auth):
    """Attach a fresh Entra access token to every MCP request."""

    def __init__(self, credential: DefaultAzureCredential, scope: str) -> None:
        self._credential = credential
        self._scope = scope

    async def async_auth_flow(self, request):
        token = await self._credential.get_token(self._scope)
        request.headers["Authorization"] = f"Bearer {token.token}"
        yield request


async def main() -> None:
    credential = DefaultAzureCredential(process_timeout=cfg.credential_process_timeout())
    model_endpoint = f"{GATEWAY_URL}/{MODEL_API_PATH}"
    print("Scenario 2a - local MAF agent -> APIM -> MCP server")
    print(f"  Model   : {model_endpoint}")
    print(f"  MCP     : {MCP_URL}")
    print(f"  Auth    : DefaultAzureCredential -> {INBOUND_SCOPE} (no key)")
    try:
        model_client = OpenAIChatCompletionClient(
            model=MODEL,
            azure_endpoint=model_endpoint,
            api_version=API_VERSION,
            credential=credential,
        )
        async with httpx.AsyncClient(
            auth=EntraAuth(credential, INBOUND_SCOPE),
            follow_redirects=True,
            timeout=httpx.Timeout(120.0),
        ) as http_client:
            mcp = MCPStreamableHTTPTool(
                name="mslearn",
                url=MCP_URL,
                description="Microsoft Learn MCP governed by customer-owned APIM.",
                http_client=http_client,
                approval_mode="never_require",
            )
            async with mcp:
                agent = model_client.as_agent(
                    name="sc2-maf-apim-mcp-mi",
                    instructions="Use the Microsoft Learn MCP tool to answer in one sentence.",
                    tools=mcp,
                )
                result = await agent.run(
                    "Search Microsoft Learn: what is Azure API Management?"
                )
        text = (result.text or "").strip().replace("\n", " ")
        if not text:
            raise RuntimeError("The agent returned an empty response.")
        print(f"  PASS    : {text}")
    finally:
        await credential.close()


if __name__ == "__main__":
    asyncio.run(main())