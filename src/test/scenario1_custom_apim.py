"""
Scenario 1 — Foundry agent + Toolbox behind BYO Azure APIM, managed-identity first.

Runs against its OWN client Foundry account (client-foundry-sc1). One versioned Foundry
Toolbox holds both remote capabilities, and every tool call crosses the customer-owned APIM
gateway. No credential appears in this file:
    1a  MODEL   apim-custom-key/<model>   -> ApiManagement connection.
                                             ⚠️ APIM subscription KEY — the only secret in
                                             the scenario (last resort; Scenario 2 shows the
                                             same model leg with managed identity).
    1b  TOOLBOX MS Learn MCP behind APIM  -> project MI (Entra token validated by APIM)
                remote A2A behind APIM    -> project MI (Entra token validated by APIM)
                Toolbox MCP endpoint      -> project MI (audience https://ai.azure.com)

APIM pins the `oid` claim of the incoming Entra token to this project's managed identity and
strips the Authorization header before forwarding, so neither downstream service ever sees a
gateway credential.

Run:
    python scenario1_custom_apim.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_lib as s  # noqa: E402
import scenario_config as cfg  # noqa: E402
from azure.ai.projects.models import A2APreviewTool, MCPTool, PromptAgentDefinition  # noqa: E402

ENDPOINT = cfg.require("sc1ProjectEndpoint", "SC1_PROJECT_ENDPOINT")
DRIVER_MODEL = cfg.get("sc1DriverModel", "SC1_DRIVER_MODEL", "gpt-4o-mini")
KEY_MODEL = cfg.get("sc1CustomKeyModel", "SC1_CUSTOM_KEY_MODEL", "apim-custom-key/gpt-4o-mini")
# Entra-protected MCP front door on APIM (subscriptionRequired=false).
MCP_APIM_URL = cfg.require("sc1McpApimMiUrl", "SC1_MCP_APIM_MI_URL")
MCP_APIM_CONN_ID = cfg.require("sc1McpApimConnId", "SC1_MCP_APIM_CONN_ID")
ENTRA_AUDIENCE = cfg.get("sc1EntraAudience", "SC1_ENTRA_AUDIENCE", "https://cognitiveservices.azure.com")
A2A_URL = cfg.require("sc1A2aApimUrl", "SC1_A2A_APIM_URL")
A2A_CONN_ID = cfg.require("sc1A2aApimConnId", "SC1_A2A_APIM_CONN_ID")
TOOLBOX_NAME = cfg.get("sc1ToolboxName", "SC1_TOOLBOX_NAME", "scenario1-apim-toolbox")
TOOLBOX_URL = cfg.require("sc1ToolboxMcpUrl", "SC1_TOOLBOX_MCP_URL")
TOOLBOX_CONN_ID = cfg.require("sc1ToolboxConnId", "SC1_TOOLBOX_CONN_ID")


def main() -> None:
    project = s.connect(ENDPOINT)
    results: list = []

    s.print_header(
        "Scenario 1 — Foundry agent + Toolbox + BYO APIM (managed identity)",
        [
            "A versioned Toolbox combines MCP and A2A. Both downstream legs authenticate to",
            "APIM with the project managed identity (Entra token, oid pinned by policy), and",
            "the agent reaches the Toolbox with project MI too. Only the model leg uses a key.",
        ],
    )

    # 1a — MODEL: ⚠️ the one key in this scenario (APIM subscription key on an
    # ApiManagement connection). Scenario 2 runs the same leg with managed identity.
    s.run_subscenario(
        project, results, "sc1-custom-apim-model-key",
        s.model_def(KEY_MODEL),
        s.QUESTION_MODEL,
        title="1a  MODEL  — ApiManagement connection (⚠️ APIM subscription key, last resort)",
        calls=[("model conn", KEY_MODEL)],
    )

    # 1b — TOOLBOX: one reusable, versioned tool surface. The toolbox and agent definitions
    # carry only connection IDs; the connections themselves hold no secret (project MI).
    toolbox = project.toolboxes.create_toolbox_version(
        name=TOOLBOX_NAME,
        description="Entra-authenticated MCP and A2A tools governed by customer-owned APIM.",
        tools=[
            MCPTool(
                server_label="mslearn",
                server_url=MCP_APIM_URL,
                server_description="Microsoft Learn MCP through Azure API Management (Entra auth).",
                project_connection_id=MCP_APIM_CONN_ID,
                require_approval="never",
            ),
            A2APreviewTool(project_connection_id=A2A_CONN_ID),
        ],
    )
    print(f"  Toolbox {toolbox.name} version {toolbox.version} created; agent uses its stable consumer URL.")

    toolbox_definition = PromptAgentDefinition(
        model=DRIVER_MODEL,
        instructions=(
            "Use the toolbox for both parts. First use Microsoft Learn to explain Azure API "
            "Management in one sentence, then ask the specialist whether agents should be "
            "placed behind a gateway. Report both answers concisely."
        ),
        tools=[MCPTool(
            server_label="apim_toolbox",
            server_url=TOOLBOX_URL,
            server_description="Foundry Toolbox containing APIM-governed MCP and A2A tools.",
            project_connection_id=TOOLBOX_CONN_ID,
            require_approval="never",
        )],
    )
    s.run_subscenario(
        project, results, "sc1-apim-toolbox-mcp-a2a",
        toolbox_definition,
        "Use both toolbox capabilities now.",
        title="1b  TOOLBOX — MCP + A2A through BYO APIM (project managed identity)",
        calls=[
            ("toolbox", TOOLBOX_URL),
            ("toolbox auth", "ProjectManagedIdentity → https://ai.azure.com"),
            ("MCP via APIM", MCP_APIM_URL),
            ("A2A via APIM", A2A_URL),
            ("downstream auth", f"ProjectManagedIdentity → {ENTRA_AUDIENCE} (no key)"),
        ],
    )

    s.print_summary("Scenario 1 — Foundry agent + Toolbox + BYO APIM (managed identity)", results)


if __name__ == "__main__":
    main()
