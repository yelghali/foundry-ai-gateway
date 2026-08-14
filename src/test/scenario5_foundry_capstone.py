"""Foundry capstone: one hosted agent uses APIM-published Toolbox and A2A assets."""

import os
import sys

from azure.ai.projects.models import A2APreviewTool, MCPTool, PromptAgentDefinition

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402
import scenario_lib as s  # noqa: E402

ENDPOINT = cfg.require("appProjectEndpoint", "APP_PROJECT_ENDPOINT")
DRIVER_MODEL = cfg.get("appDriverModel", "APP_DRIVER_MODEL", "gpt-4o-mini")
TOOLBOX_APIM_URL = cfg.require("toolboxApimUrl", "TOOLBOX_APIM_URL")
TOOLBOX_CONNECTION_ID = cfg.require(
    "appToolboxConnectionId",
    "TOOLBOX_APIM_CONNECTION_ID",
)
A2A_APIM_URL = cfg.require(
    "enterpriseAgentApimDiscoveryUrl",
    "ENTERPRISE_AGENT_APIM_DISCOVERY_URL",
)
A2A_CONNECTION_ID = cfg.require(
    "enterpriseAgentConsumerConnectionId",
    "ENTERPRISE_AGENT_CONSUMER_CONNECTION_ID",
)


def main() -> None:
    project = s.connect(ENDPOINT)
    openai_client = project.get_openai_client()
    agent = None
    conversation = None
    try:
        a2a_tool = A2APreviewTool({
            "type": "a2a_preview",
            "name": "enterprise_specialist",
            "description": "Enterprise Foundry specialist published through APIM.",
            "base_url": A2A_APIM_URL,
            "project_connection_id": A2A_CONNECTION_ID,
            "send_credentials_for_agent_card": True,
        })
        definition = PromptAgentDefinition(
            model=DRIVER_MODEL,
            instructions=(
                "Use the research_toolbox for factual Microsoft Learn research and the "
                "enterprise_specialist for governance advice. Be concise."
            ),
            tools=[
                MCPTool(
                    server_label="research_toolbox",
                    server_url=TOOLBOX_APIM_URL,
                    server_description="Foundry research Toolbox published through APIM.",
                    project_connection_id=TOOLBOX_CONNECTION_ID,
                    require_approval="never",
                ),
                a2a_tool,
            ],
        )
        agent = project.agents.create_version(
            agent_name="sc5-foundry-enterprise-capstone",
            definition=definition,
        )
        conversation = openai_client.conversations.create()
        research = openai_client.responses.create(
            conversation=conversation.id,
            input=(
                "Use the research Toolbox to explain Azure API Management in one sentence. "
                "Do not answer from memory."
            ),
            extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
        )
        advice = openai_client.responses.create(
            conversation=conversation.id,
            input=(
                "Now ask the enterprise specialist why enterprise agents should be published "
                "through APIM. Summarize that advice with the research finding."
            ),
            extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
        )
        research_text = (research.output_text or "").strip().replace("\n", " ")
        advice_text = (advice.output_text or "").strip().replace("\n", " ")
        if not research_text or not advice_text:
            raise RuntimeError("One of the capstone tool turns returned an empty response.")
        print("Scenario 5b - Foundry-hosted enterprise capstone")
        print(f"  Project : {ENDPOINT}")
        print(f"  Toolbox : {TOOLBOX_APIM_URL}")
        print(f"  A2A     : {A2A_APIM_URL}")
        print(f"  Research: {research_text}")
        print(f"  PASS    : {advice_text}")
    finally:
        if not s.KEEP_AGENT:
            if conversation:
                openai_client.conversations.delete(conversation.id)
            if agent:
                project.agents.delete_version(
                    agent_name=agent.name,
                    agent_version=agent.version,
                )


if __name__ == "__main__":
    main()