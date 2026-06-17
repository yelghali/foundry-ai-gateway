"""
Scenario 4 (A2A) — Local tool + REMOTE A2A agent, with LiteLLM as the model gateway.

Mirrors agent_mcp_litellm.py, but the remote capability is an **A2A agent** (Agent2Agent
protocol). The orchestrator keeps its **local** Python tool (get_exchange_rate) AND gains a
tool that delegates to a **remote A2A "specialist" agent**.

  - model (inference) traffic -> load-balanced Foundry backends, via LiteLLM ({base_url}/chat/completions)
  - agent (A2A) traffic       -> dummy specialist agent

WHAT WORKS / WHAT DOESN'T (honest finding):
  LiteLLM *does* ship an "Agent Gateway (A2A)" that can proxy A2A agents at
  POST /a2a/{agent_id} with virtual-key auth, logging and spend tracking. BUT agent
  registration requires a DB-backed control plane (store_model_in_db + Postgres / the Admin
  UI / the /v1/agents API). This POC runs LiteLLM as a *file-config* Container App with NO
  database, so the A2A gateway is not wired up here.

  Therefore, in this sample LiteLLM governs the MODEL traffic, and the A2A call goes
  DIRECT to the dummy agent's Container App (set A2A_URL_DIRECT). To also govern the A2A
  hop with LiteLLM, enable store_model_in_db + a database and register the agent (see
  https://docs.litellm.ai/docs/a2a). Contrast this with the APIM variant
  (agent_a2a_apim.py), where the SAME gateway governs both model and A2A traffic today.

Prereqs:
  - LiteLLM running (cd ../litellm; docker compose up, or the deployed Container App).
  - The dummy A2A agent deployed (infra/a2a-agent.bicep) and its direct URL in A2A_URL_DIRECT.
  - pip install -r requirements.txt

Usage (PowerShell):
    $env:LITELLM_BASE_URL   = "https://ca-litellm-xxxx.azurecontainerapps.io"
    $env:LITELLM_MASTER_KEY = "sk-litellm-foundry-poc"
    $env:A2A_URL_DIRECT     = "https://ca-a2a-dummy-xxxx.azurecontainerapps.io"
    python agent_a2a_litellm.py
"""
import asyncio
import os
import uuid

import httpx
from openai import AsyncOpenAI
from agents import Agent, OpenAIChatCompletionsModel, Runner, function_tool, set_tracing_disabled

set_tracing_disabled(True)

BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000").rstrip("/")
API_KEY = os.environ["LITELLM_MASTER_KEY"]
MODEL = os.environ.get("MODEL", "gpt-4o-mini")
# Dummy A2A specialist agent. With no DB-backed LiteLLM A2A gateway in this POC, we call it
# directly. (If you register it in LiteLLM's A2A gateway, set this to {base}/a2a/<agent>.)
A2A_URL = os.environ.get("A2A_URL_DIRECT") or os.environ.get("A2A_URL_APIM")
if not A2A_URL:
    raise SystemExit("Set A2A_URL_DIRECT to the dummy agent's direct Container App URL.")
A2A_URL = A2A_URL.rstrip("/")

# AsyncOpenAI client pointed at the LiteLLM proxy (plain OpenAI-style routes).
client = AsyncOpenAI(base_url=BASE_URL, api_key=API_KEY)


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
    """Ask the remote specialist agent (A2A) for expert advice. (REMOTE agent, direct call)"""
    return call_a2a_agent(A2A_URL, question, headers={})


async def main() -> None:
    agent = Agent(
        name="Orchestrator + FX Assistant",
        instructions=(
            "You are a helpful assistant. Use the local get_exchange_rate tool for currency "
            "conversions, and use the consult_specialist tool to delegate questions to the "
            "remote specialist agent. Always quote the specialist's answer verbatim."
        ),
        model=OpenAIChatCompletionsModel(model=MODEL, openai_client=client),
        tools=[get_exchange_rate, consult_specialist],   # LOCAL tool + REMOTE A2A agent
    )

    result = await Runner.run(
        agent,
        "Ask the specialist agent whether I should put a gateway in front of my agents, "
        "then convert 100 USD to EUR using the exchange-rate tool.",
    )
    print("Agent answer:\n", result.final_output)
    print("\n=> LiteLLM governed the model calls; the A2A call went direct (see module docstring).")


if __name__ == "__main__":
    asyncio.run(main())
