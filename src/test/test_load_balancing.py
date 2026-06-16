"""
Test the load-balanced Inference API exposed by Azure API Management.

It fires N requests at the APIM gateway and prints the Azure region that served
each one (from the `x-ms-region` response header). With a low TPM model capacity,
you should see the priority-1 backend get throttled (HTTP 429 handled transparently
by the APIM retry policy) and traffic fall back to the priority-2 backend.

Usage:
    set APIM_GATEWAY_URL=https://apim-xxxx.azure-api.net
    set APIM_API_KEY=<subscription key>
    python test_load_balancing.py
"""
import os
import time
import json
import requests

GATEWAY_URL = os.environ["APIM_GATEWAY_URL"].rstrip("/")
API_KEY = os.environ["APIM_API_KEY"]
API_PATH = os.environ.get("INFERENCE_API_PATH", "inference")
MODEL = os.environ.get("MODEL", "gpt-4o-mini")
API_VERSION = os.environ.get("API_VERSION", "2024-10-21")

RUNS = int(os.environ.get("RUNS", "20"))
SLEEP_MS = int(os.environ.get("SLEEP_MS", "100"))

url = f"{GATEWAY_URL}/{API_PATH}/openai/deployments/{MODEL}/chat/completions?api-version={API_VERSION}"
messages = {
    "messages": [
        {"role": "system", "content": "You are a sarcastic, unhelpful assistant."},
        {"role": "user", "content": "Can you tell me the time, please?"},
    ]
}

session = requests.Session()
session.headers.update({"api-key": API_KEY, "Content-Type": "application/json"})

region_counts = {}
try:
    for i in range(RUNS):
        start = time.time()
        resp = session.post(url, json=messages)
        elapsed = time.time() - start
        region = resp.headers.get("x-ms-region", "n/a")
        region_counts[region] = region_counts.get(region, 0) + 1
        print(f"Run {i + 1:>2}/{RUNS}  status={resp.status_code}  {elapsed:5.2f}s  region={region}")
        if resp.status_code != 200:
            print(f"    body: {resp.text[:200]}")
        time.sleep(SLEEP_MS / 1000)
finally:
    session.close()

print("\nRegion distribution:")
print(json.dumps(region_counts, indent=2))
