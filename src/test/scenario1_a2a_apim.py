"""
A2A THROUGH APIM — a Foundry agent that reaches the dummy specialist fully via the gateway.

This is an ADDITIVE companion to Scenario 1. The standard scenarios reach the A2A
specialist *directly* at its Container App host root (the `dummy-a2a-direct` connection),
because a Foundry RemoteA2A connection posts message/send to the agent card's own `url`
field — and the dummy agent advertises its ACA URL there.

The `dummy-a2a-apim` connection (created by infra/a2a-apim.bicep) points at a NEW APIM API
that reuses the same Container App backend but rewrites the agent card's `url` to the APIM
gateway. So BOTH legs — card discovery AND message/send — flow through APIM, governed by
the api-key carried on the connection.

Prereqs:
    infra/deploy-a2a-apim.ps1   (creates the API + the dummy-a2a-apim connection, and
                                 merges a2aApimUrl + sc1A2aApimConnId into scenario-outputs.json)

Run:
    python scenario1_a2a_apim.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_lib as s  # noqa: E402
import scenario_config as cfg  # noqa: E402

ENDPOINT = cfg.require("sc1ProjectEndpoint", "SC1_PROJECT_ENDPOINT")
DRIVER_MODEL = cfg.get("sc1DriverModel", "SC1_DRIVER_MODEL", "gpt-4o-mini")
A2A_APIM_URL = cfg.require("a2aApimUrl", "A2A_APIM_URL")
A2A_APIM_CONN_ID = cfg.require("sc1A2aApimConnId", "SC1_A2A_APIM_CONN_ID")


def main() -> None:
    project = s.connect(ENDPOINT)
    results: list = []

    s.print_header(
        "A2A via APIM — Foundry agent reaches the specialist THROUGH the gateway",
        [
            "Same dummy specialist as every scenario, but the RemoteA2A connection points",
            "at the dummy-a2a-apim API: the card url is rewritten to the gateway, so both",
            "discovery and message/send flow through APIM (governed by the api-key).",
        ],
    )

    s.run_subscenario(
        project, results, "sc1-a2a-via-apim",
        s.a2a_def(DRIVER_MODEL, A2A_APIM_URL, A2A_APIM_CONN_ID),
        s.QUESTION_A2A,
        title="A2A — remote specialist through APIM (RemoteA2A connection + api-key)",
        calls=[
            ("driver model", DRIVER_MODEL),
            ("A2A url", A2A_APIM_URL),
            ("A2A conn", s.short_conn(A2A_APIM_CONN_ID)),
        ],
    )

    s.print_summary("A2A via APIM", results)


if __name__ == "__main__":
    main()
