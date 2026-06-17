"""
Scenario 1 — CUSTOM (APIM), subscription-KEY custom connection.

Runs against its OWN client Foundry account (client-foundry-sc1). The client reaches the
enterprise resources with *custom* connections that carry the APIM subscription KEY — the
"bring the gateway URL + key yourself" pattern. The model leg uses an `ApiManagement`
connection (the supported key path; a raw `CustomKeys` connection cannot back a model),
and the tool/A2A legs use connections too:
    1a  MODEL  apim-custom-key/<model>      -> ApiManagement connection, subscription KEY
    1b  TOOL   MS Learn MCP behind APIM     -> CustomKeys connection (mslearn-mcp-apim),
                                               driven by the native driver model
    1c  A2A    remote specialist agent      -> RemoteA2A connection (dummy-a2a-direct),
                                               orchestrated by the native driver model

Run:
    python scenario1_custom_apim.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_lib as s  # noqa: E402
import scenario_config as cfg  # noqa: E402

ENDPOINT = cfg.require("sc1ProjectEndpoint", "SC1_PROJECT_ENDPOINT")
DRIVER_MODEL = cfg.get("sc1DriverModel", "SC1_DRIVER_MODEL", "gpt-4o-mini")
KEY_MODEL = cfg.get("sc1CustomKeyModel", "SC1_CUSTOM_KEY_MODEL", "apim-custom-key/gpt-4o-mini")
MCP_APIM_URL = cfg.get("mcpApimUrl", "SC1_MCP_APIM_URL")
MCP_APIM_CONN_ID = cfg.get("sc1McpApimConnId", "SC1_MCP_APIM_CONN_ID")
A2A_URL = cfg.get("a2aDirectUrl", "SC1_A2A_URL")
A2A_CONN_ID = cfg.get("sc1A2aConnId", "SC1_A2A_CONN_ID")


def main() -> None:
    project = s.connect(ENDPOINT)
    results: list = []

    s.print_header(
        "Scenario 1 — CUSTOM (APIM), subscription-KEY custom connection",
        [
            "The model leg uses an ApiManagement connection carrying the APIM subscription",
            "key; the tool leg uses a CustomKeys connection; the A2A leg uses a RemoteA2A",
            "connection — all three calls are made through Foundry connections.",
        ],
    )

    # 1a — MODEL: custom ApiManagement connection authenticated by the subscription key.
    s.run_subscenario(
        project, results, "sc1-custom-apim-model-key",
        s.model_def(KEY_MODEL),
        s.QUESTION_MODEL,
        title="1a  MODEL  — ApiManagement connection (APIM subscription key)",
        calls=[("model conn", KEY_MODEL)],
    )

    # 1b — TOOL: MS Learn MCP governed by APIM via a CustomKeys connection.
    if MCP_APIM_URL and MCP_APIM_CONN_ID:
        s.run_subscenario(
            project, results, "sc1-custom-apim-tool",
            s.tool_def(DRIVER_MODEL, MCP_APIM_URL, MCP_APIM_CONN_ID, "APIM (custom connection)"),
            s.QUESTION_TOOL,
            title="1b  TOOL   — MS Learn MCP via APIM (CustomKeys connection)",
            calls=[
                ("driver model", DRIVER_MODEL),
                ("MCP url", MCP_APIM_URL),
                ("MCP conn", s.short_conn(MCP_APIM_CONN_ID)),
            ],
        )

    # 1c — A2A: remote specialist via a RemoteA2A connection (native driver model).
    if A2A_URL and A2A_CONN_ID:
        s.run_subscenario(
            project, results, "sc1-custom-apim-a2a",
            s.a2a_def(DRIVER_MODEL, A2A_URL, A2A_CONN_ID),
            s.QUESTION_A2A,
            title="1c  A2A    — remote specialist (RemoteA2A connection, direct host root)",
            calls=[
                ("driver model", DRIVER_MODEL),
                ("A2A url", A2A_URL),
                ("A2A conn", s.short_conn(A2A_CONN_ID)),
            ],
        )

    s.print_summary("Scenario 1 — CUSTOM (APIM), subscription-KEY custom connection", results)


if __name__ == "__main__":
    main()
