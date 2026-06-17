"""
Scenario 2 — AI GATEWAY NATIVE (APIM `ApiManagement` connection).

The client reaches the enterprise models through Foundry's first-class **ApiManagement**
connection — the "native AI Gateway" wiring. Foundry knows APIM's Azure-OpenAI
conventions and builds the `/deployments/{name}/chat/completions` path for you.

Sub-scenarios (same remote targets as every scenario):
    2a  MODEL  apim-gateway/<model>           -> enterprise gpt-4o-mini through APIM
                                                 (load balanced across 2 regions).
    2b  TOOL   MS Learn MCP behind APIM       -> MCPTool governed by APIM (mslearn-mcp-apim),
                                                 driven by the apim-gateway model: model AND
                                                 tool through the same APIM gateway.
    2c  A2A    remote specialist agent        -> RemoteA2A connection (dummy-a2a-direct),
                                                 orchestrated by the native driver model.

Run:
    python scenario2_aigateway_native.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_lib as s  # noqa: E402

MODEL_CONNECTION = os.environ.get("SC2_MODEL_CONNECTION", "apim-gateway")


def main() -> None:
    project = s.connect()
    results: list = []
    model_ref = f"{MODEL_CONNECTION}/{s.MODEL_NAME}"

    print("== Scenario 2 — AI GATEWAY NATIVE (APIM ApiManagement connection) ==\n")

    # 2a — MODEL through the native ApiManagement connection.
    s.run_subscenario(
        project, results, "sc2-aigateway-native-model",
        s.model_def(model_ref),
        s.QUESTION_MODEL,
    )

    # 2b — TOOL: MS Learn MCP behind APIM, driven by the same native gateway model.
    if s.MCP_APIM_URL and s.MCP_APIM_CONN_ID:
        s.run_subscenario(
            project, results, "sc2-aigateway-native-tool",
            s.tool_def(model_ref, s.MCP_APIM_URL, s.MCP_APIM_CONN_ID, "APIM (native AI Gateway)"),
            s.QUESTION_TOOL,
        )

    # 2c — A2A: remote specialist via a RemoteA2A connection (native driver model).
    if s.A2A_DIRECT_URL and s.A2A_DIRECT_CONN_ID:
        s.run_subscenario(
            project, results, "sc2-aigateway-native-a2a",
            s.a2a_def(s.DRIVER_MODEL),
            s.QUESTION_A2A,
        )

    s.print_summary("Scenario 2 — AI GATEWAY NATIVE", results)


if __name__ == "__main__":
    main()
