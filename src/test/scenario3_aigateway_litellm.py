"""
Scenario 3 — AI GATEWAY LITELLM (bring-your-own `ModelGateway` connection).

The client reaches the enterprise models through a self-hosted **LiteLLM** proxy
registered as a Foundry **ModelGateway** connection — the "bring your own gateway"
wiring. Same agent shape as Scenario 2, only the gateway behind the connection differs.

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

MODEL_CONNECTION = os.environ.get("SC3_MODEL_CONNECTION", "litellm-gateway")


def main() -> None:
    project = s.connect()
    results: list = []
    model_ref = f"{MODEL_CONNECTION}/{s.MODEL_NAME}"

    print("== Scenario 3 — AI GATEWAY LITELLM (ModelGateway connection) ==\n")

    # 3a — MODEL through the bring-your-own ModelGateway connection.
    s.run_subscenario(
        project, results, "sc3-aigateway-litellm-model",
        s.model_def(model_ref),
        s.QUESTION_MODEL,
    )

    # 3b — TOOL: MS Learn MCP behind LiteLLM, driven by the same litellm gateway model.
    if s.MCP_LITELLM_URL and s.MCP_LITELLM_CONN_ID:
        s.run_subscenario(
            project, results, "sc3-aigateway-litellm-tool",
            s.tool_def(model_ref, s.MCP_LITELLM_URL, s.MCP_LITELLM_CONN_ID, "LiteLLM (BYO gateway)"),
            s.QUESTION_TOOL,
        )

    # 3c — A2A: remote specialist via a RemoteA2A connection (native driver model).
    if s.A2A_DIRECT_URL and s.A2A_DIRECT_CONN_ID:
        s.run_subscenario(
            project, results, "sc3-aigateway-litellm-a2a",
            s.a2a_def(s.DRIVER_MODEL),
            s.QUESTION_A2A,
        )

    s.print_summary("Scenario 3 — AI GATEWAY LITELLM", results)


if __name__ == "__main__":
    main()
