"""
Scenario 1 (A2A) — Local tool + REMOTE A2A agent, both governed by the APIM gateway.

Mirrors agent_mcp_apim.py, but the remote capability is now an **A2A agent** (Agent2Agent
protocol) instead of an MCP server. The orchestrator agent keeps its **local** Python tool
(get_exchange_rate) AND gains a tool that delegates to a **remote A2A "specialist" agent**
reached THROUGH APIM. So the *same* gateway + subscription key front BOTH:
  - model (inference) traffic -> load-balanced Foundry backends   ({gateway}/inference)
  - agent (A2A) traffic       -> dummy specialist agent, via APIM ({gateway}/dummy-a2a)

This is the point of the demo: an AI gateway can govern *agent-to-agent* traffic, not just
models. The dummy A2A agent runs on Azure Container Apps, but every A2A call still flows
through APIM (auth, throttling, logging) exactly like the model calls.

A2A here is plain JSON-RPC 2.0 over HTTP (the wire format the spec defines), so we call it
with httpx — no extra SDK needed and guaranteed to match our stdlib dummy agent.

Prereqs:
  - APIM has the dummy A2A passthrough API (infra/a2a-agent.bicep -> "dummy-a2a").
  - pip install -r requirements.txt

Usage (PowerShell):
    $env:APIM_GATEWAY_URL = "https://apim-xxxx.azure-api.net"
    $env:APIM_API_KEY     = "<subscription key>"
    $env:A2A_URL_APIM     = "https://apim-xxxx.azure-api.net/dummy-a2a"   # optional override
    python agent_a2a_apim.py
"""
import asyncio
import os
import uuid

import httpx
from openai import AsyncAzureOpenAI
from agents import Agent, OpenAIChatCompletionsModel, Runner, function_tool, set_tracing_disabled

set_tracing_disabled(True)

GATEWAY_URL = os.environ["APIM_GATEWAY_URL"].rstrip("/")
API_KEY = os.environ["APIM_API_KEY"]
API_PATH = os.environ.get("INFERENCE_API_PATH", "inference")
MODEL = os.environ.get("MODEL", "gpt-4o-mini")
API_VERSION = os.environ.get("API_VERSION", "2024-10-21")
# Dummy A2A specialist agent, proxied by APIM (the "dummy-a2a" API in infra/a2a-agent.bicep).
A2A_URL = os.environ.get("A2A_URL_APIM", f"{GATEWAY_URL}/dummy-a2a")

# AzureOpenAI client pointed at the APIM inference API (Azure-style routes + api-key header).
client = AsyncAzureOpenAI(
    api_key=API_KEY,
    azure_endpoint=f"{GATEWAY_URL}/{API_PATH}",
    api_version=API_VERSION,
)


def call_a2a_agent(base_url: str, question: str, headers: dict) -> str:
    """Send an A2A 'message/send' (JSON-RPC 2.0) to an A2A agent and return its text reply."""
    payload = {
        "jsonrpc": "2.0",
        "id": uuid.uuid4().hex,
        "method": "message/send",
        "params": {
            "message": {
                "kind": "message",
                "role": "user",
                "messageId": uuid.uuid4().hex,
                "parts": [{"kind": "text", "text": question}],
            }
        },
    }
    resp = httpx.post(base_url, json=payload, headers=headers, timeout=30.0)
    resp.raise_for_status()
    data = resp.json()
    if "error" in data:
        return f"A2A error: {data['error']}"
    result = data.get("result", {})
    # Result is either a Task (with artifacts) or a direct Message (with parts).
    if result.get("kind") == "task":
        for artifact in result.get("artifacts", []):
            for part in artifact.get("parts", []):
                if part.get("kind") == "text":
                    return part["text"]
    for part in result.get("parts", []):
        if part.get("kind") == "text":
            return part["text"]
    return str(data)


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


@function_tool
def consult_specialist(question: str) -> str:
    """Ask the remote specialist agent (A2A) for expert advice. (REMOTE agent, via APIM)"""
    # The api-key header authenticates to APIM, which proxies the A2A JSON-RPC to the agent.
    return call_a2a_agent(A2A_URL, question, headers={"api-key": API_KEY})


async def main() -> None:
    agent = Agent(
        name="Orchestrator + FX Assistant",
        instructions=(
            "You are a helpful assistant. Use the local get_exchange_rate tool for currency "
            "conversions, and use the consult_specialist tool to delegate questions to the "
            "remote specialist agent. Always quote the specialist's answer verbatim."
        ),
        model=OpenAIChatCompletionsModel(model=MODEL, openai_client=client),
        tools=[get_exchange_rate, consult_specialist],   # LOCAL tool + REMOTE A2A agent (via APIM)
    )

    result = await Runner.run(
        agent,
        "Ask the specialist agent whether I should put a gateway in front of my agents, "
        "then convert 100 USD to EUR using the exchange-rate tool.",
    )
    print("Agent answer:\n", result.final_output)
    print("\n=> APIM governed BOTH the model calls and the A2A specialist-agent calls.")


if __name__ == "__main__":
    asyncio.run(main())
