"""Direct Foundry Responses invocation (comparison path; intentionally bypasses APIM).

This demonstrates the alternate call shape requested by the workshop: use the enterprise
project endpoint and identify the deployed agent by name in agent_reference. Use A2A through
APIM for the governed cross-application endpoint.
"""

import os
import sys

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402

PROJECT_ENDPOINT = cfg.require("enterpriseProjectEndpoint", "ENTERPRISE_PROJECT_ENDPOINT")
AGENT_NAME = cfg.get("enterpriseAgentName", "ENTERPRISE_AGENT_NAME", "enterprise-specialist")


def main() -> None:
    project = AIProjectClient(
        endpoint=PROJECT_ENDPOINT,
        credential=DefaultAzureCredential(process_timeout=cfg.credential_process_timeout()),
    )
    response = project.get_openai_client().responses.create(
        input="In one sentence, what is an enterprise AI gateway?",
        extra_body={
            "agent_reference": {
                "name": AGENT_NAME,
                "type": "agent_reference",
            }
        },
    )
    print(response.output_text)


if __name__ == "__main__":
    main()
