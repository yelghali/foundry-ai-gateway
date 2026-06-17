"""
Shared helpers for the three Foundry-based consumption scenarios (1, 2, 3).

Each scenario now runs against its OWN dedicated client Foundry account, because the
native AI Gateway integration is configured at the Foundry *resource* level:

    Scenario 1  client-foundry-sc1   CUSTOM (APIM)      managed-identity-first, key fallback
    Scenario 2  client-foundry-sc2   AI GATEWAY NATIVE  Foundry's ApiManagement connection
    Scenario 3  client-foundry-sc3   AI GATEWAY BYO     ModelGateway connection to LiteLLM

Every scenario runs the SAME three sub-scenarios against the SAME remote targets:

    a) MODEL  -> the enterprise gpt-4o-mini (behind APIM, load balanced across 2 regions)
    b) TOOL   -> the public Microsoft Learn MCP server (governed by the scenario's gateway)
    c) A2A    -> the remote "dummy specialist" Agent2Agent agent

so the only thing that changes between scenarios is HOW the client connects, not WHAT it
calls. Each sub-scenario creates its own clearly-named prompt agent, runs one turn, and
records a PASS/FAIL line (a blocked path is reported honestly instead of aborting the run).

The per-scenario endpoints, connection IDs and gateway URLs are read from
infra/scenario-outputs.json (written by deploy-client-foundry.ps1); env vars override.
See scenario_config.py for the precedence rules.

    KEEP_AGENT   set to 0 to delete agents after the run; default keeps them for
                 portal viewing (Build > Agents)
"""

import os
import sys

from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition, MCPTool, A2APreviewTool

# --- Pretty colors (ANSI) ------------------------------------------------------
# Enable ANSI on Windows terminals and honor NO_COLOR / non-tty output.
if os.name == "nt":
    os.system("")  # turns on virtual-terminal processing in the console
_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None

BOLD = "1"
DIM = "2"
RED = "31"
GREEN = "32"
YELLOW = "33"
BLUE = "34"
MAGENTA = "35"
CYAN = "36"
GREY = "90"


def _c(text: str, *codes: str) -> str:
    """Wrap text in ANSI color codes (no-op when colors are disabled)."""
    if not _COLOR or not codes:
        return text
    return f"\033[{';'.join(codes)}m{text}\033[0m"


def short_conn(conn_id: str) -> str:
    """Reduce a full ARM connection id to just its connection name for display."""
    if not conn_id:
        return ""
    return conn_id.rstrip("/").split("/")[-1]


def _section(title: str, calls) -> None:
    """Print a clear banner for a sub-scenario and the URL(s)/connection(s) it calls."""
    rule = _c("─" * 78, CYAN)
    print()
    print(rule)
    print(_c(f" {title}", BOLD, CYAN))
    for what, value in (calls or []):
        print(f"    {_c(f'{what:<13}', BOLD, YELLOW)} {_c('→', GREY)} {_c(str(value), BLUE)}")
    print(rule)


def _print_record(label: str, ok: bool, detail: str) -> None:
    badge = _c(" PASS ", BOLD, "30", "42") if ok else _c(" FAIL ", BOLD, "30", "41")
    name = _c(label, BOLD, GREEN if ok else RED)
    print(f"  {badge} {name}")
    print(f"        {_c(detail, DIM)}")


def print_header(title: str, lines) -> None:
    """Print a colored scenario header banner."""
    print(_c("═" * 78, MAGENTA))
    print(_c(f" {title}", BOLD, MAGENTA))
    for ln in lines:
        print(_c(f" {ln}", DIM))
    print(_c("═" * 78, MAGENTA))
# -------------------------------------------------------------------------------

# Agents persist by default so every scenario is visible in the portal (Build > Agents).
# Set KEEP_AGENT=0 (or false/no) to clean them up after the run instead.
KEEP_AGENT = os.environ.get("KEEP_AGENT", "1").strip().lower() not in ("0", "false", "no", "")

# One canonical question per sub-scenario, reused across all three scenarios.
QUESTION_MODEL = "In one sentence, what does an AI gateway do?"
QUESTION_TOOL = "Search Microsoft Learn: what is Azure API Management? Answer in one sentence."
QUESTION_A2A = "Ask the specialist: should I put a gateway in front of my agents?"


def connect(endpoint: str) -> AIProjectClient:
    """Open a client against a scenario's own client Foundry project."""
    return AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential())


def run_subscenario(project, results, label, definition, question, *, title=None, calls=None) -> bool:
    """Create a prompt agent, run one turn, record PASS/FAIL, optionally persist.

    Pass `title` + `calls` to print a clear section banner (with the URLs/connections
    this sub-scenario reaches) before running it.
    """
    if title is not None or calls:
        _section(title or label, calls)
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
        _print_record(label, True, text[:160])
        return True
    except Exception as exc:  # noqa: BLE001 - report honestly, keep going
        results.append((label, False, f"{type(exc).__name__}: {str(exc)[:160]}"))
        _print_record(label, False, f"{type(exc).__name__}: {str(exc)[:200]}")
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


def a2a_def(
    driver_model: str,
    a2a_url: str,
    a2a_conn_id: str,
    description: str = "A remote A2A specialist, reached directly at its host root.",
) -> PromptAgentDefinition:
    """Sub-scenario (c): an A2A call to the remote specialist (orchestrated by a native model)."""
    return PromptAgentDefinition(
        model=driver_model,
        instructions="Consult the dummy_specialist A2A agent. Be concise.",
        tools=[A2APreviewTool(
            name="dummy_specialist",
            description=description,
            base_url=a2a_url,
            project_connection_id=a2a_conn_id,
        )],
    )


def print_summary(scenario_title: str, results) -> None:
    print()
    print(_c("═" * 78, MAGENTA))
    print(_c(f" {scenario_title} — SUMMARY", BOLD, MAGENTA))
    print(_c("═" * 78, MAGENTA))
    for label, ok, detail in results:
        badge = _c(" PASS ", BOLD, "30", "42") if ok else _c(" FAIL ", BOLD, "30", "41")
        name = _c(f"{label:<34}", BOLD, GREEN if ok else RED)
        print(f"  {badge} {name} {_c(detail[:90], DIM)}")
    if KEEP_AGENT:
        print(_c("\n Agents left in the client project (Build > Agents). Set KEEP_AGENT=0 to clean up.", DIM))
