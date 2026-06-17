"""
Scenario 3 — AI GATEWAY BYO LITELLM (bring-your-own `ModelGateway` connection).

Runs against its OWN client Foundry account (client-foundry-sc3). The client reaches the
enterprise models through a self-hosted **LiteLLM** proxy registered as a Foundry
**ModelGateway** connection — the "bring your own gateway" wiring. Same agent shape as
Scenario 2, only the gateway behind the connection differs.

Sub-scenarios (same remote targets as every scenario):
    3a  MODEL  litellm-gateway/<model>        -> enterprise gpt-4o-mini through LiteLLM.
    3b  TOOL   MS Learn MCP behind LiteLLM    -> MCPTool governed by LiteLLM (mslearn-mcp-litellm),
                                                 driven by the litellm-gateway model: model AND
                                                 tool through the same LiteLLM gateway.
    3c  A2A    remote specialist agent        -> RemoteA2A connection (dummy-a2a-direct),
                                                 orchestrated by the native driver model.
                                                 (A2A routed THROUGH LiteLLM is blocked — LiteLLM
                                                 serves its agent card under a path, not the host
                                                 root Foundry requires — so the client reaches the
                                                 A2A agent directly. See the workshop findings.)

Run:
    python scenario3_aigateway_litellm.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_lib as s  # noqa: E402
import scenario_config as cfg  # noqa: E402

ENDPOINT = cfg.require("sc3ProjectEndpoint", "SC3_PROJECT_ENDPOINT")
DRIVER_MODEL = cfg.get("sc3DriverModel", "SC3_DRIVER_MODEL", "gpt-4o-mini")
MODEL_REF = cfg.get("sc3Model", "SC3_MODEL", "litellm-gateway/gpt-4o-mini")
MCP_LITELLM_URL = cfg.get("sc3McpLitellmUrl", "SC3_MCP_LITELLM_URL")
MCP_LITELLM_CONN_ID = cfg.get("sc3McpLitellmConnId", "SC3_MCP_LITELLM_CONN_ID")
A2A_URL = cfg.get("a2aDirectUrl", "SC3_A2A_URL")
A2A_CONN_ID = cfg.get("sc3A2aConnId", "SC3_A2A_CONN_ID")


def main() -> None:
    project = s.connect(ENDPOINT)
    results: list = []

    print("== Scenario 3 — AI GATEWAY BYO LITELLM (ModelGateway connection) ==\n")

    # 3a — MODEL through the bring-your-own ModelGateway connection.
    s.run_subscenario(
        project, results, "sc3-aigateway-litellm-model",
        s.model_def(MODEL_REF),
        s.QUESTION_MODEL,
    )

    # 3b — TOOL: MS Learn MCP behind LiteLLM, driven by the same litellm gateway model.
    if MCP_LITELLM_URL and MCP_LITELLM_CONN_ID:
        s.run_subscenario(
            project, results, "sc3-aigateway-litellm-tool",
            s.tool_def(MODEL_REF, MCP_LITELLM_URL, MCP_LITELLM_CONN_ID, "LiteLLM (BYO gateway)"),
            s.QUESTION_TOOL,
        )

    # 3c — A2A: remote specialist via a RemoteA2A connection (native driver model).
    if A2A_URL and A2A_CONN_ID:
        s.run_subscenario(
            project, results, "sc3-aigateway-litellm-a2a",
            s.a2a_def(DRIVER_MODEL, A2A_URL, A2A_CONN_ID),
            s.QUESTION_A2A,
        )

    s.print_summary("Scenario 3 — AI GATEWAY BYO LITELLM", results)


if __name__ == "__main__":
    main()
