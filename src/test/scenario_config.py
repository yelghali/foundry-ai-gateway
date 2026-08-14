"""Configuration loader shared by the keyless two-consumer APIM scenarios.

The deployment scripts write a secret-free ``infra/scenario-outputs.json`` containing
endpoints, project connection IDs, gateway URLs, and model references. Resolution order is
environment variable, then the outputs file, then the caller's default.
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
        hint = f" (set {env} or run the infra deployment scripts)" if env else ""
        raise SystemExit(f"Missing required config '{key}'{hint}.")
    return value


def credential_process_timeout() -> int:
    """Seconds DefaultAzureCredential waits for the az / PowerShell CLI probe.

    The SDK default is 10s, which times out on machines where the Azure CLI starts
    slowly. Override with AZURE_CREDENTIAL_PROCESS_TIMEOUT.
    """
    try:
        return int(os.environ.get("AZURE_CREDENTIAL_PROCESS_TIMEOUT", "90"))
    except ValueError:
        return 90
