"""Create a Foundry Toolbox whose underlying MCP tool is governed by APIM."""

import os
import sys

from azure.ai.projects.models import MCPTool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402
import scenario_lib as s  # noqa: E402

ENDPOINT = cfg.require("toolboxProjectEndpoint", "TOOLBOX_PROJECT_ENDPOINT")
TOOLBOX_NAME = cfg.get(
    "toolboxName",
    "TOOLBOX_NAME",
    "scenario1-apim-toolbox",
)
MCP_APIM_URL = cfg.require("rawMcpApimUrl", "MCP_APIM_URL")
MCP_CONNECTION_ID = cfg.require(
    "toolboxPublisherMcpConnectionId",
    "MCP_APIM_CONNECTION_ID",
)


def main() -> None:
    project = s.connect(ENDPOINT)
    toolbox = project.toolboxes.create_version(
        name=TOOLBOX_NAME,
        description="Reusable Microsoft Learn capability with egress governed by APIM.",
        tools=[
            MCPTool(
                server_label="mslearn",
                server_url=MCP_APIM_URL,
                server_description="Microsoft Learn MCP through customer-owned APIM.",
                project_connection_id=MCP_CONNECTION_ID,
                require_approval="never",
            )
        ],
    )
    project.toolboxes.update(name=TOOLBOX_NAME, default_version=toolbox.version)
    print("Foundry Toolbox setup")
    print(f"  Project : {ENDPOINT}")
    print(f"  Toolbox : {toolbox.name} version {toolbox.version}")
    print(f"  Egress  : {MCP_APIM_URL}")
    print("  PASS    : Toolbox version created")


if __name__ == "__main__":
    main()