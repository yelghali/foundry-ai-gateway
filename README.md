# APIM ❤️ Azure AI Foundry — Building an AI Gateway

A hands-on **MOAW lab** showing five complementary ways to put an *AI gateway* in front of [Azure AI Foundry](https://learn.microsoft.com/azure/ai-foundry/):

1. **Azure API Management (APIM) as an AI gateway** — load balance one model across **two Foundry regions** with a backend pool, priority/weight routing, circuit breakers, and transparent 429 retries.
2. **MCP governance** — expose and govern the **Microsoft Learn MCP server** through APIM.
3. **Foundry native AI Gateway** — the built-in portal experience that attaches an APIM **v2** instance to a Foundry resource for per-project token limits.
4. **Bring your own gateway** — a proof-of-concept with the open-source **LiteLLM** proxy in front of Foundry.
5. **Bring your own gateway *into* Foundry** — register your gateway with **Foundry Agent Service** as a connection (your APIM as an `ApiManagement` connection, or LiteLLM as a `ModelGateway` connection) so agents run their models through it.

![Overview: apps and Foundry Agent Service reach Foundry models through APIM (Parts 1-3) or LiteLLM (Part 4), load-balanced across two Foundry regions; APIM also governs the Microsoft Learn MCP server.](docs/assets/overview.drawio.svg)

The full, step-by-step workshop is in **[workshop.md](workshop.md)** (MOAW format).

## Repository structure

```
foundry-ai-gateway/
├── workshop.md              # MOAW lab (front matter + 5 parts)
├── README.md                # this file
├── infra/
│   ├── main.bicep           # APIM Standard v2 + 2 Foundry regions + backend pool + inference API
│   ├── policy.xml           # load-balance + retry-on-429/503 + managed-identity auth
│   ├── deploy.ps1           # one-command deploy (Parts 1–3)
│   ├── litellm-foundry.bicep        # Part 5: LiteLLM on Container Apps + Foundry Model Gateway connection
│   ├── deploy-litellm-foundry.ps1   # Part 5: deploy the LiteLLM (ModelGateway) variant
│   ├── apim-foundry.bicep           # Part 5: APIM as a Foundry ApiManagement connection
│   ├── deploy-apim-foundry.ps1      # Part 5: deploy the APIM-connection variant
│   └── cleanup.ps1          # tear down
└── src/
    ├── test/
    │   ├── test_load_balancing.py   # APIM: shows the region serving each request
    │   ├── test_burst.py            # APIM: concurrent burst that forces failover
    │   ├── sample_openai_apim.py    # APIM: OpenAI SDK (AzureOpenAI) client
    │   ├── agent_apim.py            # APIM: OpenAI Agents SDK agent + tool
    │   ├── agent_maf_apim.py        # APIM: Microsoft Agent Framework agent + tool
    │   ├── test_litellm_tools.py    # LiteLLM: models + tools (function calling)
    │   ├── sample_openai_litellm.py # LiteLLM: OpenAI SDK (OpenAI) client
    │   ├── agent_litellm.py         # LiteLLM: OpenAI Agents SDK agent + tool
    │   ├── agent_maf_litellm.py     # LiteLLM: Microsoft Agent Framework agent + tool
    │   ├── agent_foundry_litellm.py # Part 5: Foundry agent via the LiteLLM (ModelGateway) connection
    │   ├── agent_foundry_apim.py    # Part 5: Foundry agent via the APIM connection
    │   └── requirements.txt
    └── litellm/
        ├── config.yaml          # LiteLLM proxy config — Part 4 (static Entra ID token)
        ├── config.foundry.yaml  # LiteLLM proxy config — Part 5 (managed identity, auto-refresh)
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
python ../src/test/sample_openai_apim.py      # OpenAI SDK (AzureOpenAI) -> APIM
python ../src/test/agent_apim.py              # OpenAI Agents SDK agent + tool -> APIM
python ../src/test/agent_maf_apim.py          # Microsoft Agent Framework agent + tool -> APIM

# 4. (Part 5) Bring your own gateway INTO Foundry. Two connection types:
#    (a) APIM as an "ApiManagement" connection (reuses Parts 1-3 — no container)
./deploy-apim-foundry.ps1                       # creates the ApiManagement connection
$env:FOUNDRY_PROJECT_ENDPOINT = "https://<account>.services.ai.azure.com/api/projects/<project>"
$env:FOUNDRY_MODEL_DEPLOYMENT_NAME = "apim-gateway/gpt-4o-mini"
python ../src/test/agent_foundry_apim.py       # Foundry agent runs its model THROUGH APIM
#    (b) LiteLLM on Container Apps as a "ModelGateway" connection
./deploy-litellm-foundry.ps1                   # deploys LiteLLM + creates the connection
$env:FOUNDRY_MODEL_DEPLOYMENT_NAME = "litellm-gateway/gpt-4o-mini"
python ../src/test/agent_foundry_litellm.py    # Foundry agent runs its model THROUGH LiteLLM

# 5. Clean up when done
./cleanup.ps1
```

> **Validated end to end** against the deployed gateway:
> - **Load balancing + failover** — a 60-request concurrent burst returned **60 × HTTP 200** (the retry policy absorbed every 429) splitting **East US 2: 39 / Sweden Central: 21** — priority-1 served traffic until its 8K-TPM cap, then APIM failed over to priority-2.
> - **OpenAI SDK + agent** — `sample_openai_apim.py` (official SDK) and `agent_apim.py` (OpenAI Agents SDK with a tool) both ran on the gateway; the agent answered *"250 US dollars is approximately 230 euros and 197.50 pounds"* after calling its tool.
> - **LiteLLM BYO (Entra ID auth)** — `test_litellm_tools.py` returned a chat reply **and** a `get_current_weather` tool call; `agent_litellm.py` ran the same agent on LiteLLM — proving **models + tools + agents**.
> - **LiteLLM *into* Foundry (Part 5)** — LiteLLM deployed to **Azure Container Apps** (managed identity, Entra ID auto-refresh) and registered as a Foundry **Model Gateway connection**. `GET /v1/models` → 200, `POST /v1/chat/completions` → 200, and a **Foundry Agent Service** prompt agent (`litellm-gateway/gpt-4o-mini`) replied end to end *through the gateway* — proving **Foundry Agent Service → connection → LiteLLM → Foundry**.
> - **APIM *into* Foundry (Part 5)** — the existing APIM instance registered as a Foundry **`ApiManagement`** connection (`provisioningState: Succeeded`, `target: .../inference/openai`, `deploymentInPath: true`). A **Foundry Agent Service** prompt agent (`apim-gateway/gpt-4o-mini`) replied end to end *through APIM* — proving **Foundry Agent Service → ApiManagement connection → APIM → Foundry (backend pool)**.

## Integration features comparison

The three gateway approaches differ most in **what they can govern**. The matrix below summarizes how each integrates with Foundry building blocks — **models**, **tools** (function calling / MCP), **agents**, and the **Foundry control plane**.

| Integration feature | **APIM AI gateway** (you build — Parts 1–2) | **Foundry native AI Gateway** (Part 3) | **LiteLLM** — bring your own (Part 4) |
|---|---|---|---|
| **Models** — chat/completions & embeddings | ✅ Load balanced across regions via backend pool, circuit breaker, retry policy | ✅ Routed through attached APIM v2 with per-project token limits | ✅ Routed via `azure_ai/` provider; client-side router for LB/fallback |
| **Models** — auth to Foundry | ✅ APIM **managed identity** (no keys in policy) | ✅ Managed by the platform | ✅ **Entra ID** bearer token (no keys); API key also supported if local auth is on |
| **Tools** — function calling pass-through | ✅ Passed through to the model | ✅ Passed through to the model | ✅ `tools`/`tool_choice` pass-through; returns `tool_calls` |
| **Tools** — govern external MCP servers | ✅ Expose/govern MCP (e.g. Learn MCP) with policies | ✅ MCP/A2A tool governance via control plane | ❌ Not an MCP governance layer |
| **Tools** — execution host | ❌ Client executes the tool | ❌ Client/agent executes the tool | ❌ Client executes the tool |
| **Agents** — hosted agent runtime | ❌ Not an agent runtime (gateway only) | ✅ Integrates with **Foundry Agent Service** + custom agent registration | ❌ Not an agent runtime |
| **Agents** — as a model backend for frameworks | ✅ OpenAI-compatible endpoint (OpenAI Agents SDK + Microsoft Agent Framework) | ✅ Via Foundry projects | ✅ OpenAI-compatible endpoint (OpenAI Agents SDK + Microsoft Agent Framework; Semantic Kernel/LangChain) |
| **Agents** — backend for **Foundry Agent Service** (BYO gateway connection) | ✅ **`ApiManagement`** connection — validated (Part 5) | ✅ Native (Agent Service) | ✅ **`ModelGateway`** connection — **prompt agents only**, validated (Part 5) |
| **Agent tools** through a BYO-gateway model | ✅ Foundry runs the tools | ✅ Foundry runs the tools | ✅ Code Interpreter, Functions, File Search, OpenAPI, Foundry IQ, SharePoint, Fabric, MCP, Browser Automation (run by Foundry) |
| **Foundry control plane** — registered/discoverable | ⚠️ Only when attached as the native AI Gateway | ✅ First-class: per-project quotas, custom agent registration, tool governance | ⚠️ Model is admin-connected (Foundry governs the connection); LiteLLM itself is **not** a governance plane |
| **Per-project token limits / quotas** | ⚠️ Custom policy | ✅ Built-in | ⚠️ Virtual-key budgets only |
| **Observability** | ✅ APIM metrics + GatewayLogs + LLM logging | ✅ Through attached APIM | ⚠️ LiteLLM logs / callbacks |
| **Portability across providers/clouds** | ⚠️ Azure-centric | ⚠️ Azure-only | ✅ Multi-provider |
| **Setup effort** | Medium (IaC) | Low (portal) | Low–medium (container) |

### Bottom line

- **Models + tools (function calling):** all three work. LiteLLM is fully capable as a **model + tool-passthrough gateway** and is the most portable — validated here with **models, tools, and an OpenAI Agents SDK agent** (Entra ID auth, no keys).
- **Agents:** only the **Foundry native AI Gateway** integrates with the **Foundry Agent Service** and agent/tool *governance*. That said, **Foundry Agent Service can use either gateway as a model backend** via a *bring-your-own* connection — APIM connections or a **Model Gateway** connection for LiteLLM/third-party gateways (validated in Part 5, **prompt agents only**). When an agent uses a BYO-gateway model, Foundry still runs its own **agent tools** (Code Interpreter, Functions, File Search, OpenAPI, Foundry IQ, SharePoint, Fabric, MCP, Browser Automation). APIM and LiteLLM are model backends, not agent runtimes.
- **Foundry control plane:** only **Azure API Management (v2)** can be registered as Foundry's *governance* AI Gateway. A third-party gateway like **LiteLLM cannot** be a governance plane — but its model *can* be attached to **Foundry Agent Service** as an **admin-connected** Model Gateway connection that **Foundry's** control plane manages (Part 5).

**Guidance:** Use **APIM** (built or native) when you need Foundry-native governance — per-project quotas, agent/tool governance, control-plane registration. Use **LiteLLM** when you want a portable, multi-provider model + function-calling gateway and don't need Foundry's control plane.

## References

- [Backend pool load balancing lab (AI-Gateway)](https://github.com/Azure-Samples/AI-Gateway/blob/main/labs/backend-pool-load-balancing/backend-pool-load-balancing.ipynb)
- [AI gateway capabilities in Azure API Management](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities)
- [Configure AI Gateway in your Foundry resources](https://learn.microsoft.com/azure/foundry/configuration/enable-ai-api-management-gateway-portal)
- [Bring your own model to Foundry Agent Service (Model Gateway connection)](https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway)
- [Expose an existing MCP server in APIM](https://learn.microsoft.com/azure/api-management/expose-existing-mcp-server)
- [Microsoft Learn MCP server](https://learn.microsoft.com/training/support/mcp)
- [LiteLLM — Azure AI provider](https://docs.litellm.ai/docs/providers/azure_ai)
