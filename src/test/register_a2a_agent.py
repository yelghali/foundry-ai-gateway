"""
Register (or re-register) the dummy A2A specialist in LiteLLM's A2A Agent Gateway.

LiteLLM's A2A gateway is DB-backed: agents live in the PostgreSQL control plane
(store_model_in_db + DATABASE_URL, provided by the Postgres sidecar in
infra/litellm-foundry.bicep). This script POSTs the agent to /v1/agents so it is
re-exposed at POST {base}/a2a/<agent_name>. Re-run it after a LiteLLM replica
restart (the POC Postgres uses ephemeral storage).

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


def main() -> None:
    # Skip if an agent with this name is already registered.
    try:
        for agent in list_agents() or []:
            if isinstance(agent, dict) and agent.get("agent_name") == AGENT_NAME:
                print(f"Agent '{AGENT_NAME}' already registered -> {BASE_URL}/a2a/{AGENT_NAME}")
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
    print(f"Registered '{AGENT_NAME}' -> upstream {AGENT_URL}")
    print(f"Invoke it via LiteLLM at: POST {BASE_URL}/a2a/{AGENT_NAME}")
    print(resp.json())


if __name__ == "__main__":
    main()
