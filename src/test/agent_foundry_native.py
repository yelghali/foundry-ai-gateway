"""
Scenario 6 — Native Foundry agent doing model + tool (MCP) + agent (A2A) calls,
with NO gateway in the path.

This is the "native" counterpart to agent_foundry_mcp_a2a_litellm.py. Everything
here is direct:

    * model  -> a native Foundry model deployment (e.g. gpt-4o-mini), no gateway
    * MCP    -> the public Microsoft Learn MCP server, called directly
    * A2A    -> the remote dummy specialist agent, called directly at its OWN host

The point of this script is the honest A2A comparison:

    LiteLLM-fronted A2A is BLOCKED because Foundry resolves the agent card at the
    HOST ROOT ({scheme}://{host}/.well-known/agent-card.json, per the A2A spec /
    RFC 8615) and LiteLLM only serves the card UNDER a path. A *native* A2A target
    that serves its card at its own host root (like our dummy agent) works, because
    discovery hits a real 200. So native A2A succeeds where LiteLLM-fronted A2A does
    not -- this script demonstrates the working native path.

Prerequisites:
    pip install -r requirements.txt
    az login
    # A RemoteA2A connection whose target is the A2A agent's host root, e.g.
    #   az rest --method put --url ".../connections/dummy-a2a-direct?..." --body @conn.json

Environment variables:
    FOUNDRY_PROJECT_ENDPOINT        Foundry project endpoint, e.g.
                                    https://<account>.services.ai.azure.com/api/projects/<project>
    FOUNDRY_MODEL_DEPLOYMENT_NAME   Native model deployment name, e.g. gpt-4o-mini
    FOUNDRY_A2A_CONNECTION_ID       Resource id of the RemoteA2A connection to the
                                    A2A agent's host root (required for the A2A leg).
    A2A_BASE_URL                    A2A agent host root (defaults to the connection's
                                    target if omitted), e.g.
                                    https://ca-a2a-dummy-...azurecontainerapps.io
    MCP_SERVER_URL                  Public MCP server (default: Microsoft Learn MCP).
    KEEP_AGENT                      Set to 1 to leave the agent + conversation in the
                                    project so they stay visible in the Foundry portal.
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
MODEL_DEPLOYMENT = os.environ["FOUNDRY_MODEL_DEPLOYMENT_NAME"]  # native deployment, e.g. gpt-4o-mini
A2A_CONNECTION_ID = os.environ.get("FOUNDRY_A2A_CONNECTION_ID")
A2A_BASE_URL = os.environ.get("A2A_BASE_URL", "").rstrip("/")
MCP_SERVER_URL = os.environ.get("MCP_SERVER_URL", "https://learn.microsoft.com/api/mcp")
KEEP_AGENT = os.environ.get("KEEP_AGENT", "").strip().lower() in ("1", "true", "yes")


def build_tools() -> list:
    """Build the native MCP (+ optional native A2A) tool definitions -- no gateway."""
    tools: list = []

    # 1) Microsoft Learn MCP, called directly (public, no connection / no gateway).
    tools.append(
        MCPTool(
            server_label="mslearn",
            server_url=MCP_SERVER_URL,
            server_description="Microsoft Learn documentation search (called directly).",
            require_approval="never",
        )
    )

    # 2) Remote A2A specialist, called DIRECTLY at its own host root. Foundry resolves
    #    the agent card at {scheme}://{host}/.well-known/agent-card.json; the dummy agent
    #    serves exactly that, so discovery (and message/send) succeed with no gateway.
    if A2A_CONNECTION_ID:
        a2a_kwargs = dict(
            name="dummy_specialist",
            description="A remote A2A specialist agent, called directly at its host root.",
            project_connection_id=A2A_CONNECTION_ID,
        )
        if A2A_BASE_URL:
            a2a_kwargs["base_url"] = A2A_BASE_URL
        tools.append(A2APreviewTool(**a2a_kwargs))
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

    # 1) Create a prompt agent on a native model deployment with native tools.
    agent = project.agents.create_version(
        agent_name="native-mcp-a2a-agent",
        definition=PromptAgentDefinition(
            model=MODEL_DEPLOYMENT,
            instructions=instructions,
            tools=tools,
        ),
    )
    tool_names = ", ".join(type(t).__name__ for t in tools)
    print(f"Created agent '{agent.name}' (version {agent.version}) -> model '{MODEL_DEPLOYMENT}' (native)")
    print(f"Tools (all direct, no gateway): {tool_names}")

    if have_a2a:
        question = (
            "First, search Microsoft Learn: what is Azure API Management in one line? "
            "Then consult the specialist about whether to put a gateway in front of agents. "
            "Give both answers."
        )
    else:
        question = "Search Microsoft Learn: what is Azure API Management? Answer in one sentence."

    # 2) Run it. Model + tool calls all go direct -- no gateway in the path.
    openai_client = project.get_openai_client()
    conversation = openai_client.conversations.create()
    try:
        response = openai_client.responses.create(
            conversation=conversation.id,
            input=question,
            extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
        )
        print("\nAgent reply (native model + native tools, no gateway):")
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
