"""
Scenario 5+ — Foundry Agent Service agent that calls a remote MCP tool AND a
remote A2A agent, both governed by the LiteLLM BYO gateway.

This is the most complete "bring your own gateway" demo: a single Foundry
*prompt agent* whose

    * model   ->  litellm-gateway/gpt-4o-mini   (Foundry Model Gateway connection)
    * MCP tool ->  {LiteLLM}/mcp/  (x-mcp-servers: mslearn -> remote MS Learn MCP)
    * A2A tool ->  {LiteLLM}/a2a/dummy-specialist  (remote A2A specialist agent)

all flow through the *same* LiteLLM gateway on Azure Container Apps. One control
point governs model + tool + agent traffic.

How Foundry executes the tools
------------------------------
Foundry Agent Service runs the MCP / A2A tool calls *server-side*: the model
emits a tool call, Foundry connects to the remote endpoint (LiteLLM), runs it,
and feeds the result back to the model. With ``require_approval="never"`` no
human approval step is needed.

Foundry Agent Service does **not** allow sensitive headers (such as
``Authorization``) inline on a tool definition — it returns ``invalid_payload``
and tells you to use a project connection instead. So both tools authenticate to
LiteLLM through a Foundry **Custom keys** project connection that stores
``Authorization: Bearer <LiteLLM master key>``:

* MCPTool  -> server_url = {LiteLLM}/mcp/   + project_connection_id (litellm-mcp)
* A2APreviewTool -> base_url = {LiteLLM}/a2a/dummy-specialist + project_connection_id (litellm-a2a)

Create each connection once (portal: Management center > Connected resources >
Custom keys, key ``Authorization`` = ``Bearer <key>``; or via the management REST
API). Pass the connection resource ids in FOUNDRY_MCP_CONNECTION_ID /
FOUNDRY_A2A_CONNECTION_ID. If FOUNDRY_A2A_CONNECTION_ID is unset the A2A tool is
skipped and only the MCP hop is exercised.

Prerequisites:
    pip install -r requirements.txt          # azure-ai-projects>=2.2, azure-identity
    az login                                 # DefaultAzureCredential needs an identity
    # Deploy the gateway + connection first:  infra/deploy-litellm-foundry.ps1
    # Register the A2A agent in LiteLLM:       python register_a2a_agent.py

Environment variables:
    FOUNDRY_PROJECT_ENDPOINT        Foundry project endpoint, e.g.
                                    https://<account>.services.ai.azure.com/api/projects/<project>
    FOUNDRY_MODEL_DEPLOYMENT_NAME   <connection>/<model>, e.g. litellm-gateway/gpt-4o-mini
    LITELLM_BASE_URL                LiteLLM gateway base URL (ACA)
    FOUNDRY_MCP_CONNECTION_ID       project connection id (Custom keys) holding the
                                    LiteLLM Authorization header for the MCP endpoint
    FOUNDRY_A2A_CONNECTION_ID       (optional) project connection id holding the
                                    LiteLLM Authorization header for A2A; enables the A2A hop
"""

import os

from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    PromptAgentDefinition,
    MCPTool,
    A2APreviewTool,
)

PROJECT_ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
MODEL_DEPLOYMENT = os.environ["FOUNDRY_MODEL_DEPLOYMENT_NAME"]  # "<connection>/<model>"
LITELLM_BASE_URL = os.environ["LITELLM_BASE_URL"].rstrip("/")
MCP_CONNECTION_ID = os.environ["FOUNDRY_MCP_CONNECTION_ID"]
A2A_CONNECTION_ID = os.environ.get("FOUNDRY_A2A_CONNECTION_ID")


def build_tools() -> list:
    """Build the MCP (+ optional A2A) tool definitions, both pointed at LiteLLM."""
    tools: list = []

    # 1) MS Learn MCP, governed by LiteLLM. Trailing slash on /mcp/ matters: LiteLLM
    #    307-redirects /mcp -> /mcp/ and a streamable-HTTP client refuses the redirect.
    #    Auth comes from the Custom-keys project connection (Authorization header),
    #    not inline headers (Foundry rejects sensitive headers on the tool itself).
    tools.append(
        MCPTool(
            server_label="mslearn",
            server_url=f"{LITELLM_BASE_URL}/mcp/",
            server_description="Microsoft Learn documentation search, governed by the LiteLLM gateway.",
            project_connection_id=MCP_CONNECTION_ID,
            require_approval="never",
        )
    )

    # 2) Remote A2A specialist, governed by LiteLLM. Auth also comes from a
    #    Custom-keys project connection holding the LiteLLM bearer token.
    #    Foundry resolves agent_card_path against the host root, so base_url is the
    #    gateway host and the full LiteLLM A2A card path is given explicitly.
    if A2A_CONNECTION_ID:
        tools.append(
            A2APreviewTool(
                name="dummy_specialist",
                description="A remote A2A specialist agent reached through the LiteLLM gateway.",
                base_url=LITELLM_BASE_URL,
                agent_card_path="/a2a/dummy-specialist/.well-known/agent-card.json",
                project_connection_id=A2A_CONNECTION_ID,
            )
        )
    return tools


def main() -> None:
    project = AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())

    tools = build_tools()
    have_a2a = any(isinstance(t, A2APreviewTool) for t in tools)

    instructions = (
        "You are a research assistant. "
        "Use the mslearn MCP tool to answer Microsoft/Azure documentation questions. "
        + ("Use the dummy_specialist A2A agent when the user asks to consult a specialist. "
           if have_a2a else "")
        + "Be concise."
    )

    # 1) Create a prompt agent whose model is served by the LiteLLM gateway and
    #    whose tools (MCP + optional A2A) are also reached through LiteLLM.
    agent = project.agents.create_version(
        agent_name="litellm-mcp-a2a-agent",
        definition=PromptAgentDefinition(
            model=MODEL_DEPLOYMENT,
            instructions=instructions,
            tools=tools,
        ),
    )
    tool_names = ", ".join(type(t).__name__ for t in tools)
    print(f"Created agent '{agent.name}' (version {agent.version}) -> model '{MODEL_DEPLOYMENT}'")
    print(f"Tools (all via LiteLLM): {tool_names}")

    if have_a2a:
        question = (
            "First, search Microsoft Learn: what is Azure API Management in one line? "
            "Then consult the specialist to convert 100 USD to EUR. "
            "Give both answers."
        )
    else:
        question = "Search Microsoft Learn: what is Azure API Management? Answer in one sentence."

    # 2) Run it. Model + tool calls all flow through LiteLLM.
    openai_client = project.get_openai_client()
    conversation = openai_client.conversations.create()
    try:
        response = openai_client.responses.create(
            conversation=conversation.id,
            input=question,
            extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
        )
        print("\nAgent reply (model + tools served through the LiteLLM gateway):")
        print(response.output_text)
    finally:
        # 3) Clean up the conversation and agent version.
        openai_client.conversations.delete(conversation.id)
        project.agents.delete_version(agent_name=agent.name, agent_version=agent.version)
        print("\nCleaned up conversation + agent version.")


if __name__ == "__main__":
    main()
