"""Foundry-hosted agent consumes an APIM-published model without keys.

The project uses a project-scoped ``ApiManagement`` connection authenticated by its
managed identity:

    Foundry project MI -> APIM -> APIM MI -> enterprise Foundry model pool

There is deliberately no subscription-key fallback.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402
import scenario_lib as s  # noqa: E402

ENDPOINT = cfg.require("appProjectEndpoint", "APP_PROJECT_ENDPOINT")
MODEL = cfg.get("appModel", "APP_MODEL", "apim-gateway-mi/gpt-4o-mini")


def main() -> None:
    project = s.connect(ENDPOINT)
    results: list = []
    s.print_header(
        "Scenario 1b - Foundry agent -> APIM model pool",
        [
            "The project managed identity authenticates to customer-owned APIM.",
            "APIM uses its managed identity to reach the enterprise Foundry model pool.",
        ],
    )
    ok = s.run_subscenario(
        project,
        results,
        "sc1-foundry-apim-model-mi",
        s.model_def(MODEL),
        s.QUESTION_MODEL,
        title="1b  MODEL - ApiManagement connection (project managed identity)",
        calls=[
            ("consumer", ENDPOINT),
            ("model conn", MODEL),
            ("auth", "ProjectManagedIdentity -> APIM -> APIM managed identity -> Foundry"),
        ],
    )
    s.print_summary("Scenario 1b - Foundry model consumer", results)
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()