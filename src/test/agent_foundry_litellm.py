"""
Scenario 5 — Bring Your Own Gateway INTO Foundry.

Runs a Foundry Agent Service *prompt agent* whose model is served by our LiteLLM
gateway through a Foundry "Model Gateway" connection. Foundry Agent Service routes
the agent's model calls to LiteLLM (Container Apps), which load balances across the
two Foundry regions with Entra ID auth.

The only thing that makes this a "BYO gateway" agent is the model deployment name
format:  <connection-name>/<model-name>   (e.g. litellm-gateway/gpt-4o-mini)

Prerequisites:
    pip install -r requirements.txt          # includes azure-ai-projects, azure-identity
    az login                                 # DefaultAzureCredential needs an identity
    # Deploy the gateway + connection first:  infra/deploy-litellm-foundry.ps1

Environment variables:
    FOUNDRY_PROJECT_ENDPOINT        Foundry project endpoint, e.g.
                                    https://<account>.services.ai.azure.com/api/projects/<project>
    FOUNDRY_MODEL_DEPLOYMENT_NAME   <connection-name>/<model-name>, e.g. litellm-gateway/gpt-4o-mini
"""

import os

from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition

PROJECT_ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
MODEL_DEPLOYMENT = os.environ["FOUNDRY_MODEL_DEPLOYMENT_NAME"]  # "<connection>/<model>"


def main() -> None:
    project = AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())

    # 1) Create a prompt agent that uses the model behind our gateway connection.
    agent = project.agents.create_version(
        agent_name="litellm-gateway-agent",
        definition=PromptAgentDefinition(
            model=MODEL_DEPLOYMENT,
            instructions="You are a concise assistant. Answer in one sentence.",
        ),
    )
    print(f"Created agent '{agent.name}' (version {agent.version}) -> model '{MODEL_DEPLOYMENT}'")

    # 2) Run it. Requests flow: Agent Service -> Model Gateway connection -> LiteLLM -> Foundry.
    openai_client = project.get_openai_client()
    conversation = openai_client.conversations.create()
    try:
        response = openai_client.responses.create(
            conversation=conversation.id,
            input="In one sentence, what does an AI gateway do?",
            extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
        )
        print("\nAgent reply (served through the LiteLLM gateway):")
        print(response.output_text)
    finally:
        # 3) Clean up the conversation and agent version.
        openai_client.conversations.delete(conversation.id)
        project.agents.delete_version(agent_name=agent.name, agent_version=agent.version)
        print("\nCleaned up conversation + agent version.")


if __name__ == "__main__":
    main()
