"""
Register (or re-register) the dummy A2A specialist in LiteLLM's A2A Agent Gateway.

LiteLLM's A2A gateway is DB-backed. This script POSTs the agent to /v1/agents
and reports the UUID-based endpoint returned by the live registry:
POST {base}/a2a/<agent_id>.

Usage (PowerShell):
    $env:LITELLM_BASE_URL   = "https://ca-litellm-xxxx.azurecontainerapps.io"
    $env:LITELLM_MASTER_KEY = "sk-litellm-foundry-poc"
    $env:A2A_URL_DIRECT     = "https://ca-a2a-dummy-xxxx.azurecontainerapps.io"
    python register_a2a_agent.py
"""
import os
import sys

import httpx

BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000").rstrip("/")
MASTER_KEY = os.environ["LITELLM_MASTER_KEY"]
AGENT_NAME = os.environ.get("A2A_AGENT_NAME", "dummy-specialist")
AGENT_URL = os.environ.get("A2A_URL_DIRECT")
if not AGENT_URL:
    raise SystemExit("Set A2A_URL_DIRECT to the dummy agent's direct Container App URL.")
AGENT_URL = AGENT_URL.rstrip("/")

headers = {"Authorization": f"Bearer {MASTER_KEY}", "Content-Type": "application/json"}


def list_agents() -> list:
    resp = httpx.get(f"{BASE_URL}/v1/agents", headers=headers, timeout=30.0)
    resp.raise_for_status()
    data = resp.json()
    return data.get("agents", data) if isinstance(data, dict) else data


def report_agent(agent: dict) -> None:
    agent_id = agent.get("agent_id") or agent.get("id")
    if not agent_id:
        raise SystemExit(f"Registered agent has no ID: {agent}")
    print(f"Agent '{AGENT_NAME}' registered -> {BASE_URL}/a2a/{agent_id}")
    # Stable machine-readable output consumed by infra/deploy-litellm-scenario.ps1.
    print(f"A2A_AGENT_ID={agent_id}")


def main() -> None:
    # Skip if an agent with this name is already registered.
    try:
        for agent in list_agents() or []:
            if isinstance(agent, dict) and agent.get("agent_name") == AGENT_NAME:
                report_agent(agent)
                return
    except Exception as exc:  # listing is best-effort; fall through to register
        print(f"(could not list existing agents: {exc})", file=sys.stderr)

    payload = {
        "agent_name": AGENT_NAME,
        "agent_card_params": {"url": AGENT_URL},
    }
    resp = httpx.post(f"{BASE_URL}/v1/agents", json=payload, headers=headers, timeout=60.0)
    if resp.status_code >= 400:
        raise SystemExit(f"Registration failed ({resp.status_code}): {resp.text}")
    for agent in list_agents() or []:
        if isinstance(agent, dict) and agent.get("agent_name") == AGENT_NAME:
            report_agent(agent)
            return
    raise SystemExit("Registration succeeded, but the agent was not returned by /v1/agents.")


if __name__ == "__main__":
    main()
