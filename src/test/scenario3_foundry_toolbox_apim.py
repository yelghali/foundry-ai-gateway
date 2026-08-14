"""Foundry-hosted agent consumes a Foundry Toolbox through APIM without keys."""

import os
import sys

from azure.ai.projects.models import MCPTool, PromptAgentDefinition

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402
import scenario_lib as s  # noqa: E402

ENDPOINT = cfg.require("appProjectEndpoint", "APP_PROJECT_ENDPOINT")
MODEL = cfg.get("appDriverModel", "APP_TOOLBOX_DRIVER_MODEL", "gpt-4o-mini")
TOOLBOX_APIM_URL = cfg.require("toolboxApimUrl", "TOOLBOX_APIM_URL")
TOOLBOX_CONNECTION_ID = cfg.require(
    "appToolboxConnectionId",
    "TOOLBOX_APIM_CONNECTION_ID",
)


def main() -> None:
    project = s.connect(ENDPOINT)
    results: list = []
    s.print_header(
        "Scenario 3b - Foundry agent -> APIM -> Foundry Toolbox",
        [
            "The Toolbox ingress and its MCP egress both cross APIM.",
            "A native driver is used because Agent Service currently returns 500 when this",
            "Toolbox is paired with an ApiManagement connected model; raw MCP does not.",
        ],
    )
    definition = PromptAgentDefinition(
        model=MODEL,
        instructions="Use the research Toolbox to answer in one sentence.",
        tools=[
            MCPTool(
                server_label="research_toolbox",
                server_url=TOOLBOX_APIM_URL,
                server_description="Foundry Toolbox published through customer-owned APIM.",
                project_connection_id=TOOLBOX_CONNECTION_ID,
                require_approval="never",
            )
        ],
    )
    ok = s.run_subscenario(
        project,
        results,
        "sc3-foundry-apim-toolbox-mi",
        definition,
        "Use Microsoft Learn to explain Azure API Management in one sentence.",
        title="3b  TOOLBOX - Foundry agent through APIM (project managed identity)",
        calls=[
            ("consumer", ENDPOINT),
            ("model", MODEL),
            ("Toolbox", TOOLBOX_APIM_URL),
            ("connection", s.short_conn(TOOLBOX_CONNECTION_ID)),
            ("ingress auth", "ProjectManagedIdentity -> APIM -> APIM MI -> Toolbox"),
            ("egress auth", "Toolbox project identity -> APIM -> MCP"),
        ],
    )
    s.print_summary("Scenario 3b - Foundry Toolbox consumer", results)
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()