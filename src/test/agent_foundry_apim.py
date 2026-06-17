"""
Scenario 5 (APIM variant) — Bring Your Own Gateway INTO Foundry.

Runs a Foundry Agent Service *prompt agent* whose model is served by your existing
APIM gateway through a Foundry "API Management" connection (category: ApiManagement).
Foundry Agent Service routes the agent's model calls to APIM, which load balances
across the two Foundry regions via its backend pool (Parts 1-3).

The only thing that makes this a "BYO gateway" agent is the model deployment name
format:  <connection-name>/<model-name>   (e.g. apim-gateway/gpt-4o-mini)

Prerequisites:
    pip install -r requirements.txt          # includes azure-ai-projects, azure-identity
    az login                                 # DefaultAzureCredential needs an identity
    # Create the APIM connection first:  infra/deploy-apim-foundry.ps1

Environment variables:
    FOUNDRY_PROJECT_ENDPOINT        Foundry project endpoint, e.g.
                                    https://<account>.services.ai.azure.com/api/projects/<project>
    FOUNDRY_MODEL_DEPLOYMENT_NAME   <connection-name>/<model-name>, e.g. apim-gateway/gpt-4o-mini
"""

import os

from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition

PROJECT_ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
MODEL_DEPLOYMENT = os.environ["FOUNDRY_MODEL_DEPLOYMENT_NAME"]  # "<connection>/<model>"
# Set KEEP_AGENT=1 to leave the created agent (and its conversation) in the project
# after the run, so it stays visible in the Foundry portal (Agents list + its thread).
# Default (unset) deletes both, as before.
KEEP_AGENT = os.environ.get("KEEP_AGENT", "").strip().lower() in ("1", "true", "yes")


def main() -> None:
    project = AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())

    # 1) Create a prompt agent that uses the model behind our APIM gateway connection.
    agent = project.agents.create_version(
        agent_name="apim-gateway-agent",
        definition=PromptAgentDefinition(
            model=MODEL_DEPLOYMENT,
            instructions="You are a concise assistant. Answer in one sentence.",
        ),
    )
    print(f"Created agent '{agent.name}' (version {agent.version}) -> model '{MODEL_DEPLOYMENT}'")

    # 2) Run it. Requests flow: Agent Service -> ApiManagement connection -> APIM -> Foundry.
    openai_client = project.get_openai_client()
    conversation = openai_client.conversations.create()
    try:
        response = openai_client.responses.create(
            conversation=conversation.id,
            input="In one sentence, what does an AI gateway do?",
            extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
        )
        print("\nAgent reply (served through the APIM gateway):")
        print(response.output_text)
    finally:
        # 3) Clean up the conversation and agent version, unless KEEP_AGENT is set so
        #    you can inspect the agent + its run in the Foundry portal.
        if KEEP_AGENT:
            print(f"\nKEEP_AGENT set — left agent '{agent.name}' (v{agent.version}) and "
                  f"conversation '{conversation.id}' in the project for portal viewing.")
        else:
            openai_client.conversations.delete(conversation.id)
            project.agents.delete_version(agent_name=agent.name, agent_version=agent.version)
            print("\nCleaned up conversation + agent version.")


if __name__ == "__main__":
    main()
