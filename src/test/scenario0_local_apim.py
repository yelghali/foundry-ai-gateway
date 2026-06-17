"""
Scenario 0 — LOCAL AGENTS (Microsoft Agent Framework) through APIM, no Foundry.

The other three scenarios all run *inside* Foundry's Agent Service: Foundry hosts the
agent and reaches the gateways through Foundry **connections**. Scenario 0 is the
**client-orchestrated** baseline: the agent is an ordinary **in-memory Microsoft Agent
Framework (MAF) agent** running in this process — there is **no Foundry account and no
Foundry connection at all**. It reaches the same three remote targets straight through
the **APIM** AI gateway, governed by one subscription key.

Sub-scenarios (same shape as scenarios 1-3: model -> tool -> A2A):
    0a  MODEL  APIM inference API           -> MAF agent's chat backend is the APIM
                                               load-balanced gateway (Part 1).
    0b  TOOL   MS Learn MCP via APIM        -> MAF MCPStreamableHTTPTool against the
                                               `learn-mcp` passthrough API (Part 2).
    0c  A2A    remote specialist via APIM   -> a local function tool sends A2A JSON-RPC
                                               through the `dummy-a2a` passthrough API (Part 2b).

So the *same* APIM gateway + subscription key front model, tool (MCP) and agent (A2A)
traffic for a plain client app — no Foundry in the picture.

Prereqs:
  - APIM has the inference, `learn-mcp` and `dummy-a2a` passthrough APIs
    (infra/main.bicep + infra/a2a-agent.bicep).
  - pip install -r requirements.txt   (installs agent-framework + mcp + httpx)

Usage (PowerShell):
    $env:APIM_GATEWAY_URL = "https://apim-xxxx.azure-api.net"
    $env:APIM_API_KEY     = "<subscription key>"
    python scenario0_local_apim.py
"""

import asyncio
import os
import uuid

import httpx
from agent_framework import MCPStreamableHTTPTool
from agent_framework.openai import OpenAIChatCompletionClient

GATEWAY_URL = os.environ["APIM_GATEWAY_URL"].rstrip("/")
API_KEY = os.environ["APIM_API_KEY"]
API_PATH = os.environ.get("INFERENCE_API_PATH", "inference")
MODEL = os.environ.get("MODEL", "gpt-4o-mini")
API_VERSION = os.environ.get("API_VERSION", "2024-10-21")
MCP_PATH = os.environ.get("MCP_API_PATH", "learn-mcp/mcp")
MCP_URL = f"{GATEWAY_URL}/{MCP_PATH}"
A2A_URL = os.environ.get("A2A_URL_APIM", f"{GATEWAY_URL}/dummy-a2a")

QUESTION_MODEL = "In one sentence, what does an AI gateway do?"
QUESTION_TOOL = "Search Microsoft Learn: what is Azure API Management? Answer in one sentence."
QUESTION_A2A = "Ask the specialist: should I put a gateway in front of my agents?"


def make_client() -> OpenAIChatCompletionClient:
    """A MAF chat client whose backend is the APIM inference API (Azure-style routes + api-key)."""
    return OpenAIChatCompletionClient(
        model=MODEL,
        azure_endpoint=f"{GATEWAY_URL}/{API_PATH}",
        api_key=API_KEY,
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
    if result.get("kind") == "task":
        for artifact in result.get("artifacts", []):
            for part in artifact.get("parts", []):
                if part.get("kind") == "text":
                    return part["text"]
    for part in result.get("parts", []):
        if part.get("kind") == "text":
            return part["text"]
    return str(data)


def consult_specialist(question: str) -> str:
    """Ask the remote specialist agent (A2A) for expert advice. (REMOTE agent, via APIM)"""
    return call_a2a_agent(A2A_URL, question, headers={"api-key": API_KEY})


def _record(results, label, ok, detail) -> None:
    results.append((label, ok, detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}: {detail[:180]}")


async def run_model(client, results) -> None:
    """0a — a plain model call through the APIM gateway."""
    label = "sc0-local-apim-model"
    try:
        agent = client.as_agent(
            name="sc0-model",
            instructions="You are a concise assistant. Answer in one sentence.",
        )
        result = await agent.run(QUESTION_MODEL)
        text = (result.text or "").strip().replace("\n", " ")
        _record(results, label, True, text)
    except Exception as exc:  # noqa: BLE001 - report honestly, keep going
        _record(results, label, False, f"{type(exc).__name__}: {exc}")


async def run_tool(client, results) -> None:
    """0b — an MS Learn MCP tool call governed by APIM."""
    label = "sc0-local-apim-tool"
    try:
        # Pass our own httpx client so the api-key header authenticates to APIM on every MCP request.
        async with httpx.AsyncClient(headers={"api-key": API_KEY}, follow_redirects=True) as http_client:
            mcp = MCPStreamableHTTPTool(
                name="mslearn",
                url=MCP_URL,
                description="Microsoft Learn docs, governed by APIM.",
                http_client=http_client,
                approval_mode="never_require",
            )
            async with mcp:
                agent = client.as_agent(
                    name="sc0-tool",
                    instructions="Use the mslearn MCP tool to answer. Be concise.",
                    tools=mcp,
                )
                result = await agent.run(QUESTION_TOOL)
        text = (result.text or "").strip().replace("\n", " ")
        _record(results, label, True, text)
    except Exception as exc:  # noqa: BLE001 - report honestly, keep going
        _record(results, label, False, f"{type(exc).__name__}: {exc}")


async def run_a2a(client, results) -> None:
    """0c — an A2A call to the remote specialist, routed through APIM."""
    label = "sc0-local-apim-a2a"
    try:
        agent = client.as_agent(
            name="sc0-a2a",
            instructions=(
                "Use the consult_specialist tool to ask the remote specialist agent, then "
                "quote its answer. Be concise."
            ),
            tools=consult_specialist,
        )
        result = await agent.run(QUESTION_A2A)
        text = (result.text or "").strip().replace("\n", " ")
        _record(results, label, True, text)
    except Exception as exc:  # noqa: BLE001 - report honestly, keep going
        _record(results, label, False, f"{type(exc).__name__}: {exc}")


async def main() -> None:
    client = make_client()
    results: list = []

    print("== Scenario 0 — LOCAL AGENTS (Microsoft Agent Framework) via APIM ==")
    print("   In-memory MAF agents, NO Foundry account / connection — model, tool and A2A")
    print("   all reach the enterprise through the APIM gateway on one subscription key.\n")

    await run_model(client, results)
    await run_tool(client, results)
    await run_a2a(client, results)

    print("\n== Scenario 0 — LOCAL AGENTS via APIM — SUMMARY ==")
    for label, ok, detail in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {label:<30} {detail[:120]}")


if __name__ == "__main__":
    asyncio.run(main())
