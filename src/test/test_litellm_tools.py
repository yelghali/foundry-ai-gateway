"""
POC: prove the BYO LiteLLM gateway handles BOTH plain chat completions AND
tool/function calling against Azure AI Foundry models.

Point an OpenAI client at the local LiteLLM proxy (OpenAI-compatible) and ask a
question that should trigger a tool call.

Usage:
    set LITELLM_BASE_URL=http://localhost:4000
    set LITELLM_MASTER_KEY=sk-litellm-local-poc
    python test_litellm_tools.py
"""
import os
import json
from openai import OpenAI

client = OpenAI(
    base_url=os.environ.get("LITELLM_BASE_URL", "http://localhost:4000"),
    api_key=os.environ["LITELLM_MASTER_KEY"],
)

tools = [
    {
        "type": "function",
        "function": {
            "name": "get_current_weather",
            "description": "Get the current weather in a given location",
            "parameters": {
                "type": "object",
                "properties": {
                    "location": {"type": "string", "description": "City and state, e.g. Seattle, WA"},
                    "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]},
                },
                "required": ["location"],
            },
        },
    }
]

print("== 1) Plain chat completion ==")
chat = client.chat.completions.create(
    model="gpt-4o-mini",
    messages=[{"role": "user", "content": "Say hello in one short sentence."}],
)
print(chat.choices[0].message.content, "\n")

print("== 2) Tool / function calling ==")
resp = client.chat.completions.create(
    model="gpt-4o-mini",
    messages=[{"role": "user", "content": "What's the weather like in Boston today?"}],
    tools=tools,
    tool_choice="auto",
)
msg = resp.choices[0].message
if msg.tool_calls:
    call = msg.tool_calls[0]
    print(f"Tool requested: {call.function.name}")
    print(f"Arguments: {json.dumps(json.loads(call.function.arguments), indent=2)}")
    print("\n=> LiteLLM BYO gateway supports MODELS + TOOLS (function calling).")
else:
    print("No tool call returned:", msg.content)
