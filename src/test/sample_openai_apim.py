"""
Scenario 1 — OpenAI SDK calling the APIM AI gateway (load-balanced Foundry models).

Uses the official `openai` SDK (AzureOpenAI client) instead of raw HTTP, pointed at
the APIM inference API. APIM load balances across two Foundry regions and authenticates
to them with its managed identity. The region that served each call is printed from the
`x-ms-region` response header.

Usage (PowerShell):
    $env:APIM_GATEWAY_URL = "https://apim-xxxx.azure-api.net"
    $env:APIM_API_KEY      = "<subscription key>"
    python sample_openai_apim.py
"""
import os

from openai import AzureOpenAI

GATEWAY_URL = os.environ["APIM_GATEWAY_URL"].rstrip("/")
API_KEY = os.environ["APIM_API_KEY"]
API_PATH = os.environ.get("INFERENCE_API_PATH", "inference")
MODEL = os.environ.get("MODEL", "gpt-4o-mini")
API_VERSION = os.environ.get("API_VERSION", "2024-10-21")
RUNS = int(os.environ.get("RUNS", "6"))

# The AzureOpenAI client builds Azure-style routes:
#   {azure_endpoint}/openai/deployments/{model}/chat/completions?api-version=...
# so azure_endpoint must include the APIM inference base path.
client = AzureOpenAI(
    api_key=API_KEY,
    azure_endpoint=f"{GATEWAY_URL}/{API_PATH}",
    api_version=API_VERSION,
)

counts = {}
for i in range(RUNS):
    raw = client.chat.completions.with_raw_response.create(
        model=MODEL,
        messages=[{"role": "user", "content": "Reply with a single word: hello"}],
        max_tokens=5,
    )
    region = raw.headers.get("x-ms-region", "n/a")
    completion = raw.parse()
    counts[region] = counts.get(region, 0) + 1
    print(f"Run {i + 1}/{RUNS}  region={region:<14}  -> {completion.choices[0].message.content!r}")

print("\nRegion distribution:", counts)
print("=> OpenAI SDK talked to load-balanced Foundry models through the APIM AI gateway.")
