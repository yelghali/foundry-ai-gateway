"""
Tiny config loader shared by the consumption scenarios.

`deploy-client-foundry.ps1` writes a secret-free `infra/scenario-outputs.json` with the
per-scenario endpoints, connection IDs, gateway URLs and model references. The scenario
scripts read it through this module so a replay is just "deploy, then run the scripts" —
no long list of env vars to export by hand.

Precedence for every value: explicit environment variable > scenario-outputs.json > default.
Secrets are never written to the file: the Foundry scenarios authenticate with
DefaultAzureCredential, and Scenario 0 still reads APIM_API_KEY from the environment.
"""

import json
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(os.path.dirname(_HERE))
_OUTPUTS_FILE = os.environ.get(
    "SCENARIO_OUTPUTS_FILE",
    os.path.join(_REPO_ROOT, "infra", "scenario-outputs.json"),
)


def _load() -> dict:
    try:
        with open(_OUTPUTS_FILE, "r", encoding="utf-8-sig") as handle:
            return json.load(handle)
    except (FileNotFoundError, ValueError):
        return {}


_DATA = _load()


def get(key: str, env: str | None = None, default=None):
    """Resolve a value: env var first, then scenario-outputs.json, then default."""
    if env:
        value = os.environ.get(env)
        if value:
            return value
    if _DATA.get(key):
        return _DATA[key]
    return default


def require(key: str, env: str | None = None):
    """Like get(), but raise a clear error if the value is missing."""
    value = get(key, env)
    if not value:
        hint = f" (set {env} or run infra/deploy-client-foundry.ps1)" if env else ""
        raise SystemExit(f"Missing required config '{key}'{hint}.")
    return value
