# APIM ❤️ Azure AI Foundry — Building an AI Gateway

> 🚀 **[Launch the workshop on MOAW](https://aka.ms/ws?src=gh:yelghali/foundry-ai-gateway/main/docs/)**

A hands-on **MOAW lab** showing five complementary ways to put an *AI gateway* in front of [Azure AI Foundry](https://learn.microsoft.com/azure/ai-foundry/):

1. **Azure API Management (APIM) as an AI gateway** — load balance one model across **two Foundry regions** with a backend pool, priority/weight routing, circuit breakers, and transparent 429 retries.
2. **MCP governance** — expose and govern the **Microsoft Learn MCP server** through APIM.
2b. **A2A governance** — expose and govern a **dummy A2A (Agent2Agent) agent** through APIM so one agent can call another *through* your gateway.
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
│   ├── a2a-agent.bicep              # A2A: dummy A2A agent on Container Apps + APIM passthrough API
│   ├── deploy-a2a.ps1               # A2A: deploy the dummy agent + APIM passthrough
│   ├── client-foundry-sc1.bicep     # Client: Scenario 1 consumer Foundry (custom APIM, key)
│   ├── client-foundry-sc2.bicep     # Client: Scenario 2 consumer Foundry (native APIM, MI + key fallback)
│   ├── client-foundry-sc3.bicep     # Client: Scenario 3 consumer Foundry (BYO LiteLLM, ModelGateway)
│   ├── deploy-client-foundry.ps1    # Client: deploy the three consumer Foundries on top of main + LiteLLM + A2A
│   └── cleanup.ps1          # tear down
└── src/
    ├── test/
    │   ├── test_load_balancing.py   # APIM: shows the region serving each request
    │   ├── test_burst.py            # APIM: concurrent burst that forces failover
    │   ├── sample_openai_apim.py    # APIM: OpenAI SDK (AzureOpenAI) client
    │   ├── agent_apim.py            # APIM: OpenAI Agents SDK agent + tool
    │   ├── agent_maf_apim.py        # APIM: Microsoft Agent Framework agent + tool
    │   ├── agent_mcp_apim.py        # APIM: agent + local tool + remote MS Learn MCP (proxied by APIM)
    │   ├── agent_a2a_apim.py        # APIM: agent + local tool + remote A2A specialist agent (proxied by APIM)
    │   ├── test_litellm_tools.py    # LiteLLM: models + tools (function calling)
    │   ├── sample_openai_litellm.py # LiteLLM: OpenAI SDK (OpenAI) client
    │   ├── agent_litellm.py         # LiteLLM: OpenAI Agents SDK agent + tool
    │   ├── agent_maf_litellm.py     # LiteLLM: Microsoft Agent Framework agent + tool
    │   ├── agent_mcp_litellm.py     # LiteLLM: agent + local tool + remote MS Learn MCP (proxied by LiteLLM)
    │   ├── agent_a2a_litellm.py     # LiteLLM: agent + local tool + remote A2A specialist agent (LiteLLM governs model + A2A)
    │   ├── register_a2a_agent.py    # registers the dummy agent in LiteLLM's DB-backed A2A gateway
    │   ├── agent_foundry_litellm.py # Part 5: Foundry agent via the LiteLLM (ModelGateway) connection
    │   ├── agent_foundry_apim.py    # Part 5: Foundry agent via the APIM connection
    │   ├── agent_foundry_native.py  # Part 5: native Foundry agent — model + MCP + A2A, no gateway
    │   ├── scenario_lib.py          # Part 6: shared helpers for the Foundry client scenarios
    │   ├── scenario0_local_apim.py  # Part 6 — Scenario 0 (local MAF agents, no Foundry, via APIM): model + tool + A2A
    │   ├── scenario1_custom_apim.py # Part 6 — Scenario 1 (custom/APIM, subscription key): model + tool + A2A
    │   ├── scenario2_aigateway_native.py   # Part 6 — Scenario 2 (AI Gateway native, MI + key fallback): model + tool + A2A
    │   ├── scenario3_aigateway_litellm.py  # Part 6 — Scenario 3 (AI Gateway LiteLLM): model + tool + A2A
    │   └── requirements.txt
    └── litellm/
        ├── config.yaml          # LiteLLM proxy config — Part 4 (static Entra ID token; mcp_servers block)
        ├── config.foundry.yaml  # LiteLLM proxy config — Part 5 (managed identity, auto-refresh; mcp_servers block)
        ├── docker-compose.yml
        └── .env.example
    └── a2a/
        └── dummy_agent.py       # A2A: stdlib-only dummy A2A agent (agent card + JSON-RPC message/send)
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
python ../src/test/agent_mcp_apim.py          # agent + local tool + remote MS Learn MCP, both THROUGH APIM

# 3b. (A2A) Govern a dummy A2A agent behind APIM
cd ../infra; ./deploy-a2a.ps1                  # dummy A2A agent on Container Apps + APIM passthrough
$env:A2A_URL_APIM = "<apimResourceGatewayURL>/dummy-a2a"
python ../src/test/agent_a2a_apim.py          # agent + local tool + remote A2A agent, both THROUGH APIM
$env:A2A_URL_DIRECT = "<a2aAgentDirectUrl>"
python ../src/test/agent_a2a_apim.py          # agent + local tool + remote A2A agent, both THROUGH APIM
# Govern the SAME A2A agent through LiteLLM (needs the Postgres-backed LiteLLM gateway from step 4b):
$env:LITELLM_BASE_URL = "<gatewayUrl>"; $env:LITELLM_MASTER_KEY = "sk-litellm-foundry-poc"
python ../src/test/register_a2a_agent.py       # register dummy-specialist in LiteLLM's A2A gateway
python ../src/test/agent_a2a_litellm.py        # agent + local tool + remote A2A agent, both THROUGH LiteLLM

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
> - **Remote MCP through the gateway** — `agent_mcp_apim.py` and `agent_mcp_litellm.py` each run one agent that combines a **local** Python tool with the **remote Microsoft Learn MCP** server reached *through the gateway* (APIM `learn-mcp` passthrough API; LiteLLM `mcp_servers`). Both answered *"Azure API Management is … (source: learn.microsoft.com)"* from MS Learn **and** converted *100 USD ≈ 92 EUR* with the local tool — proving the **same proxy + key govern both model and MCP-tool traffic**.
> - **Remote A2A agent through the gateway** — `agent_a2a_apim.py` runs an orchestrator agent that combines a **local** Python tool with a **remote A2A (Agent2Agent) "specialist" agent** reached *through APIM* (`dummy-a2a` passthrough API → a stdlib A2A agent on Container Apps). It quoted the specialist's advice **and** converted *100 USD ≈ 92 EUR* — proving the **same proxy + key govern model and agent-to-agent traffic**. `agent_a2a_litellm.py` ran the **same** agent fully through **LiteLLM** — after deploying a **PostgreSQL sidecar** (so `store_model_in_db` enables the A2A *Agent Gateway*) and registering the agent (`register_a2a_agent.py`), **both** the model call and the A2A `message/send` flowed through LiteLLM at `{litellm}/a2a/dummy-specialist` on one master key.
> - **LiteLLM *into* Foundry (Part 5)** — LiteLLM deployed to **Azure Container Apps** (managed identity, Entra ID auto-refresh) and registered as a Foundry **Model Gateway connection**. `GET /v1/models` → 200, `POST /v1/chat/completions` → 200, and a **Foundry Agent Service** prompt agent (`litellm-gateway/gpt-4o-mini`) replied end to end *through the gateway* — proving **Foundry Agent Service → connection → LiteLLM → Foundry**.
> - **Foundry agent calls an MCP tool *through* LiteLLM (Part 5)** — `agent_foundry_mcp_a2a_litellm.py` adds an **`MCPTool`** (`server_url = {litellm}/mcp/`) to the prompt agent, authenticated via a **Custom-keys project connection** (Foundry rejects inline `Authorization` headers — `invalid_payload`). The agent answered an **Azure API Management** question from **MS Learn through LiteLLM**, so the **same gateway + connection govern the model *and* the tool**. A2A from a Foundry-hosted agent is *not* reachable through LiteLLM with the **managed `A2APreviewTool`**: two early blockers were fixed (LiteLLM now advertises **https** cards via `FORWARDED_ALLOW_IPS=*`; the demo agent now reads **chunked** request bodies + replies with an A2A Message), but Foundry anchors A2A **card discovery at the host-root well-known URI** (`/.well-known/agent-card.json`, per RFC 8615 / the A2A spec). LiteLLM serves its card only under `/a2a/{agent}/...` (host-root → `404`), so discovery fails before any message is sent. Confirmed even with the dedicated **`RemoteA2A`** connection category whose `target` is the full `/a2a/{agent}` path → Foundry returns `400 Failed to fetch agent card: 404`. There is no connection-less form of the managed tool. A2A-through-LiteLLM works for **client-side orchestrators** instead (`agent_a2a_litellm.py`).
> - **Native Foundry agent — model + MCP + A2A, no gateway (Part 5)** — `agent_foundry_native.py` builds one prompt agent on a **native** `gpt-4o-mini` deployment that calls the **public MS Learn MCP** server *and* the **dummy A2A agent** directly (a `RemoteA2A` connection whose `target` is the agent's **host root**, which serves a spec-compliant card). It answered the **MCP** question *and* relayed the **A2A specialist's** advice in one turn — proving Foundry's managed A2A tool itself is fine; the LiteLLM block is purely its **path-scoped** card. Set **`KEEP_AGENT=1`** on any `agent_foundry_*.py` script to keep the agent visible in the portal (Build → Agents).
> - **APIM *into* Foundry (Part 5)** — the existing APIM instance registered as a Foundry **`ApiManagement`** connection (`provisioningState: Succeeded`, `target: .../inference/openai`, `deploymentInPath: true`). A **Foundry Agent Service** prompt agent (`apim-gateway/gpt-4o-mini`) replied end to end *through APIM* — proving **Foundry Agent Service → ApiManagement connection → APIM → Foundry (backend pool)**.
> - **Enterprise-vs-client topology — 4 consumer scenarios (Part 6)** — the consumer reaches the same three remote targets (an enterprise **model**, **MS Learn MCP**, a **remote A2A specialist**) four ways, each running **model → tool → A2A** with a PASS/FAIL summary. **Scenario 0 — local agents (no Foundry)** [`scenario0_local_apim.py`]: an in-memory **Microsoft Agent Framework** agent in the client process reaches everything through **APIM** passthrough APIs on one subscription key — **no Foundry account or connection** — all three legs **PASS** (model via `/inference`, MS Learn MCP via `/learn-mcp/mcp`, A2A via `/dummy-a2a`). **Scenarios 0 and 1 share the identical remote APIM infrastructure** — the only difference is *where the agent runs* (local app vs Foundry Agent Service). Scenarios 1–3 are Foundry-hosted, each on its **own dedicated client Foundry account** (`client-foundry-sc1/sc2/sc3.bicep`, projects `aigateway-sc1/sc2/sc3`, **no local enterprise models**; deployed together by `deploy-client-foundry.ps1`, agents persist in the portal by default): **Scenario 1 — custom (APIM), subscription key** [`scenario1_custom_apim.py`]: model ✅ (`apim-custom-key/gpt-4o-mini`, hand-authored `ApiManagement` + **subscription key**), tool ✅, A2A ✅; **Scenario 2 — AI Gateway native, managed identity + key fallback** [`scenario2_aigateway_native.py`]: **MI** model leg ⛔ *expected fail* (shared APIM lacks a `validate-azure-ad-token` policy → `Connection 'apim-gateway-mi' not found`) → **falls back** to ✅ key model leg (`apim-gateway/gpt-4o-mini`, `ApiManagement`), tool ✅, A2A ✅; **Scenario 3 — AI Gateway LiteLLM** [`scenario3_aigateway_litellm.py`]: model ✅ (`litellm-gateway/gpt-4o-mini`, `ModelGateway`), tool ✅, A2A ✅. Two honest findings on the Foundry scenarios: **(1)** Foundry serves a **model** only through `ApiManagement` / `ModelGateway` connections — a **`CustomKeys` connection cannot back a model** (`400 Category cannot be null`; custom keys are for **tool** auth instead), and a **managed-identity (`AAD`) `ApiManagement` connection** only resolves if APIM validates the project MI's Entra token (a `validate-azure-ad-token` inbound policy), which the shared enterprise APIM lacks — so Scenario 2 demonstrates the **MI-first → key-fallback** pattern; **(2)** the **managed A2A tool 500s when the calling agent's model is a gateway connection**, so every Foundry A2A leg is driven by **one small native `gpt-4o-mini` driver** the client account hosts (plain model calls and MCP work fine over gateway connections; Foundry-managed A2A through a path-scoped gateway is blocked by host-root card discovery, so Scenarios 1–3 reach the specialist directly — whereas Scenario 0's *client-orchestrated* A2A flows through APIM passthrough fine).

## Integration features comparison

The three gateway approaches differ most in **what they can govern**. The matrix below summarizes how each integrates with Foundry building blocks — **models**, **tools** (function calling / MCP), **agents**, and the **Foundry control plane**.

| Integration feature | **APIM AI gateway** (you build — Parts 1–2) | **Foundry native AI Gateway** (Part 3) | **LiteLLM** — bring your own (Part 4) |
|---|---|---|---|
| **Models** — chat/completions & embeddings | ✅ Load balanced across regions via backend pool, circuit breaker, retry policy | ✅ Routed through attached APIM v2 with per-project token limits | ✅ Routed via `azure_ai/` provider; client-side router for LB/fallback |
| **Models** — auth to Foundry | ✅ APIM **managed identity** (no keys in policy) | ✅ Managed by the platform | ✅ **Entra ID** bearer token (no keys); API key also supported if local auth is on |
| **Tools** — function calling pass-through | ✅ Passed through to the model | ✅ Passed through to the model | ✅ `tools`/`tool_choice` pass-through; returns `tool_calls` |
| **Tools** — govern external MCP servers | ✅ Expose/govern MCP (e.g. Learn MCP) with policies — `learn-mcp` passthrough API | ✅ MCP/A2A tool governance via control plane | ⚠️ Acts as an **MCP gateway** (`mcp_servers` aggregates/re-exposes MCP at `/mcp/`) — proxy + key auth, not full policy governance |
| **Agents** — govern A2A (agent-to-agent) traffic | ✅ Expose/govern an A2A agent with policies — `dummy-a2a` passthrough API | ✅ A2A tool/agent governance via control plane | ⚠️ Has a DB-backed **Agent Gateway (A2A)** (`/a2a/{agent}`) — not enabled in this file-config POC (no database) |
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
