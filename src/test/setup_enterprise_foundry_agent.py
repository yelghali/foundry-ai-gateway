"""Create an enterprise Foundry prompt agent and enable its incoming A2A endpoint.

This is the publisher-side setup for Scenario 4. It uses Microsoft Entra authentication only.
The agent is hosted by Foundry; APIM later fronts its native A2A endpoint.
"""

import argparse
import os
import sys

import requests
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity import DefaultAzureCredential

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-endpoint", required=True)
    parser.add_argument("--agent-name", default="enterprise-specialist")
    parser.add_argument("--model", default="gpt-4o-mini")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    endpoint = args.project_endpoint.rstrip("/")
    credential = DefaultAzureCredential(process_timeout=cfg.credential_process_timeout())
    project = AIProjectClient(endpoint=endpoint, credential=credential)

    # Agent names are stable and versions are immutable. Re-running publishes a new version
    # under the same name; consumers continue to use the stable agent endpoint.
    agent = project.agents.create_version(
        agent_name=args.agent_name,
        description="Enterprise specialist published behind Azure API Management.",
        definition=PromptAgentDefinition(
            model=args.model,
            instructions=(
                "You are the enterprise AI gateway specialist. Explain enterprise AI gateway, "
                "APIM, model, MCP, toolbox, and agent governance decisions concisely."
            ),
        ),
    )

    # Incoming A2A and the agent card currently require the data-plane PATCH surface.
    # The Python SDK can enable the protocol in newer releases, but REST is also the
    # documented path and lets this sample configure the card in the same operation.
    token = credential.get_token("https://ai.azure.com/.default").token
    response = requests.patch(
        f"{endpoint}/agents/{args.agent_name}",
        params={"api-version": "v1"},
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json={
            "agent_card": {
                "description": "Enterprise AI gateway and APIM specialist.",
                "version": "1.0",
                "skills": [
                    {
                        "id": "enterprise-ai-gateway",
                        "name": "Enterprise AI gateway guidance",
                        "description": "Advises on APIM governance for models, tools, and agents.",
                    }
                ],
            },
            "agent_endpoint": {
                "protocol_configuration": {
                    "responses": {},
                    "a2a": {},
                }
            },
        },
        timeout=120,
    )
    response.raise_for_status()

    a2a_url = f"{endpoint}/agents/{args.agent_name}/endpoint/protocols/a2a"
    print(f"Agent name       : {agent.name}")
    print(f"Agent version    : {agent.version}")
    print(f"Responses target : {endpoint} + agent_reference.name={agent.name}")
    print(f"A2A base URL     : {a2a_url}")
    print(f"A2A v1 card      : {a2a_url}/agentCard/v1.0")


if __name__ == "__main__":
    main()
