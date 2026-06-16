# APIM ❤️ Azure AI Foundry — Building an AI Gateway

A hands-on **MOAW lab** showing four complementary ways to put an *AI gateway* in front of [Azure AI Foundry](https://learn.microsoft.com/azure/ai-foundry/):

1. **Azure API Management (APIM) as an AI gateway** — load balance one model across **two Foundry regions** with a backend pool, priority/weight routing, circuit breakers, and transparent 429 retries.
2. **MCP governance** — expose and govern the **Microsoft Learn MCP server** through APIM.
3. **Foundry native AI Gateway** — the built-in portal experience that attaches an APIM **v2** instance to a Foundry resource for per-project token limits.
4. **Bring your own gateway** — a proof-of-concept with the open-source **LiteLLM** proxy in front of Foundry.

The full, step-by-step workshop is in **[workshop.md](workshop.md)** (MOAW format).

## Repository structure

```
foundry-ai-gateway/
├── workshop.md              # MOAW lab (front matter + 4 sections)
├── README.md                # this file
├── infra/
│   ├── main.bicep           # APIM Standard v2 + 2 Foundry regions + backend pool + inference API
│   ├── policy.xml           # load-balance + retry-on-429/503 + managed-identity auth
│   ├── deploy.ps1           # one-command deploy
│   └── cleanup.ps1          # tear down
└── src/
    ├── test/
    │   ├── test_load_balancing.py   # hits APIM, shows the region serving each request│   │   ├── test_burst.py            # concurrent burst that forces priority failover    │   ├── test_litellm_tools.py    # proves LiteLLM handles models + tools
    │   └── requirements.txt
    └── litellm/
        ├── config.yaml      # LiteLLM proxy config (2 Foundry regions, router)
        ├── docker-compose.yml
        └── .env.example
```

## Quickstart

> Requires Azure CLI (`az`), Owner (or Contributor + RBAC Administrator) on the subscription, and `gpt-4o-mini` quota in two regions. APIM **Standard v2** is used so the same instance can be reused for the native AI Gateway (Part 3).

```powershell
# 1. Sign in
az login
az account set --subscription "<your-subscription-id>"

# 2. Deploy (resource group lab-foundry-ai-gateway in eastus2)
cd infra
./deploy.ps1            # prints APIM gateway URL + subscription key + Foundry endpoints

# 3. Test load balancing
pip install -r ../src/test/requirements.txt
$env:APIM_GATEWAY_URL = "<apimResourceGatewayURL>"
$env:APIM_API_KEY      = "<subscription key>"
python ../src/test/test_load_balancing.py     # steady traffic (stays on priority 1)
python ../src/test/test_burst.py              # concurrent burst -> forces failover

# 4. Clean up when done
./cleanup.ps1
```

> **Validated:** A 60-request concurrent burst against the deployed gateway returned **60 × HTTP 200** (the retry policy absorbed every 429) with the load splitting **East US 2: 39 / Sweden Central: 21** — priority-1 served traffic until its 8K-TPM cap, then APIM failed over to priority-2 automatically.

## Integration features comparison

The three gateway approaches differ most in **what they can govern**. The matrix below summarizes how each integrates with Foundry building blocks — **models**, **tools** (function calling / MCP), **agents**, and the **Foundry control plane**.

| Integration feature | **APIM AI gateway** (you build — Parts 1–2) | **Foundry native AI Gateway** (Part 3) | **LiteLLM** — bring your own (Part 4) |
|---|---|---|---|
| **Models** — chat/completions & embeddings | ✅ Load balanced across regions via backend pool, circuit breaker, retry policy | ✅ Routed through attached APIM v2 with per-project token limits | ✅ Routed via `azure_ai/` provider; client-side router for LB/fallback |
| **Models** — auth to Foundry | ✅ APIM **managed identity** (no keys in policy) | ✅ Managed by the platform | ⚠️ API key or AAD token in proxy config |
| **Tools** — function calling pass-through | ✅ Passed through to the model | ✅ Passed through to the model | ✅ `tools`/`tool_choice` pass-through; returns `tool_calls` |
| **Tools** — govern external MCP servers | ✅ Expose/govern MCP (e.g. Learn MCP) with policies | ✅ MCP/A2A tool governance via control plane | ❌ Not an MCP governance layer |
| **Tools** — execution host | ❌ Client executes the tool | ❌ Client/agent executes the tool | ❌ Client executes the tool |
| **Agents** — hosted agent runtime | ❌ Not an agent runtime (gateway only) | ✅ Integrates with **Foundry Agent Service** + custom agent registration | ❌ Not an agent runtime |
| **Agents** — as a model backend for frameworks | ✅ OpenAI-compatible endpoint | ✅ Via Foundry projects | ✅ Point Semantic Kernel/LangChain at the OpenAI-compatible endpoint |
| **Foundry control plane** — registered/discoverable | ⚠️ Only when attached as the native AI Gateway | ✅ First-class: per-project quotas, custom agent registration, tool governance | ❌ Independent proxy; **cannot** register in Foundry's control plane |
| **Per-project token limits / quotas** | ⚠️ Custom policy | ✅ Built-in | ⚠️ Virtual-key budgets only |
| **Observability** | ✅ APIM metrics + GatewayLogs + LLM logging | ✅ Through attached APIM | ⚠️ LiteLLM logs / callbacks |
| **Portability across providers/clouds** | ⚠️ Azure-centric | ⚠️ Azure-only | ✅ Multi-provider |
| **Setup effort** | Medium (IaC) | Low (portal) | Low–medium (container) |

### Bottom line

- **Models + tools (function calling):** all three work. LiteLLM is fully capable as a **model + tool-passthrough gateway** and is the most portable.
- **Agents:** only the **Foundry native AI Gateway** integrates with the **Foundry Agent Service** and agent/tool governance. APIM and LiteLLM serve as the **model backend** for agent frameworks but are not agent runtimes.
- **Foundry control plane:** only **Azure API Management (v2)** can be registered as Foundry's AI Gateway. A third-party gateway like **LiteLLM cannot** be registered/discovered by Foundry's control plane — it sits in front as an independent proxy.

**Guidance:** Use **APIM** (built or native) when you need Foundry-native governance — per-project quotas, agent/tool governance, control-plane registration. Use **LiteLLM** when you want a portable, multi-provider model + function-calling gateway and don't need Foundry's control plane.

## References

- [Backend pool load balancing lab (AI-Gateway)](https://github.com/Azure-Samples/AI-Gateway/blob/main/labs/backend-pool-load-balancing/backend-pool-load-balancing.ipynb)
- [AI gateway capabilities in Azure API Management](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities)
- [Configure AI Gateway in your Foundry resources](https://learn.microsoft.com/azure/foundry/configuration/enable-ai-api-management-gateway-portal)
- [Expose an existing MCP server in APIM](https://learn.microsoft.com/azure/api-management/expose-existing-mcp-server)
- [Microsoft Learn MCP server](https://learn.microsoft.com/training/support/mcp)
- [LiteLLM — Azure AI provider](https://docs.litellm.ai/docs/providers/azure_ai)
