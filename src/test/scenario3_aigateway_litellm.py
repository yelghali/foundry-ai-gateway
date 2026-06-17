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
    3c  A2A    remote specialist agent        -> RemoteA2A connection routed THROUGH LiteLLM's
                                                 A2A Agent Gateway when available (dummy-a2a-litellm,
                                                 a host-root shim that forwards message/send to
                                                 {litellm}/a2a/dummy-specialist); falls back to the
                                                 direct host-root connection otherwise. Orchestrated
                                                 by the native driver model.

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
# Prefer the through-LiteLLM A2A path (shim) when it has been deployed; else go direct.
A2A_LITELLM_URL = cfg.get("a2aLitellmUrl", "SC3_A2A_LITELLM_URL")
A2A_LITELLM_CONN_ID = cfg.get("sc3A2aLitellmConnId", "SC3_A2A_LITELLM_CONN_ID")
A2A_DIRECT_URL = cfg.get("a2aDirectUrl", "SC3_A2A_URL")
A2A_DIRECT_CONN_ID = cfg.get("sc3A2aConnId", "SC3_A2A_CONN_ID")


def main() -> None:
    project = s.connect(ENDPOINT)
    results: list = []

    s.print_header(
        "Scenario 3 — AI GATEWAY BYO LITELLM (ModelGateway connection)",
        [
            "Model and tool both ride a self-hosted LiteLLM proxy registered as a Foundry",
            "ModelGateway connection; the A2A leg is routed through LiteLLM's A2A gateway too.",
        ],
    )

    # 3a — MODEL through the bring-your-own ModelGateway connection.
    s.run_subscenario(
        project, results, "sc3-aigateway-litellm-model",
        s.model_def(MODEL_REF),
        s.QUESTION_MODEL,
        title="3a  MODEL  — LiteLLM ModelGateway connection (bring your own)",
        calls=[("model conn", MODEL_REF)],
    )

    # 3b — TOOL: MS Learn MCP behind LiteLLM, driven by the same litellm gateway model.
    if MCP_LITELLM_URL and MCP_LITELLM_CONN_ID:
        s.run_subscenario(
            project, results, "sc3-aigateway-litellm-tool",
            s.tool_def(MODEL_REF, MCP_LITELLM_URL, MCP_LITELLM_CONN_ID, "LiteLLM (BYO gateway)"),
            s.QUESTION_TOOL,
            title="3b  TOOL   — MS Learn MCP via LiteLLM (BYO gateway)",
            calls=[
                ("model conn", MODEL_REF),
                ("MCP url", MCP_LITELLM_URL),
                ("MCP conn", s.short_conn(MCP_LITELLM_CONN_ID)),
            ],
        )

    # 3c — A2A: remote specialist routed THROUGH LiteLLM's A2A gateway when available.
    if A2A_LITELLM_URL and A2A_LITELLM_CONN_ID:
        s.run_subscenario(
            project, results, "sc3-aigateway-litellm-a2a",
            s.a2a_def(
                DRIVER_MODEL, A2A_LITELLM_URL, A2A_LITELLM_CONN_ID,
                description="A remote A2A specialist reached through the LiteLLM A2A gateway.",
            ),
            s.QUESTION_A2A,
            title="3c  A2A    — remote specialist THROUGH LiteLLM (RemoteA2A via A2A gateway)",
            calls=[
                ("driver model", DRIVER_MODEL),
                ("A2A url", A2A_LITELLM_URL),
                ("A2A conn", s.short_conn(A2A_LITELLM_CONN_ID)),
            ],
        )
    elif A2A_DIRECT_URL and A2A_DIRECT_CONN_ID:
        s.run_subscenario(
            project, results, "sc3-aigateway-litellm-a2a",
            s.a2a_def(DRIVER_MODEL, A2A_DIRECT_URL, A2A_DIRECT_CONN_ID),
            s.QUESTION_A2A,
            title="3c  A2A    — remote specialist (RemoteA2A connection, direct host root)",
            calls=[
                ("driver model", DRIVER_MODEL),
                ("A2A url", A2A_DIRECT_URL),
                ("A2A conn", s.short_conn(A2A_DIRECT_CONN_ID)),
            ],
        )

    s.print_summary("Scenario 3 — AI GATEWAY BYO LITELLM", results)


if __name__ == "__main__":
    main()
