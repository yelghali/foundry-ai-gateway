"""Local MAF agent consumes a Foundry Toolbox through APIM without keys."""

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
TOOLBOX_APIM_URL = cfg.require("toolboxApimUrl", "TOOLBOX_APIM_URL")
INBOUND_SCOPE = cfg.get(
    "apimInboundScope",
    "APIM_INBOUND_SCOPE",
    "https://cognitiveservices.azure.com/.default",
)


class EntraAuth(httpx.Auth):
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
    print("Scenario 3a - local MAF agent -> APIM -> Foundry Toolbox")
    print(f"  Toolbox : {TOOLBOX_APIM_URL}")
    print("  Ingress : DefaultAzureCredential -> APIM -> APIM managed identity -> Toolbox")
    print("  Egress  : Toolbox project identity -> APIM -> Microsoft Learn MCP")
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
            timeout=httpx.Timeout(180.0),
        ) as http_client:
            toolbox = MCPStreamableHTTPTool(
                name="research_toolbox",
                url=TOOLBOX_APIM_URL,
                description="Foundry Toolbox published through customer-owned APIM.",
                http_client=http_client,
                approval_mode="never_require",
            )
            async with toolbox:
                agent = model_client.as_agent(
                    name="sc3-maf-apim-toolbox-mi",
                    instructions="Use the research Toolbox to answer in one sentence.",
                    tools=toolbox,
                )
                result = await agent.run(
                    "Use Microsoft Learn to explain Azure API Management in one sentence."
                )
        text = (result.text or "").strip().replace("\n", " ")
        if not text:
            raise RuntimeError("The agent returned an empty response.")
        print(f"  PASS    : {text}")
    finally:
        await credential.close()


if __name__ == "__main__":
    asyncio.run(main())