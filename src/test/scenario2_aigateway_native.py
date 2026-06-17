"""
Scenario 2 — AI GATEWAY NATIVE (APIM `ApiManagement` connection).

Runs against its OWN client Foundry account (client-foundry-sc2). The client reaches the
enterprise models through Foundry's first-class **ApiManagement** connection — the "native
AI Gateway" wiring. Foundry knows APIM's Azure-OpenAI conventions and builds the
`/deployments/{name}/chat/completions` path for you.

Sub-scenarios (same remote targets as every scenario):
    2a  MODEL  apim-gateway-mi/<model>        -> managed-identity FIRST (AAD connection),
        MODEL  apim-gateway/<model>           -> fall back to the subscription-key connection
                                                 (enterprise gpt-4o-mini through APIM, load
                                                 balanced across 2 regions).
    2b  TOOL   MS Learn MCP behind APIM       -> MCPTool governed by APIM (mslearn-mcp-apim),
                                                 driven by the working native gateway model.
    2c  A2A    remote specialist agent        -> RemoteA2A connection (dummy-a2a-direct),
                                                 orchestrated by the native driver model.

Run:
    python scenario2_aigateway_native.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_lib as s  # noqa: E402
import scenario_config as cfg  # noqa: E402

ENDPOINT = cfg.require("sc2ProjectEndpoint", "SC2_PROJECT_ENDPOINT")
DRIVER_MODEL = cfg.get("sc2DriverModel", "SC2_DRIVER_MODEL", "gpt-4o-mini")
MI_MODEL = cfg.get("sc2MiModel", "SC2_MI_MODEL", "apim-gateway-mi/gpt-4o-mini")
KEY_MODEL = cfg.get("sc2Model", "SC2_MODEL", "apim-gateway/gpt-4o-mini")
MCP_APIM_URL = cfg.get("mcpApimUrl", "SC2_MCP_APIM_URL")
MCP_APIM_CONN_ID = cfg.get("sc2McpApimConnId", "SC2_MCP_APIM_CONN_ID")
A2A_URL = cfg.get("a2aDirectUrl", "SC2_A2A_URL")
A2A_CONN_ID = cfg.get("sc2A2aConnId", "SC2_A2A_CONN_ID")


def main() -> None:
    project = s.connect(ENDPOINT)
    results: list = []

    print("== Scenario 2 — AI GATEWAY NATIVE (APIM ApiManagement connection) ==")
    print("   2a tries the managed-identity (AAD) connection first, then falls back to the")
    print("   subscription-key connection. The tool leg is driven by whichever model worked.\n")

    # 2a — MODEL: native ApiManagement connection, managed-identity FIRST, key fallback.
    mi_ok = s.run_subscenario(
        project, results, "sc2-aigateway-native-model-mi",
        s.model_def(MI_MODEL),
        s.QUESTION_MODEL,
    )
    working_model = MI_MODEL if mi_ok else KEY_MODEL
    if not mi_ok:
        print("   -> managed-identity model leg was not accepted; trying the key connection.")
        s.run_subscenario(
            project, results, "sc2-aigateway-native-model-key",
            s.model_def(KEY_MODEL),
            s.QUESTION_MODEL,
        )

    # 2b — TOOL: MS Learn MCP behind APIM, driven by the model that worked.
    if MCP_APIM_URL and MCP_APIM_CONN_ID:
        s.run_subscenario(
            project, results, "sc2-aigateway-native-tool",
            s.tool_def(working_model, MCP_APIM_URL, MCP_APIM_CONN_ID, "APIM (native AI Gateway)"),
            s.QUESTION_TOOL,
        )

    # 2c — A2A: remote specialist via a RemoteA2A connection (native driver model).
    if A2A_URL and A2A_CONN_ID:
        s.run_subscenario(
            project, results, "sc2-aigateway-native-a2a",
            s.a2a_def(DRIVER_MODEL, A2A_URL, A2A_CONN_ID),
            s.QUESTION_A2A,
        )

    s.print_summary("Scenario 2 — AI GATEWAY NATIVE", results)


if __name__ == "__main__":
    main()
