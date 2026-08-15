"""MAF combined workflow: APIM model, Toolbox, and A2A agent, all keyless."""

import asyncio
import json
import os
import sys

import httpx
from a2a.client import A2ACardResolver
from agent_framework import MCPStreamableHTTPTool
from agent_framework.a2a import A2AAgent
from agent_framework.openai import OpenAIChatCompletionClient
from azure.identity.aio import DefaultAzureCredential

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402

GATEWAY_URL = cfg.require("apimGatewayUrl", "APIM_GATEWAY_URL").rstrip("/")
MODEL_API_PATH = cfg.get("modelApimMiPath", "MODEL_APIM_MI_PATH", "inference-mi")
MODEL = cfg.get("enterpriseModel", "MODEL", "gpt-4o-mini")
API_VERSION = cfg.get("inferenceApiVersion", "API_VERSION", "2024-10-21")
TOOLBOX_APIM_URL = cfg.require("toolboxApimUrl", "TOOLBOX_APIM_URL")
A2A_APIM_URL = cfg.require("enterpriseAgentApimUrl", "ENTERPRISE_AGENT_APIM_URL")
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
    toolbox_call_count = 0
    specialist_call_count = 0

    async def observe_response(response: httpx.Response) -> None:
        nonlocal toolbox_call_count
        request = response.request
        if (
            request.method != "POST"
            or "/toolboxes/research/" not in request.url.path
            or not response.is_success
        ):
            return
        try:
            payload = json.loads(request.content)
        except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
            return
        messages = payload if isinstance(payload, list) else [payload]
        toolbox_call_count += sum(
            1
            for message in messages
            if isinstance(message, dict) and message.get("method") == "tools/call"
        )

    print("Scenario 5a - MAF model + Toolbox + A2A workflow")
    print(f"  Model   : {GATEWAY_URL}/{MODEL_API_PATH}")
    print(f"  Toolbox : {TOOLBOX_APIM_URL}")
    print(f"  A2A     : {A2A_APIM_URL}")
    try:
        model_client = OpenAIChatCompletionClient(
            model=MODEL,
            azure_endpoint=f"{GATEWAY_URL}/{MODEL_API_PATH}",
            api_version=API_VERSION,
            credential=credential,
        )
        async with httpx.AsyncClient(
            auth=EntraAuth(credential, INBOUND_SCOPE),
            follow_redirects=True,
            timeout=httpx.Timeout(180.0),
            event_hooks={"response": [observe_response]},
        ) as http_client:
            resolver = A2ACardResolver(
                httpx_client=http_client,
                base_url=A2A_APIM_URL,
                agent_card_path="agentCard/v1.0",
            )
            card = await resolver.get_agent_card()
            specialist = A2AAgent(agent_card=card, http_client=http_client)

            async def consult_enterprise_specialist(question: str) -> str:
                """Ask the APIM-published enterprise specialist agent for advice."""
                nonlocal specialist_call_count
                response = await specialist.run(question)
                text = getattr(response, "text", None)
                if not text and getattr(response, "messages", None):
                    text = response.messages[-1].text
                if not text:
                    raise RuntimeError("The APIM-published A2A specialist returned no text.")
                specialist_call_count += 1
                return str(text)

            toolbox = MCPStreamableHTTPTool(
                name="research_toolbox",
                url=TOOLBOX_APIM_URL,
                description="Foundry research Toolbox published through APIM.",
                http_client=http_client,
                approval_mode="never_require",
            )
            async with toolbox:
                baseline_toolbox_calls = toolbox_call_count
                agent = model_client.as_agent(
                    name="sc5-maf-combined-workflow",
                    instructions=(
                        "Always use both available capabilities. Research the factual part with "
                        "the research Toolbox, then ask the enterprise specialist for governance "
                        "advice. Clearly label both findings."
                    ),
                    tools=[toolbox, consult_enterprise_specialist],
                )
                result = await agent.run(
                    "What is Azure API Management, and why should an enterprise put agents "
                    "behind it?"
                )

        if toolbox_call_count <= baseline_toolbox_calls:
            raise RuntimeError("The combined workflow did not complete a Toolbox tools/call request.")
        if specialist_call_count < 1:
            raise RuntimeError("The combined workflow did not invoke the APIM-published A2A specialist.")
        text = (result.text or "").strip().replace("\n", " ")
        if not text:
            raise RuntimeError("The combined workflow returned an empty response.")
        print(f"  Calls   : Toolbox={toolbox_call_count - baseline_toolbox_calls}, A2A={specialist_call_count}")
        print(f"  PASS    : {text}")
    finally:
        await credential.close()


if __name__ == "__main__":
    asyncio.run(main())