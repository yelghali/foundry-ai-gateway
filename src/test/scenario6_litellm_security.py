"""Negative authentication checks for the optional LiteLLM scenario."""

import os
import sys

import httpx

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402

BASE_URL = cfg.require("litellmBaseUrl", "LITELLM_BASE_URL").rstrip("/")
A2A_URL = cfg.require("litellmA2aShimUrl", "LITELLM_A2A_URL").rstrip("/")
MODEL = cfg.get("litellmModel", "LITELLM_MODEL", "gpt-5.1").split("/", 1)[-1]
API_KEY = os.environ.get("LITELLM_API_KEY") or os.environ.get("LITELLM_MASTER_KEY")
if not API_KEY:
    raise SystemExit("Set LITELLM_API_KEY (preferred) or LITELLM_MASTER_KEY.")

MCP_INITIALIZE = {
    "jsonrpc": "2.0",
    "id": "security-check",
    "method": "initialize",
    "params": {
        "protocolVersion": "2025-03-26",
        "capabilities": {},
        "clientInfo": {"name": "scenario6-security", "version": "1.0"},
    },
}
MODEL_REQUEST = {
    "model": MODEL,
    "messages": [{"role": "user", "content": "Reply with OK."}],
    "max_tokens": 8,
}


def require_denied(label: str, response: httpx.Response) -> None:
    if response.status_code not in (401, 403):
        raise RuntimeError(f"{label} expected 401/403, got {response.status_code}.")
    print(f"  PASS : {label} -> {response.status_code}")


def main() -> None:
    targets = [
        (
            "model without bearer",
            "POST",
            f"{BASE_URL}/v1/chat/completions",
            {"json": MODEL_REQUEST},
        ),
        (
            "MCP without bearer",
            "POST",
            f"{BASE_URL}/mcp/",
            {
                "json": MCP_INITIALIZE,
                "headers": {"Accept": "application/json, text/event-stream"},
            },
        ),
        (
            "A2A card without bearer",
            "GET",
            f"{A2A_URL}/.well-known/agent-card.json",
            {},
        ),
    ]
    print("Scenario 6 - LiteLLM authentication boundaries")
    with httpx.Client(timeout=60.0, follow_redirects=False) as client:
        for label, method, url, kwargs in targets:
            require_denied(label, client.request(method, url, **kwargs))
            bad_kwargs = dict(kwargs)
            bad_headers = dict(bad_kwargs.get("headers", {}))
            bad_headers["Authorization"] = "Bearer invalid-scenario6-credential"
            bad_kwargs["headers"] = bad_headers
            require_denied(
                label.replace("without", "with invalid"),
                client.request(method, url, **bad_kwargs),
            )

        card = client.get(
            f"{A2A_URL}/.well-known/agent-card.json",
            headers={"Authorization": f"Bearer {API_KEY}"},
        )
        card.raise_for_status()
        print("  PASS : A2A card with configured bearer -> 200")


if __name__ == "__main__":
    main()
