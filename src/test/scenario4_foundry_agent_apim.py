"""Scenario 4b - a consumer Foundry agent calls an enterprise Foundry agent through APIM.

Authentication is keyless on both hops:
  consumer project managed identity -> APIM
  APIM managed identity             -> enterprise Foundry A2A endpoint
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402
import scenario_lib as s  # noqa: E402
from azure.ai.projects.models import A2APreviewTool, PromptAgentDefinition  # noqa: E402

ENDPOINT = cfg.require("appProjectEndpoint", "APP_PROJECT_ENDPOINT")
DRIVER_MODEL = cfg.get("appDriverModel", "APP_DRIVER_MODEL", "gpt-4o-mini")
A2A_APIM_URL = cfg.require("enterpriseAgentApimUrl", "ENTERPRISE_AGENT_APIM_URL")
# Foundry resolves the agent card with urljoin, which drops the last path segment unless the
# base URL ends with a slash. Discovery must therefore use the trailing-slash form.
A2A_DISCOVERY_URL = cfg.get(
    "enterpriseAgentApimDiscoveryUrl",
    "ENTERPRISE_AGENT_APIM_DISCOVERY_URL",
    A2A_APIM_URL.rstrip("/") + "/",
)
A2A_CONNECTION_ID = cfg.require(
    "enterpriseAgentConsumerConnectionId",
    "ENTERPRISE_AGENT_CONSUMER_CONNECTION_ID",
)


def main() -> None:
    project = s.connect(ENDPOINT)
    results: list = []

    s.print_header(
        "Scenario 4b - Foundry app agent -> APIM -> enterprise Foundry agent",
        [
            "The consumer project managed identity authenticates to APIM; APIM uses its",
            "managed identity and least-privilege Foundry Agent Consumer role downstream.",
        ],
    )

    # azure-ai-projects 2.3+ models send this field directly. Constructing from a mapping also
    # preserves it on 2.2 clients, whose generated constructor predates the documented field.
    a2a_tool = A2APreviewTool({
        "type": "a2a_preview",
        "name": "enterprise_specialist",
        "description": "Enterprise Foundry specialist governed by APIM.",
        "base_url": A2A_DISCOVERY_URL,
        "project_connection_id": A2A_CONNECTION_ID,
        "send_credentials_for_agent_card": True,
    })
    definition = PromptAgentDefinition(
        model=DRIVER_MODEL,
        instructions=(
            "Delegate the question to the enterprise_specialist A2A agent. "
            "Summarize its answer concisely."
        ),
        tools=[a2a_tool],
    )
    succeeded = s.run_subscenario(
        project,
        results,
        "sc4-foundry-consumer-enterprise-agent-apim",
        definition,
        "Should enterprise agents be exposed through APIM? Give two practical reasons.",
        title="4b  AGENT - enterprise Foundry agent through APIM (managed identity)",
        calls=[
            ("consumer", ENDPOINT),
            ("A2A via APIM", A2A_DISCOVERY_URL),
            ("connection", s.short_conn(A2A_CONNECTION_ID)),
            ("auth", "ProjectManagedIdentity -> APIM -> APIM managed identity -> Foundry"),
        ],
    )
    s.print_summary("Scenario 4b - Foundry consumer app agent", results)
    if not succeeded:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
