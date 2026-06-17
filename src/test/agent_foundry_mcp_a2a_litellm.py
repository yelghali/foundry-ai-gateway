"""
Scenario 5+ — Foundry Agent Service agent that calls a remote MCP tool AND a
remote A2A agent, both governed by the LiteLLM BYO gateway.

This is the most complete "bring your own gateway" demo: a single Foundry
*prompt agent* whose

    * model   ->  litellm-gateway/gpt-4o-mini   (Foundry Model Gateway connection)
    * MCP tool ->  {LiteLLM}/mcp/  (x-mcp-servers: mslearn -> remote MS Learn MCP)
    * A2A tool ->  remote A2A specialist agent (see A2A finding below)

The model + MCP legs flow through the *same* LiteLLM gateway on Azure Container
Apps. One control point governs model + tool traffic.

A2A finding (Foundry managed A2A tool vs. LiteLLM)
-------------------------------------------------
The MCP leg is validated end to end through LiteLLM. The A2A leg is *not*
governable through LiteLLM with Foundry's **managed** A2APreviewTool, for a
structural reason discovered empirically:

  * Foundry resolves the agent card at the **host root of the project
    connection's target** (``{scheme}://{host}/.well-known/agent-card.json``) and
    sends ``message/send`` **directly to that same server** — it ignores the
    tool ``base_url`` path, the ``agent_card_path``, and the card's advertised
    ``url``. So LiteLLM's A2A gateway (path-scoped at ``/a2a/{agent}/...`` with
    no host-root card or host-root message route) cannot sit in front of the
    agent for the managed tool. Pointing the connection straight at the agent
    makes Foundry discover + call it, but that bypasses LiteLLM.
  * Two prerequisites that *were* fixed along the way: LiteLLM now advertises
    **https** card URLs (``FORWARDED_ALLOW_IPS=*`` on the container), and the
    demo A2A agent now reads **chunked** request bodies (Foundry's .NET A2A
    client sends them) and replies with an A2A **Message**.
  * Even pointing Foundry directly at the agent, the managed A2A tool currently
    returns an opaque Foundry-side ``500 server_error`` after the agent answers
    — a preview-stage limitation.

A2A *through LiteLLM* is validated for **client-orchestrated** agents instead
(see agent_a2a_litellm.py), where the client controls the endpoint URL.

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
* A2APreviewTool -> base_url + project_connection_id (litellm-a2a). NOTE: Foundry
  discovers + routes A2A via the *connection target* host root, not this base_url.

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
    FOUNDRY_A2A_BASE_URL            (optional) host whose /.well-known/agent-card.json
                                    Foundry discovers for the A2A tool; defaults to
                                    LITELLM_BASE_URL. See the A2A finding above.
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
# Host whose /.well-known/agent-card.json Foundry discovers for the A2A tool. Foundry
# resolves the agent card at the HOST ROOT (per the A2A spec / RFC 8615), ignoring any
# sub-path or agent_card_path. LiteLLM only serves the card UNDER a path
# (/a2a/{agent}/.well-known/agent-card.json), so we discover the card at the A2A agent's
# OWN host root and let that card advertise the LiteLLM endpoint as its url — so discovery
# is direct but every A2A *message* still flows through the LiteLLM gateway.
A2A_DISCOVERY_BASE_URL = os.environ.get("FOUNDRY_A2A_BASE_URL", LITELLM_BASE_URL)


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
    #    Foundry resolves the agent card at the HOST ROOT of base_url
    #    ({scheme}://{host}/.well-known/agent-card.json), ignoring any sub-path and the
    #    agent_card_path argument. LiteLLM only serves the card UNDER a path
    #    (/a2a/{agent}/.well-known/...), so we point base_url at the A2A agent's OWN host
    #    (which serves a host-root card). That card advertises the LiteLLM endpoint as its
    #    url, so discovery is direct to the agent but every A2A *message* the agent runtime
    #    sends flows through the LiteLLM gateway. FORWARDED_ALLOW_IPS=* on the LiteLLM
    #    container makes uvicorn honour X-Forwarded-Proto so the advertised url is https.
    if A2A_CONNECTION_ID:
        tools.append(
            A2APreviewTool(
                name="dummy_specialist",
                description="A remote A2A specialist agent reached through the LiteLLM gateway.",
                base_url=A2A_DISCOVERY_BASE_URL,
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
