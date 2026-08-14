"""Local Microsoft Agent Framework agent consumes the APIM model pool without keys.

Authentication is keyless on both hops:

    DefaultAzureCredential -> APIM -> APIM managed identity -> enterprise Foundry model pool
"""

import asyncio
import os
import sys

from agent_framework.openai import OpenAIChatCompletionClient
from azure.identity.aio import DefaultAzureCredential

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenario_config as cfg  # noqa: E402

GATEWAY_URL = cfg.require("apimGatewayUrl", "APIM_GATEWAY_URL").rstrip("/")
API_PATH = cfg.get("modelApimMiPath", "MODEL_APIM_MI_PATH", "inference-mi")
MODEL = cfg.get("enterpriseModel", "MODEL", "gpt-4o-mini")
API_VERSION = cfg.get("inferenceApiVersion", "API_VERSION", "2024-10-21")


async def main() -> None:
    credential = DefaultAzureCredential(process_timeout=cfg.credential_process_timeout())
    endpoint = f"{GATEWAY_URL}/{API_PATH}"
    print("Scenario 1a - local MAF agent -> APIM model pool")
    print(f"  Endpoint: {endpoint}")
    print("  Auth    : DefaultAzureCredential -> APIM -> APIM managed identity -> Foundry")
    try:
        client = OpenAIChatCompletionClient(
            model=MODEL,
            azure_endpoint=endpoint,
            api_version=API_VERSION,
            credential=credential,
        )
        agent = client.as_agent(
            name="sc1-maf-apim-model-mi",
            instructions="You are a concise assistant. Answer in one sentence.",
        )
        result = await agent.run("In one sentence, what does an AI gateway do?")
        text = (result.text or "").strip().replace("\n", " ")
        if not text:
            raise RuntimeError("The model returned an empty response.")
        print(f"  PASS    : {text}")
    finally:
        await credential.close()


if __name__ == "__main__":
    asyncio.run(main())