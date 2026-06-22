"""
Config for the RAG comparison demo (MAF agents vs Foundry IQ).

Precedence for every value: explicit environment variable > infra/scenario-outputs.json
(reused from the Scenario 2 deployment) > default. Secrets (API keys) only ever come from
the environment — never the file.

The demo deliberately keeps two LLM "planes" separate so the APIM governance story is
explicit:

  * EMBEDDINGS + Foundry IQ planner/synthesis  -> Azure OpenAI **direct** endpoint.
    Foundry IQ's knowledge-base model does NOT support an APIM/AI-gateway hop today, so
    this must point straight at the AOAI resource.
  * MAF chat model (planner/synthesizer in 03_maf_rag.py) -> the **APIM** inference
    gateway reused from Scenario 2 (apimGatewayUrl). This is the governed plane we will
    formally wire to APIM "later"; the var is already here.
"""

import json
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.dirname(_HERE)
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


def get(key: str | None, env: str | None = None, default=None):
    """Resolve a value: env var first, then scenario-outputs.json, then default."""
    if env and os.environ.get(env):
        return os.environ[env]
    if key and _DATA.get(key):
        return _DATA[key]
    return default


# --- Document corpus -----------------------------------------------------------
DOCS_DIR = os.path.join(_HERE, "data", "docs")

# Each domain folder becomes its own Azure AI Search index (mix of doc types per domain).
INDEX_PREFIX = os.environ.get("INDEX_PREFIX", "fab")
DOMAINS = ["product-specs", "maintenance-sops", "safety-compliance"]


def index_name(domain: str) -> str:
    return f"{INDEX_PREFIX}-{domain}"


def knowledge_source_name(domain: str) -> str:
    return f"{INDEX_PREFIX}-{domain}-ks"


KNOWLEDGE_BASE_NAME = os.environ.get("KNOWLEDGE_BASE_NAME", f"{INDEX_PREFIX}-manufacturing-kb")


# --- Azure AI Search -----------------------------------------------------------
# Resolved lazily so importing config never fails; scripts call require_search() when needed.
SEARCH_ENDPOINT = get("searchEndpoint", "AZURE_SEARCH_ENDPOINT")
SEARCH_API_KEY = os.environ.get("AZURE_SEARCH_API_KEY")  # optional; DefaultAzureCredential if absent


def require_search() -> str:
    if not SEARCH_ENDPOINT:
        raise SystemExit(
            "Missing AZURE_SEARCH_ENDPOINT (e.g. https://<svc>.search.windows.net)."
        )
    return SEARCH_ENDPOINT


# --- Azure OpenAI (DIRECT plane: embeddings + Foundry IQ KB model) -------------
AOAI_ENDPOINT = get("aoaiEndpoint", "AZURE_OPENAI_ENDPOINT")
AOAI_API_KEY = os.environ.get("AZURE_OPENAI_API_KEY")  # optional; DefaultAzureCredential if absent
AOAI_API_VERSION = os.environ.get("AZURE_OPENAI_API_VERSION", "2024-10-21")

EMBED_DEPLOYMENT = os.environ.get("AZURE_OPENAI_EMBED_DEPLOYMENT", "text-embedding-3-small")
EMBED_MODEL = os.environ.get("AZURE_OPENAI_EMBED_MODEL", "text-embedding-3-small")
EMBED_DIMENSIONS = int(os.environ.get("AZURE_OPENAI_EMBED_DIMENSIONS", "1536"))

# Chat model used by Foundry IQ knowledge base (planner + answer synthesis). AOAI-direct.
KB_CHAT_DEPLOYMENT = os.environ.get("AZURE_OPENAI_CHAT_DEPLOYMENT", "gpt-4o-mini")
KB_CHAT_MODEL = os.environ.get("AZURE_OPENAI_CHAT_MODEL", "gpt-4o-mini")


# --- MAF chat model (GOVERNED plane: APIM inference gateway from Scenario 2) ----
APIM_GATEWAY_URL = get("apimGatewayUrl", "APIM_GATEWAY_URL")
APIM_API_KEY = os.environ.get("APIM_API_KEY")
APIM_INFERENCE_PATH = os.environ.get("INFERENCE_API_PATH", "inference")
MAF_MODEL = os.environ.get("MAF_MODEL", "gpt-4o-mini")
MAF_API_VERSION = os.environ.get("MAF_API_VERSION", "2024-10-21")
