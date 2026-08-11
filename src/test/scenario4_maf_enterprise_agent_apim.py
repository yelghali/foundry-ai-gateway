"""Scenario 4a - local Microsoft Agent Framework consumes a Foundry agent through APIM.

Authentication is keyless on both hops:
  local DefaultAzureCredential -> APIM (Entra token)
  APIM managed identity        -> enterprise Foundry A2A endpoint

The Entra token is attached by an httpx auth flow so it covers BOTH agent-card discovery and
every JSON-RPC call. (a2a-sdk's AuthInterceptor is driven by security schemes declared on the
agent card, which the Foundry-generated card does not publish.)
"""

import asyncio

import os
import sys

import httpx
from a2a.client import A2ACardResolver
from agent_framework.a2a import A2AAgent
from azure.identity.aio import DefaultAzureCredential

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402

A2A_APIM_URL = cfg.require("enterpriseAgentApimUrl", "ENTERPRISE_AGENT_APIM_URL")
INBOUND_SCOPE = cfg.get(
    "enterpriseAgentInboundScope",
    "ENTERPRISE_AGENT_INBOUND_SCOPE",
    "https://cognitiveservices.azure.com/.default",
)


class EntraAuth(httpx.Auth):
    """Attach a fresh Entra token to every request; no key is stored anywhere."""

    def __init__(self, credential: DefaultAzureCredential, scope: str) -> None:
        self._credential = credential
        self._scope = scope

    async def async_auth_flow(self, request):
        token = await self._credential.get_token(self._scope)
        request.headers["Authorization"] = f"Bearer {token.token}"
        yield request


async def main() -> None:
    credential = DefaultAzureCredential(process_timeout=cfg.credential_process_timeout())
    print("Scenario 4a - local MAF -> APIM -> enterprise Foundry agent")
    print(f"  A2A URL : {A2A_APIM_URL}")
    print(f"  Auth    : DefaultAzureCredential -> {INBOUND_SCOPE} (no key)")
    try:
        async with httpx.AsyncClient(
            auth=EntraAuth(credential, INBOUND_SCOPE),
            timeout=httpx.Timeout(120.0),
        ) as http_client:
            # Discovery also crosses APIM: the gateway rewrites the card so the advertised
            # runtime URL stays on the gateway instead of pointing at Foundry directly.
            # a2a-sdk 1.x expects the v1.0 card shape, so ask for that version explicitly;
            # the well-known aliases serve the v0.3 shape for Foundry Agent Service.
            resolver = A2ACardResolver(
                httpx_client=http_client,
                base_url=A2A_APIM_URL,
                agent_card_path="agentCard/v1.0",
            )
            card = await resolver.get_agent_card()
            advertised = (
                card.supported_interfaces[0].url
                if getattr(card, "supported_interfaces", None)
                else A2A_APIM_URL
            )
            print(f"  Card    : {card.name} -> advertises {advertised}")

            # Not used as an async context manager on purpose: agent_framework_a2a 1.0.0b260604
            # raises AttributeError in __aexit__ when the caller supplies its own http_client.
            # The httpx client above owns the connection lifetime instead.
            agent = A2AAgent(agent_card=card, http_client=http_client)
            response = await agent.run(
                "In two sentences, why should enterprise agents be exposed through APIM?"
            )
            text = getattr(response, "text", None)
            if not text and getattr(response, "messages", None):
                text = response.messages[-1].text
            print(f"  PASS    : {text or response}")
    finally:
        await credential.close()


if __name__ == "__main__":
    asyncio.run(main())
