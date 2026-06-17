"""
Scenario 1 — CUSTOM (APIM).

The client reaches the enterprise resources with *custom* connections: generic
`CustomKeys` connections that hold the raw APIM gateway URL plus the subscription key.
This is the "when the first-class connection isn't available, just point at the gateway
URL" fallback.

Sub-scenarios (same remote targets as every scenario):
    1a  MODEL  apim-custom/<model>            -> EXPECTED FAIL: a CustomKeys connection
                                                 cannot back a model (Foundry serves models
                                                 only via ApiManagement / ModelGateway).
    1b  TOOL   MS Learn MCP behind APIM       -> CustomKeys connection (mslearn-mcp-apim).
                                                 Driven by the native model because 1a's
                                                 model connection can't serve a model.
    1c  A2A    remote specialist agent        -> RemoteA2A connection (dummy-a2a-direct),
                                                 orchestrated by the native driver model.

Run:
    python scenario1_custom_apim.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_lib as s  # noqa: E402

MODEL_CONNECTION = os.environ.get("SC1_MODEL_CONNECTION", "apim-custom")


def main() -> None:
    project = s.connect()
    results: list = []

    print("== Scenario 1 — CUSTOM (APIM) ==")
    print("   1a (model) is an EXPECTED FAIL: a CustomKeys connection cannot back a model;")
    print("   Foundry serves models only via the ApiManagement / ModelGateway categories.")
    print("   CustomKeys connections are the right tool for the 1b TOOL leg instead.\n")

    # 1a — MODEL through the custom connection (expected fail).
    s.run_subscenario(
        project, results, "sc1-custom-apim-model",
        s.model_def(f"{MODEL_CONNECTION}/{s.MODEL_NAME}"),
        s.QUESTION_MODEL,
    )

    # 1b — TOOL: MS Learn MCP governed by APIM via a CustomKeys connection.
    if s.MCP_APIM_URL and s.MCP_APIM_CONN_ID:
        s.run_subscenario(
            project, results, "sc1-custom-apim-tool",
            s.tool_def(s.DRIVER_MODEL, s.MCP_APIM_URL, s.MCP_APIM_CONN_ID, "APIM (custom connection)"),
            s.QUESTION_TOOL,
        )

    # 1c — A2A: remote specialist via a RemoteA2A connection (native driver model).
    if s.A2A_DIRECT_URL and s.A2A_DIRECT_CONN_ID:
        s.run_subscenario(
            project, results, "sc1-custom-apim-a2a",
            s.a2a_def(s.DRIVER_MODEL),
            s.QUESTION_A2A,
        )

    s.print_summary("Scenario 1 — CUSTOM (APIM)", results)


if __name__ == "__main__":
    main()
