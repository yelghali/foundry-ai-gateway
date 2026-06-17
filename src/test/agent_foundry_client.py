"""
Client Foundry agent — consumes ENTERPRISE resources through gateways.

This runs on the dedicated *client* Foundry (foundry-client, which has NO model
deployments of its own). It demonstrates every way the client consumes the two
enterprise foundries that sit behind APIM (scenario 1, load balanced):

  MODEL (3 connection types, all reaching the enterprise models):
    * apim-gateway   (ApiManagement) -> APIM /inference/openai      "AI Gateway native"
    * litellm-gateway(ModelGateway)  -> LiteLLM                     "BYO gateway"
    * apim-custom    (CustomKeys)    -> APIM /inference/openai      "custom, gateway URL"

  TOOLS (governed the same way):
    * MS Learn MCP behind APIM       (CustomKeys conn -> {apim}/learn-mcp/mcp)
    * MS Learn MCP behind LiteLLM    (CustomKeys conn -> {litellm}/mcp/)
    * Remote A2A specialist          (RemoteA2A conn  -> agent host-root card)

Each leg creates its own clearly-named prompt agent and runs one turn, printing a
PASS/FAIL line so unsupported paths are reported honestly rather than aborting the run.

Environment variables (all have sensible names; see infra/client-foundry.bicep outputs):
    CLIENT_PROJECT_ENDPOINT     https://foundry-client-<suffix>.services.ai.azure.com/api/projects/aigateway-client
    MODEL_NAME                  model id exposed by the gateways (default gpt-4o-mini)
    MCP_APIM_URL                {apim}/learn-mcp/mcp
    MCP_APIM_CONN_ID            resource id of the mslearn-mcp-apim connection
    MCP_LITELLM_URL             {litellm}/mcp/
    MCP_LITELLM_CONN_ID         resource id of the mslearn-mcp-litellm connection
    A2A_DIRECT_URL              remote A2A agent host root
    A2A_DIRECT_CONN_ID          resource id of the dummy-a2a-direct connection
    KEEP_AGENT                  set to 1 to persist agents for portal viewing
"""

import os

from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition, MCPTool, A2APreviewTool

ENDPOINT = os.environ["CLIENT_PROJECT_ENDPOINT"]
MODEL_NAME = os.environ.get("MODEL_NAME", "gpt-4o-mini")
# Native deployment on the client account used to DRIVE the A2A tool (Foundry's managed
# A2A 500s when the calling agent's model is a gateway connection). Defaults to MODEL_NAME.
DRIVER_MODEL = os.environ.get("DRIVER_MODEL", MODEL_NAME)
KEEP_AGENT = os.environ.get("KEEP_AGENT", "").strip().lower() in ("1", "true", "yes")

MCP_APIM_URL = os.environ.get("MCP_APIM_URL")
MCP_APIM_CONN_ID = os.environ.get("MCP_APIM_CONN_ID")
MCP_LITELLM_URL = os.environ.get("MCP_LITELLM_URL")
MCP_LITELLM_CONN_ID = os.environ.get("MCP_LITELLM_CONN_ID")
A2A_DIRECT_URL = os.environ.get("A2A_DIRECT_URL")
A2A_DIRECT_CONN_ID = os.environ.get("A2A_DIRECT_CONN_ID")

results: list[tuple[str, bool, str]] = []


def _run(project, agent_name, definition, question):
    """Create a prompt agent, run one turn, record PASS/FAIL, optionally persist."""
    agent = None
    openai_client = project.get_openai_client()
    conversation = None
    try:
        agent = project.agents.create_version(agent_name=agent_name, definition=definition)
        conversation = openai_client.conversations.create()
        response = openai_client.responses.create(
            conversation=conversation.id,
            input=question,
            extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}},
        )
        text = (response.output_text or "").strip().replace("\n", " ")
        results.append((agent_name, True, text[:160]))
        print(f"  [PASS] {agent_name}: {text[:160]}")
        return True
    except Exception as exc:  # noqa: BLE001 - report honestly, keep going
        results.append((agent_name, False, f"{type(exc).__name__}: {str(exc)[:160]}"))
        print(f"  [FAIL] {agent_name}: {type(exc).__name__}: {str(exc)[:200]}")
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


def main() -> None:
    project = AIProjectClient(endpoint=ENDPOINT, credential=DefaultAzureCredential())

    print("== MODEL: enterprise models via 3 connection types ==")
    print("   (client-custom-model is an EXPECTED FAIL: a CustomKeys connection cannot")
    print("    back a model deployment -- Foundry serves models only via the")
    print("    ApiManagement and ModelGateway categories. Custom keys are for tools.)")
    for agent_name, conn in (
        ("client-apim-model", "apim-gateway"),       # AI Gateway native (ApiManagement)
        ("client-litellm-model", "litellm-gateway"),  # BYO gateway (ModelGateway)
        ("client-custom-model", "apim-custom"),       # custom (CustomKeys) -> EXPECTED FAIL
    ):
        _run(
            project,
            agent_name,
            PromptAgentDefinition(
                model=f"{conn}/{MODEL_NAME}",
                instructions="You are a concise assistant. Answer in one sentence.",
            ),
            "In one sentence, what does an AI gateway do?",
        )

    print("\n== TOOL (MCP): MS Learn behind each gateway ==")
    if MCP_APIM_URL and MCP_APIM_CONN_ID:
        _run(
            project,
            "client-mcp-apim",
            PromptAgentDefinition(
                model=f"apim-gateway/{MODEL_NAME}",
                instructions="Use the mslearn MCP tool to answer. Be concise.",
                tools=[MCPTool(
                    server_label="mslearn",
                    server_url=MCP_APIM_URL,
                    server_description="Microsoft Learn docs, governed by APIM.",
                    project_connection_id=MCP_APIM_CONN_ID,
                    require_approval="never",
                )],
            ),
            "Search Microsoft Learn: what is Azure API Management? Answer in one sentence.",
        )
    if MCP_LITELLM_URL and MCP_LITELLM_CONN_ID:
        _run(
            project,
            "client-mcp-litellm",
            PromptAgentDefinition(
                model=f"litellm-gateway/{MODEL_NAME}",
                instructions="Use the mslearn MCP tool to answer. Be concise.",
                tools=[MCPTool(
                    server_label="mslearn",
                    server_url=MCP_LITELLM_URL,
                    server_description="Microsoft Learn docs, governed by LiteLLM.",
                    project_connection_id=MCP_LITELLM_CONN_ID,
                    require_approval="never",
                )],
            ),
            "Search Microsoft Learn: what is Azure API Management? Answer in one sentence.",
        )

    print("\n== AGENT (A2A): remote specialist, direct host-root card ==")
    if A2A_DIRECT_URL and A2A_DIRECT_CONN_ID:
        _run(
            project,
            "client-a2a-direct",
            PromptAgentDefinition(
                # A2A orchestration must run on a NATIVE deployment, not a gateway conn.
                model=DRIVER_MODEL,
                instructions="Consult the dummy_specialist A2A agent. Be concise.",
                tools=[A2APreviewTool(
                    name="dummy_specialist",
                    description="A remote A2A specialist, reached directly at its host root.",
                    base_url=A2A_DIRECT_URL,
                    project_connection_id=A2A_DIRECT_CONN_ID,
                )],
            ),
            "Ask the specialist: should I put a gateway in front of my agents?",
        )

    print("\n== SUMMARY ==")
    for name, ok, detail in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {name:<22} {detail}")
    if KEEP_AGENT:
        print("\nKEEP_AGENT set — agents left in the client project (Build > Agents).")


if __name__ == "__main__":
    main()
