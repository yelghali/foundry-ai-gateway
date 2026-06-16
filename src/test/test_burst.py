"""
Burst load test — forces the priority-1 backend to throttle so you can watch
APIM fail over to the priority-2 region.

It fires many CONCURRENT requests with a sizeable prompt to blow past the
(intentionally low) tokens-per-minute capacity of the priority-1 deployment.
APIM's retry policy hides the 429s; you should see the region mix shift from the
priority-1 region to the priority-2 region.

Usage:
    set APIM_GATEWAY_URL=https://apim-xxxx.azure-api.net
    set APIM_API_KEY=<subscription key>
    python test_burst.py
"""
import os
import time
import json
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests

GATEWAY_URL = os.environ["APIM_GATEWAY_URL"].rstrip("/")
API_KEY = os.environ["APIM_API_KEY"]
API_PATH = os.environ.get("INFERENCE_API_PATH", "inference")
MODEL = os.environ.get("MODEL", "gpt-4o-mini")
API_VERSION = os.environ.get("API_VERSION", "2024-10-21")

TOTAL = int(os.environ.get("TOTAL", "60"))
CONCURRENCY = int(os.environ.get("CONCURRENCY", "15"))

url = f"{GATEWAY_URL}/{API_PATH}/openai/deployments/{MODEL}/chat/completions?api-version={API_VERSION}"

# A larger prompt + completion burns tokens faster to exhaust the TPM cap.
filler = "Explain the history and architecture of cloud computing in detail. " * 20
payload = {
    "messages": [
        {"role": "system", "content": "You are a verbose, detailed technical writer."},
        {"role": "user", "content": filler},
    ],
    "max_tokens": 200,
}

headers = {"api-key": API_KEY, "Content-Type": "application/json"}


def fire(i: int):
    start = time.time()
    try:
        r = requests.post(url, headers=headers, json=payload, timeout=120)
        region = r.headers.get("x-ms-region", "n/a")
        return (i, r.status_code, region, time.time() - start, r.text[:120] if r.status_code != 200 else "")
    except Exception as exc:  # noqa: BLE001
        return (i, "ERR", "n/a", time.time() - start, str(exc)[:120])


results = []
with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
    futures = [pool.submit(fire, i) for i in range(TOTAL)]
    for fut in as_completed(futures):
        results.append(fut.result())

results.sort(key=lambda x: x[0])
region_counts = {}
status_counts = {}
for i, status, region, elapsed, err in results:
    region_counts[region] = region_counts.get(region, 0) + 1
    status_counts[str(status)] = status_counts.get(str(status), 0) + 1
    line = f"Req {i + 1:>3}  status={status}  {elapsed:5.2f}s  region={region}"
    if err:
        line += f"  {err}"
    print(line)

print("\nStatus distribution:")
print(json.dumps(status_counts, indent=2))
print("\nRegion distribution (which backend served each request):")
print(json.dumps(region_counts, indent=2))
