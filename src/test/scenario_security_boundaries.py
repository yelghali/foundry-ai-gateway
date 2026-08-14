"""Verify every workshop APIM surface rejects missing and wrong-audience tokens."""

import os
import sys
import uuid

import httpx
from azure.identity import DefaultAzureCredential

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402

GATEWAY_URL = cfg.require("apimGatewayUrl", "APIM_GATEWAY_URL").rstrip("/")
MODEL = cfg.get("enterpriseModel", "MODEL", "gpt-4o-mini")
API_VERSION = cfg.get("inferenceApiVersion", "API_VERSION", "2024-10-21")
MCP_URL = cfg.require("rawMcpApimUrl", "MCP_APIM_URL")
TOOLBOX_URL = cfg.require("toolboxApimUrl", "TOOLBOX_APIM_URL")
A2A_CARD_URL = cfg.require("enterpriseAgentApimCardUrl", "ENTERPRISE_AGENT_APIM_CARD_URL")

MODEL_URL = (
    f"{GATEWAY_URL}/inference-mi/openai/deployments/{MODEL}/chat/completions"
    f"?api-version={API_VERSION}"
)
MODEL_BODY = {
    "messages": [{"role": "user", "content": "ping"}],
    "max_tokens": 1,
}
MCP_BODY = {
    "jsonrpc": "2.0",
    "id": uuid.uuid4().hex,
    "method": "initialize",
    "params": {
        "protocolVersion": "2025-03-26",
        "capabilities": {},
        "clientInfo": {"name": "security-boundary-test", "version": "1.0"},
    },
}


def assert_unauthorized(
    client: httpx.Client,
    label: str,
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    body: dict | None = None,
) -> None:
    response = client.request(method, url, headers=headers, json=body)
    if response.status_code != 401:
        raise AssertionError(
            f"{label}: expected 401, got {response.status_code}: {response.text[:200]}"
        )
    print(f"  PASS    : {label} -> 401")


def main() -> None:
    credential = DefaultAzureCredential(process_timeout=cfg.credential_process_timeout())
    wrong_token = credential.get_token("https://management.azure.com/.default").token
    wrong_headers = {"Authorization": f"Bearer {wrong_token}"}
    checks = [
        ("model", "POST", MODEL_URL, MODEL_BODY),
        ("raw MCP", "POST", MCP_URL, MCP_BODY),
        ("Toolbox MCP", "POST", TOOLBOX_URL, MCP_BODY),
        ("A2A card", "GET", A2A_CARD_URL, None),
    ]

    print("APIM security-boundary checks")
    with httpx.Client(timeout=60.0) as client:
        for label, method, url, body in checks:
            assert_unauthorized(client, f"anonymous {label}", method, url, body=body)
            assert_unauthorized(
                client,
                f"wrong-audience {label}",
                method,
                url,
                headers=wrong_headers,
                body=body,
            )


if __name__ == "__main__":
    main()