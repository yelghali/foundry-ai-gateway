"""
Shared helpers for the three CLIENT-side consumption scenarios.

The client Foundry (foundry-client) hosts NO enterprise models of its own. It reaches
the enterprise resources three different ways — one "scenario" per connection style:

    Scenario 1  CUSTOM (APIM)        CustomKeys connections holding raw APIM gateway URLs
    Scenario 2  AI GATEWAY NATIVE    Foundry's first-class ApiManagement connection
    Scenario 3  AI GATEWAY LITELLM   a ModelGateway (bring-your-own) connection to LiteLLM

Every scenario runs the SAME three sub-scenarios against the SAME remote targets:

    a) MODEL  -> the enterprise gpt-4o-mini (behind APIM, load balanced across 2 regions)
    b) TOOL   -> the public Microsoft Learn MCP server (governed by the scenario's gateway)
    c) A2A    -> the remote "dummy specialist" Agent2Agent agent

so the only thing that changes between scenarios is HOW the client connects, not WHAT it
calls. Each sub-scenario creates its own clearly-named prompt agent, runs one turn, and
records a PASS/FAIL line (a blocked path is reported honestly instead of aborting the run).

Environment variables (see infra/client-foundry.bicep outputs / deploy-client-foundry.ps1):
    CLIENT_PROJECT_ENDPOINT   https://foundry-client-<suffix>.services.ai.azure.com/api/projects/aigateway-client
    MODEL_NAME                model id exposed by the gateways          (default gpt-4o-mini)
    DRIVER_MODEL              native deployment that ORCHESTRATES A2A   (default MODEL_NAME)
    MCP_APIM_URL              {apim}/learn-mcp/mcp
    MCP_APIM_CONN_ID          resource id of the mslearn-mcp-apim connection
    MCP_LITELLM_URL           {litellm}/mcp/
    MCP_LITELLM_CONN_ID       resource id of the mslearn-mcp-litellm connection
    A2A_DIRECT_URL            remote A2A agent host root
    A2A_DIRECT_CONN_ID        resource id of the dummy-a2a-direct connection
    KEEP_AGENT                set to 1 to persist agents for portal viewing (Build > Agents)
"""

import os

from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition, MCPTool, A2APreviewTool

ENDPOINT = os.environ["CLIENT_PROJECT_ENDPOINT"]
MODEL_NAME = os.environ.get("MODEL_NAME", "gpt-4o-mini")
# The managed A2A tool 500s when the calling agent's model is a *gateway* connection, so
# the A2A sub-scenario is always driven by a NATIVE deployment on the client account.
DRIVER_MODEL = os.environ.get("DRIVER_MODEL", MODEL_NAME)
KEEP_AGENT = os.environ.get("KEEP_AGENT", "").strip().lower() in ("1", "true", "yes")

MCP_APIM_URL = os.environ.get("MCP_APIM_URL")
MCP_APIM_CONN_ID = os.environ.get("MCP_APIM_CONN_ID")
MCP_LITELLM_URL = os.environ.get("MCP_LITELLM_URL")
MCP_LITELLM_CONN_ID = os.environ.get("MCP_LITELLM_CONN_ID")
A2A_DIRECT_URL = os.environ.get("A2A_DIRECT_URL")
A2A_DIRECT_CONN_ID = os.environ.get("A2A_DIRECT_CONN_ID")

# One canonical question per sub-scenario, reused across all three scenarios.
QUESTION_MODEL = "In one sentence, what does an AI gateway do?"
QUESTION_TOOL = "Search Microsoft Learn: what is Azure API Management? Answer in one sentence."
QUESTION_A2A = "Ask the specialist: should I put a gateway in front of my agents?"


def connect() -> AIProjectClient:
    """Open a client against the client Foundry project."""
    return AIProjectClient(endpoint=ENDPOINT, credential=DefaultAzureCredential())


def run_subscenario(project, results, label, definition, question) -> bool:
    """Create a prompt agent, run one turn, record PASS/FAIL, optionally persist."""
    agent = None
    openai_client = project.get_openai_client()
    conversation = None
    try:
        agent = project.agents.create_version(agent_name=label, definition=definition)
        conversation = openai_client.conversations.create()
        response = openai_client.responses.create(
            conversation=conversation.id,
            input=question,
            extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
        )
        text = (response.output_text or "").strip().replace("\n", " ")
        results.append((label, True, text[:160]))
        print(f"  [PASS] {label}: {text[:160]}")
        return True
    except Exception as exc:  # noqa: BLE001 - report honestly, keep going
        results.append((label, False, f"{type(exc).__name__}: {str(exc)[:160]}"))
        print(f"  [FAIL] {label}: {type(exc).__name__}: {str(exc)[:200]}")
        return False
    finally:
        if not KEEP_AGENT:
            try:
                if conversation:
                    openai_client.conversations.delete(conversation.id)
                if agent:
                    project.agents.delete_version(agent_name=agent.name, agent_version=agent.version)
            except Exception:  # noqa: BLE001 - best-effort cleanup
                pass


def model_def(model_ref: str) -> PromptAgentDefinition:
    """Sub-scenario (a): a plain model call through the scenario's connection."""
    return PromptAgentDefinition(
        model=model_ref,
        instructions="You are a concise assistant. Answer in one sentence.",
    )


def tool_def(model_ref: str, mcp_url: str, mcp_conn_id: str, governed_by: str) -> PromptAgentDefinition:
    """Sub-scenario (b): an MCP (Microsoft Learn) tool call governed by the scenario's gateway."""
    return PromptAgentDefinition(
        model=model_ref,
        instructions="Use the mslearn MCP tool to answer. Be concise.",
        tools=[MCPTool(
            server_label="mslearn",
            server_url=mcp_url,
            server_description=f"Microsoft Learn docs, governed by {governed_by}.",
            project_connection_id=mcp_conn_id,
            require_approval="never",
        )],
    )


def a2a_def(driver_model: str) -> PromptAgentDefinition:
    """Sub-scenario (c): an A2A call to the remote specialist (orchestrated by a native model)."""
    return PromptAgentDefinition(
        model=driver_model,
        instructions="Consult the dummy_specialist A2A agent. Be concise.",
        tools=[A2APreviewTool(
            name="dummy_specialist",
            description="A remote A2A specialist, reached directly at its host root.",
            base_url=A2A_DIRECT_URL,
            project_connection_id=A2A_DIRECT_CONN_ID,
        )],
    )


def print_summary(scenario_title: str, results) -> None:
    print(f"\n== {scenario_title} — SUMMARY ==")
    for label, ok, detail in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {label:<30} {detail}")
    if KEEP_AGENT:
        print("\nKEEP_AGENT set -> agents left in the client project (Build > Agents).")
