"""Scenario 6b: a Foundry-hosted agent consumes LiteLLM model, MCP, and A2A surfaces."""

import os
import sys

from azure.ai.projects.models import A2APreviewTool, PromptAgentDefinition

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402
import scenario_lib as s  # noqa: E402

ENDPOINT = cfg.require("appProjectEndpoint", "APP_PROJECT_ENDPOINT")
DRIVER_MODEL = cfg.get("appDriverModel", "APP_DRIVER_MODEL", "gpt-4o-mini")
MODEL_REF = cfg.require("litellmModel", "LITELLM_MODEL_REF")
MCP_URL = cfg.require("litellmMcpUrl", "LITELLM_MCP_URL")
MCP_CONNECTION_ID = cfg.require(
    "litellmMcpConnectionId",
    "LITELLM_MCP_CONNECTION_ID",
)
A2A_URL = cfg.require("litellmA2aShimUrl", "LITELLM_A2A_URL")
A2A_CONNECTION_ID = cfg.require(
    "litellmA2aConnectionId",
    "LITELLM_A2A_CONNECTION_ID",
)


def main() -> None:
    project = s.connect(ENDPOINT)
    results: list = []

    s.print_header(
        "Scenario 6b - Foundry agent -> LiteLLM BYO gateway",
        [
            "ModelGateway carries the model call; project CustomKeys connections carry",
            "MCP and A2A bearer credentials. LiteLLM uses managed identity downstream.",
        ],
    )

    model_ok = s.run_subscenario(
        project,
        results,
        "sc6-foundry-litellm-model",
        s.model_def(MODEL_REF),
        s.QUESTION_MODEL,
        title="6b.1 MODEL - LiteLLM ModelGateway connection",
        calls=[("model conn", MODEL_REF), ("auth", "Foundry connection -> bearer")],
    )

    mcp_ok = s.run_subscenario(
        project,
        results,
        "sc6-foundry-litellm-mcp",
        s.tool_def(MODEL_REF, MCP_URL, MCP_CONNECTION_ID, "LiteLLM"),
        s.QUESTION_TOOL,
        title="6b.2 MCP - Microsoft Learn through LiteLLM",
        calls=[
            ("model conn", MODEL_REF),
            ("MCP url", MCP_URL),
            ("MCP conn", s.short_conn(MCP_CONNECTION_ID)),
        ],
    )

    a2a_tool = A2APreviewTool({
        "type": "a2a_preview",
        "name": "dummy_specialist",
        "description": "A remote specialist exposed through the LiteLLM A2A gateway.",
        "base_url": A2A_URL,
        "project_connection_id": A2A_CONNECTION_ID,
        "send_credentials_for_agent_card": True,
    })
    a2a_definition = PromptAgentDefinition(
        model=DRIVER_MODEL,
        instructions="Delegate the question to dummy_specialist and summarize its answer.",
        tools=[a2a_tool],
    )
    a2a_ok = s.run_subscenario(
        project,
        results,
        "sc6-foundry-litellm-a2a",
        a2a_definition,
        s.QUESTION_A2A,
        title="6b.3 A2A - remote specialist through LiteLLM",
        calls=[
            ("driver model", DRIVER_MODEL),
            ("A2A url", A2A_URL),
            ("A2A conn", s.short_conn(A2A_CONNECTION_ID)),
        ],
    )

    s.print_summary("Scenario 6b - Foundry consumer through LiteLLM", results)
    if not all((model_ok, mcp_ok, a2a_ok)):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
