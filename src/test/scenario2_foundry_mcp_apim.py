"""Foundry-hosted agent consumes an MCP server through APIM without keys."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402
import scenario_lib as s  # noqa: E402

ENDPOINT = cfg.require("appProjectEndpoint", "APP_PROJECT_ENDPOINT")
MODEL = cfg.get("appModel", "APP_MODEL", "apim-gateway-mi/gpt-4o-mini")
GATEWAY_URL = cfg.require("apimGatewayUrl", "APIM_GATEWAY_URL").rstrip("/")
MCP_APIM_URL = cfg.get(
    "rawMcpApimUrl",
    "MCP_APIM_URL",
    f"{GATEWAY_URL}/learn-mcp-mi/mcp",
)
MCP_CONNECTION_ID = cfg.require("appMcpConnectionId", "MCP_APIM_CONNECTION_ID")


def main() -> None:
    project = s.connect(ENDPOINT)
    results: list = []
    s.print_header(
        "Scenario 2b - Foundry agent -> APIM -> MCP server",
        [
            "The project managed identity authenticates to APIM.",
            "APIM governs the streamable HTTP session and forwards to Microsoft Learn MCP.",
        ],
    )
    ok = s.run_subscenario(
        project,
        results,
        "sc2-foundry-apim-mcp-mi",
        s.tool_def(MODEL, MCP_APIM_URL, MCP_CONNECTION_ID, "customer-owned APIM"),
        s.QUESTION_TOOL,
        title="2b  MCP - RemoteTool connection (project managed identity)",
        calls=[
            ("consumer", ENDPOINT),
            ("model", MODEL),
            ("MCP via APIM", MCP_APIM_URL),
            ("connection", s.short_conn(MCP_CONNECTION_ID)),
            ("auth", "ProjectManagedIdentity -> APIM"),
        ],
    )
    s.print_summary("Scenario 2b - Foundry MCP consumer", results)
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()