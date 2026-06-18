---
published: false
type: workshop
title: APIM ❤️ Azure AI Foundry — Building an AI Gateway
short_title: Foundry  AI Gateway Lab
description: Build an AI gateway in front of Azure AI Foundry (APIM load balancing, MCP + A2A governance, native AI Gateway, and a bring-your-own LiteLLM gateway), then run four client scenarios that reach the same model, tool, and agent through it.
level: intermediate
authors:
  - Yassine El Ghali
contacts:
  - linkedin.com/in/yelghali
duration_minutes: 90
tags: azure, api management, ai foundry, ai gateway, openai, mcp, litellm, load balancing
sections_title:
  - Introduction
  - Prerequisites
  - Setup — build the gateways
  - Scenario 0 — Local app via APIM
  - Scenario 1 — Foundry agent via APIM (key)
  - Scenario 2 — Foundry agent via APIM (managed identity)
  - Scenario 3 — Foundry agent via LiteLLM
  - What works today
  - Clean up
---

# APIM ❤️ Azure AI Foundry — Building an AI Gateway

As organizations adopt generative AI, a single model endpoint quickly becomes a bottleneck for **resilience**, **cost control**, and **governance**. An *AI gateway* sits between your applications and your AI models to add load balancing, retries, token limits, observability, and policy enforcement — without changing client code.

The architecture below shows what you build: two **enterprise Foundry** accounts exposing `gpt-4o-mini` models, a remote **MCP** server, and remote **A2A** agents — all fronted by an **APIM AI Gateway**, with a bring-your-own **LiteLLM** gateway alongside it. Three client apps reach those targets through the gateways: a **local in-memory app**, a **Foundry agent on the native APIM AI Gateway**, and a **Foundry agent on LiteLLM**.

![Architecture: two enterprise Foundry accounts (models), a remote MCP server, and remote A2A agents sit behind an APIM AI Gateway and a LiteLLM gateway. Three client apps — a local in-memory MAF app, a Foundry agent on the native APIM gateway, and a Foundry agent on LiteLLM — reach those targets through the gateways.](assets/architecture.drawio.svg)

This lab is organized like its test suite: you **build the gateways once (Setup)**, then run **four client scenarios** that each reach the **same three targets** through a gateway and run them in order — **model → tool → A2A**:

- **model** — an enterprise `gpt-4o-mini` deployment, load balanced across two Foundry regions.
- **tool** — the public **Microsoft Learn MCP** server, governed by your gateway.
- **A2A** — a remote **Agent2Agent** "specialist" agent.

The only thing that changes between scenarios is **who calls** and **through which gateway** — not *what* is called. Here is what each scenario is and what passes today:

| Scenario | Client | Gateway / connection | model · tool · A2A |
| --- | --- | --- | --- |
| **0** | local **Microsoft Agent Framework** app (no Foundry) | APIM passthrough APIs + subscription key | ✅ · ✅ · ✅ |
| **1** | **Foundry agent** (Azure AI Projects SDK) | APIM `ApiManagement` connection + **key** | ✅ · ✅ · ✅ † |
| **2** | **Foundry agent** | APIM `ApiManagement` connection + **managed identity** | ✅ · ✅ · ✅ † |
| **3** | **Foundry agent** | **LiteLLM** `ModelGateway` connection + master key | ✅ · ✅ · ✅ † |

> **What works — and the one combination that doesn't.** The **model** and **MCP-tool** legs pass over the gateway in all four scenarios; the APIM **managed-identity** model leg (Scenario 2) works once APIM is configured to validate the project MI's Entra token, and **A2A discovery** works via a `RemoteA2A` host-root connection.
>
> **† Model-through-gateway *plus* the Foundry A2A tool fails today.** Foundry's managed A2A tool returns `500` when the **calling agent's model is a gateway connection** (`ApiManagement` / `ModelGateway`). So in Scenarios 1–3 the A2A leg still passes, but only because it is driven by a small **native `gpt-4o-mini`** model rather than the gateway model. Both caveats — with the supporting Microsoft Learn references — are detailed in [What works today](#what-works-today).

The **Setup** section builds the gateway capabilities the scenarios rely on: APIM load balancing across two regions, MCP and A2A governance through APIM, an optional native Foundry AI Gateway, and a bring-your-own LiteLLM gateway registered into Foundry. By the end you will understand the trade-offs between **Azure-native** and **third-party** gateways, and you will have run all four scenarios against working infrastructure.

---

# Prerequisites

To complete the hands-on parts you need:

- An **Azure subscription** with **Owner** (or **Contributor** + **Role Based Access Control Administrator**) on a resource group. The lab creates role assignments, so plain Contributor is not enough.
- **Azure CLI** installed and signed in: `az login`.
- **Python 3.10+** for the test/scenario scripts (`pip install -r src/test/requirements.txt`).
- *(LiteLLM setup only)* Python to run the LiteLLM proxy (`pip install "litellm[proxy]"`). Docker is optional.
- Quota for the **`gpt-4o-mini`** model (GlobalStandard) in **two regions** — this lab uses `eastus2` and `swedencentral`. Check the [model availability by region](https://learn.microsoft.com/azure/ai-services/openai/concepts/models).
- The **Foundry User** role on each client project (required for any connection-backed model/tool/A2A call).

> **Cost & SKU:** this lab deploys **Azure API Management Standard v2**. v2 tiers provision in minutes (versus ~40 min for classic tiers) and are **required** for the native Foundry AI Gateway integration. APIM and the Foundry deployments incur charges — run the [clean-up](#clean-up) when finished.

The lab assets are organized as:

```
foundry-ai-gateway/
├── infra/
│   ├── main.bicep              # APIM v2 + 2 Foundry regions + backend pool + inference API + learn-mcp passthrough
│   ├── policy.xml              # load-balancing + retry policy
│   ├── deploy.ps1              # Setup step 1: APIM load balancer + MCP passthrough
│   ├── a2a-agent.bicep         # dummy A2A agent on Container Apps + APIM passthrough
│   ├── deploy-a2a.ps1          # Setup step 2: deploy the A2A agent + passthrough
│   ├── litellm-foundry.bicep   # LiteLLM (+ Postgres sidecar) on Container Apps + ModelGateway connection
│   ├── deploy-litellm-foundry.ps1   # Setup step 3: deploy the LiteLLM gateway
│   ├── apim-foundry.bicep      # (optional) register APIM as an ApiManagement connection
│   ├── client-foundry-sc1.bicep     # Scenario 1 client account (custom APIM, key)
│   ├── client-foundry-sc2.bicep     # Scenario 2 client account (native APIM, MI + key)
│   ├── client-foundry-sc3.bicep     # Scenario 3 client account (BYO LiteLLM)
│   ├── deploy-client-foundry.ps1    # Setup step 4: deploy the three client accounts + connections
│   └── cleanup.ps1             # tear down
└── src/
    ├── test/
    │   ├── scenario_lib.py          # shared helpers for the Foundry scenarios (1–3)
    │   ├── scenario_config.py       # reads infra/scenario-outputs.json (written by deploy-client-foundry.ps1)
    │   ├── scenario0_local_apim.py  # Scenario 0 — local MAF agent via APIM (no Foundry)
    │   ├── scenario1_custom_apim.py # Scenario 1 — Foundry agent via APIM (custom, key)
    │   ├── scenario2_aigateway_native.py  # Scenario 2 — Foundry agent via APIM (native, MI)
    │   ├── scenario3_aigateway_litellm.py # Scenario 3 — Foundry agent via LiteLLM
    │   ├── test_load_balancing.py   # Setup verify: shows the region serving each request
    │   ├── test_burst.py            # Setup verify: concurrent burst that forces failover
    │   └── register_a2a_agent.py    # registers the dummy agent in LiteLLM's A2A gateway
    ├── a2a/dummy_agent.py      # stdlib-only dummy A2A agent
    └── litellm/                # config.yaml, config.foundry.yaml, docker-compose.yml, .env.example
```

---

# Setup — build the gateways

The four scenarios all reach the same model, MCP tool, and A2A agent. This section deploys everything they need, in order. Run the four deploy commands once; each prints the values the next step (and the scenario scripts) consume.

```powershell
cd infra
az login
az account set --subscription "<your-subscription-id>"

./deploy.ps1                                   # 1. APIM load balancer + MCP passthrough
./deploy-a2a.ps1                               # 2. dummy A2A agent + APIM passthrough
./deploy-litellm-foundry.ps1                   # 3. LiteLLM gateway (for Scenario 3)
./deploy-client-foundry.ps1 `
  -LitellmMasterKey "sk-litellm-foundry-poc" `
  -DummyA2aUrl "<a2aAgentDirectUrl from step 2>"   # 4. the three client Foundry accounts
```

Step 4 writes **`infra/scenario-outputs.json`** (endpoints, connection IDs, gateway URLs — no secrets), which the scenario scripts read automatically through [scenario_config.py](src/test/scenario_config.py). The sections below explain what each step builds.

## 1. APIM load balancer across two regions

[deploy.ps1](infra/deploy.ps1) deploys [main.bicep](infra/main.bicep): an **APIM Standard v2** instance, **two Foundry accounts** (`eastus2` + `swedencentral`) each with a `gpt-4o-mini` deployment, an APIM **backend pool**, an **inference API** (`/inference/openai`), and the **MS Learn MCP passthrough** API. It prints the **APIM gateway URL**, a **subscription key**, and the two Foundry endpoints.

![APIM Inference API in front of a backend pool that load-balances two Foundry regions (priority 1 East US 2, priority 2 Sweden Central) with retry on 429/503.](assets/part1-loadbalance.drawio.svg)

How it works (in [main.bicep](infra/main.bicep) + [policy.xml](infra/policy.xml)):

- **Backend pool** spreads traffic by `priority` (lower = higher) and `weight`; round-robin within equal priority/weight.
- **Circuit breaker** trips a backend for 1 minute after a 429, honoring `Retry-After`.
- **Retry policy** re-sends to the pool on 429/503 (`first-fast-retry`), so the caller never sees the throttle.
- **Managed-identity auth** — APIM calls Foundry with its system-assigned identity (**Cognitive Services User** role); no keys in policy.

> `modelsConfig.capacity` is set low (**8** = 8K tokens/min) so throttling and failover are easy to trigger. Raise it for real workloads.

**Verify (scripts).** APIM is a drop-in Azure OpenAI-compatible endpoint — real apps just use the OpenAI SDK; these scripts add a `requests` client only to read the `x-ms-region` header and *show* which region served each call:

```powershell
pip install -r ../src/test/requirements.txt
$env:APIM_GATEWAY_URL = "<apimResourceGatewayURL>"
$env:APIM_API_KEY     = "<subscription key>"

python ../src/test/test_load_balancing.py      # 20 spaced requests — routing + MI auth
$env:TOTAL = "60"; $env:CONCURRENCY = "15"
python ../src/test/test_burst.py               # concurrent burst — forces failover
```

> **Verified:** 60 concurrent requests returned **60 × HTTP 200** (zero visible 429s — the retry policy absorbed them), split **East US 2: 39 / Sweden Central: 21**: priority‑1 absorbed traffic until the 8K‑TPM cap, then the circuit breaker failed over to priority‑2.

**Test from the APIM portal (no code).** Open the APIM instance → **APIs → Inference API → Test → "Creates a completion for the chat message"**, then fill in:

| Field | Value |
| --- | --- |
| Template parameter `deployment-id` | `gpt-4o-mini` |
| Query parameter | **name** `api-version` (not `version`), **value** `2024-10-21` |
| Header | `Content-Type: application/json` |

Request body (Raw):

```json
{
  "messages": [
    { "role": "system", "content": "You are a concise assistant. Answer in one sentence." },
    { "role": "user", "content": "What does an AI gateway do?" }
  ],
  "max_tokens": 100,
  "temperature": 0.7
}
```

The Test console adds the `Ocp-Apim-Subscription-Key` for you; APIM injects the Foundry auth with its managed identity (no model key needed). The final URL is `…/inference/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-10-21`. **Send** returns `200` with `choices[0].message.content`, and the `x-ms-region` response header shows which region served the call.

## 2. Govern the MCP tool and A2A agent through APIM

Agents call **tools** (MCP) and **other agents** (A2A). In an enterprise you want both to flow **through your gateway** for auth, rate limiting, and tracing. Because MCP (streamable HTTP) and A2A (JSON-RPC 2.0 over HTTP) are just HTTP, APIM governs them with a simple **passthrough API** — no special feature required.

![An agent calls the Microsoft Learn MCP server through APIM over HTTP; APIM applies policies, governance, and tracing.](assets/part2-mcp.drawio.svg)

- **MCP** — `deploy.ps1` already created a `learn-mcp` passthrough API in front of `https://learn.microsoft.com/api/mcp`, exposed at `https://<apim>.azure-api.net/learn-mcp/mcp`. (Portal equivalent: **APIs → MCP Servers → Expose an existing MCP server**, then add `rate-limit-by-key` / `trace` policies. Use `forward-request buffer-response="false"` so the streaming transport isn't buffered.)
- **A2A** — [deploy-a2a.ps1](infra/deploy-a2a.ps1) deploys a tiny, dependency-free A2A agent ([src/a2a/dummy_agent.py](src/a2a/dummy_agent.py)) to **Azure Container Apps** (public HTTPS — APIM can't reach `localhost`) and wires a `dummy-a2a` passthrough API. It prints the agent's **direct URL** (used by `deploy-client-foundry.ps1 -DummyA2aUrl`) and its APIM URL.

> **Streaming gotcha:** if you enabled Application Insights at the **All APIs** scope, set **Frontend Response → payload bytes to log = 0** and never read `context.Response.Body` in MCP policies — buffering breaks the MCP transport.

## 3. Bring your own gateway (LiteLLM)

[deploy-litellm-foundry.ps1](infra/deploy-litellm-foundry.ps1) deploys [litellm-foundry.bicep](infra/litellm-foundry.bicep): the open-source **LiteLLM** proxy on **Container Apps** (managed identity → Entra ID auth, no keys), load balancing the same two Foundry regions, with a **Postgres sidecar** (enables LiteLLM's MCP + A2A gateways) and a **`ModelGateway` connection** registered on the Scenario 3 account. It prints the public gateway URL and the `<connection>/<model>` deployment name (`litellm-gateway/gpt-4o-mini`).

LiteLLM also re-exposes registered MCP servers at **`/mcp/`** (note the **trailing slash** — `/mcp` `307`-redirects and the MCP client won't follow it), so one proxy + key fronts model *and* MCP traffic. What a BYO gateway can do, validated:

| Capability | APIM (Setup 1–2) | LiteLLM (BYO) |
|---|---|---|
| Load balance / failover across regions | ✅ Backend pool + circuit breaker | ✅ Router + cooldown |
| Managed-identity auth to Foundry | ✅ | ⚠️ Entra ID token (client-managed) |
| Function-calling (tools) pass-through | ✅ | ✅ |
| Govern / proxy remote MCP servers | ✅ Passthrough API + policies | ⚠️ MCP gateway (`mcp_servers`, key auth) |
| Agent framework as a model backend | ✅ OpenAI-compatible | ✅ OpenAI-compatible |
| Per-project token limits / quotas | ✅ (native AI Gateway) | ⚠️ virtual-key budgets only |
| Registered in Foundry control plane | ✅ | ✅ as a `ModelGateway` connection |
| Multi-provider / portable | ⚠️ Azure-centric | ✅ |

> **Bottom line:** LiteLLM is a great **model + tool** gateway and is portable across providers. For **Foundry-native governance** (per-project quotas, control-plane registration), use **Azure API Management**. Both can be registered *into* Foundry as a connection — `ApiManagement` ([apim-foundry.bicep](infra/apim-foundry.bicep)) or `ModelGateway` — which is exactly how Scenarios 1–3 consume them.

> **(Optional) Foundry native AI Gateway.** Foundry also has a built-in, portal-driven gateway that attaches an APIM v2 instance to a Foundry resource for **per-project token limits** — **Operate → Admin console → AI Gateway → Add AI Gateway** (Create new, or Use existing Standard v2 APIM). It governs models, and (preview) MCP tools and registered agents. It's portal/control-plane driven (no Bicep), so this lab documents it; Setup 1–2 already prove the equivalent MCP + A2A through APIM. See [Configure AI Gateway](https://learn.microsoft.com/azure/foundry/configuration/enable-ai-api-management-gateway-portal).

## 4. The three client Foundry accounts

[deploy-client-foundry.ps1](infra/deploy-client-foundry.ps1) deploys **three independent client Foundry accounts**, one per gateway pattern, because the native AI Gateway integration is configured at the Foundry **resource** level — a separate account per pattern keeps each connection set small and clear:

| Account | Bicep | Connections it creates |
| --- | --- | --- |
| `client-foundry-sc1` | [client-foundry-sc1.bicep](infra/client-foundry-sc1.bicep) | `apim-custom-key` (`ApiManagement`, key) · `mslearn-mcp-apim` (`CustomKeys`) · `dummy-a2a-direct` (`RemoteA2A`) + a native driver model |
| `client-foundry-sc2` | [client-foundry-sc2.bicep](infra/client-foundry-sc2.bicep) | `apim-gateway-mi` (`ApiManagement`, ProjectManagedIdentity) · `apim-gateway` (`ApiManagement`, key) · `mslearn-mcp-apim` · `dummy-a2a-direct` + driver |
| `client-foundry-sc3` | [client-foundry-sc3.bicep](infra/client-foundry-sc3.bicep) | `litellm-gateway` (`ModelGateway`, key) · `mslearn-mcp-litellm` (`CustomKeys`) · `dummy-a2a-direct` + driver |

> **Where to see these in the portal:** the **model** connections are `ApiManagement` / `ModelGateway` category, so they appear under **Models + endpoints** (admin-connected deployments), *not* the generic **Connections** list. The **MCP tool** (`CustomKeys`) and **A2A** (`RemoteA2A`) connections appear under **Connections**. The agents each scenario creates appear under **Build → Agents** and persist by default (set `KEEP_AGENT=0` to clean up).

You're now ready to run the scenarios.

---

# Scenario 0 — Local app via APIM (Microsoft Agent Framework)

The baseline: a **client-orchestrated** agent. There is **no Foundry account and no connection** — an ordinary in-memory **Microsoft Agent Framework (MAF)** agent runs in your process and reaches all three targets straight through the **APIM passthrough APIs** on one subscription key. (Foundry SDK is not used here — this is the "plain app" comparison for Scenarios 1–3.)

**Setup.** Only the APIM gateway (Setup 1–2) is required — no client Foundry account. Provide the gateway URL and subscription key:

> **No Foundry connections here** — this scenario uses no `Microsoft.CognitiveServices/.../connections` resources. The MAF agent calls the APIM passthrough APIs directly with a subscription key; those APIs (`/inference`, `/learn-mcp/mcp`, `/dummy-a2a`) are defined on APIM in [infra/apim-foundry.bicep](infra/apim-foundry.bicep) and [infra/a2a-apim.bicep](infra/a2a-apim.bicep). The bicep connection resources start with Scenario 1.

**Run.**

```powershell
$env:APIM_GATEWAY_URL = "https://apim-xxxx.azure-api.net"
$env:APIM_API_KEY     = "<subscription key>"
python ../src/test/scenario0_local_apim.py
```

**Result** ([scenario0_local_apim.py](src/test/scenario0_local_apim.py)):

| Leg | How it reaches the target | Result |
| --- | --- | --- |
| model | MAF chat client → APIM `/inference` (load balanced) | ✅ PASS |
| tool | `MCPStreamableHTTPTool` → `{apim}/learn-mcp/mcp` | ✅ PASS |
| A2A | local function tool → A2A JSON-RPC `{apim}/dummy-a2a` | ✅ PASS |

---

# Scenario 1 — Foundry agent via APIM (subscription key)

The same APIM gateway as Scenario 0, but now the agent runs **inside Foundry's Agent Service** on the `client-foundry-sc1` account, using the **Azure AI Projects SDK** (`AIProjectClient` + `PromptAgentDefinition`). Each leg rides a **Foundry connection**:

- **model** — `apim-custom-key/gpt-4o-mini`: an `ApiManagement` connection carrying the APIM subscription **key**. Foundry builds the Azure-OpenAI path and authenticates with the key. *(A model must be backed by an `ApiManagement`/`ModelGateway` connection — a raw `CustomKeys` connection returns `400 Category cannot be null`.)*
- **tool** — an `MCPTool` pointed at the APIM Learn-MCP URL, authenticated by the `mslearn-mcp-apim` `CustomKeys` connection (`project_connection_id`), driven by a small native `gpt-4o-mini` model.
- **A2A** — an `A2APreviewTool` pointed at the dummy specialist's **host root** via the `dummy-a2a-direct` `RemoteA2A` connection, also driven by the native model.

**Connections (bicep)** — from [infra/client-foundry-sc1.bicep](infra/client-foundry-sc1.bicep):

```bicep
resource apimCustomKeyConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'apim-custom-key'                  // MODEL
  properties: {
    category: 'ApiManagement'             // a model must ride ApiManagement/ModelGateway
    target: apimGatewayUrl                 // {apim}/inference/openai
    authType: 'ApiKey'
    credentials: { key: apimSubscription.listSecrets().primaryKey }
    metadata: { models: modelsMetadata, deploymentInPath: 'true', inferenceAPIVersion: inferenceApiVersion }
  }
}

resource mcpApimConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'mslearn-mcp-apim'                 // TOOL — MS Learn MCP behind APIM
  properties: {
    category: 'CustomKeys'
    target: apimMcpUrl                      // {apim}/learn-mcp/mcp
    authType: 'CustomKeys'
    credentials: { keys: { 'api-key': apimSubscription.listSecrets().primaryKey } }
  }
}

resource a2aDirectConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'dummy-a2a-direct'                 // A2A — remote specialist (host-root card)
  properties: {
    category: 'RemoteA2A'
    target: dummyA2aUrl                     // serves /.well-known/agent-card.json
    authType: 'CustomKeys'
    credentials: { keys: { 'x-noop': 'none' } }   // discovery is anonymous; noop header
  }
}
```

**Setup.** Already deployed by `deploy-client-foundry.ps1` (Setup 4); endpoints and connection IDs are in `infra/scenario-outputs.json` (auto-loaded).

**Run.**

```powershell
python ../src/test/scenario1_custom_apim.py
```

**Result** ([scenario1_custom_apim.py](src/test/scenario1_custom_apim.py)):

| Leg | Connection | Result |
| --- | --- | --- |
| model | `apim-custom-key` (`ApiManagement`, key) | ✅ PASS |
| tool | `mslearn-mcp-apim` (`CustomKeys`) | ✅ PASS |
| A2A | `dummy-a2a-direct` (`RemoteA2A`, native driver) | ✅ PASS |

---

# Scenario 2 — Foundry agent via APIM (managed identity)

The same APIM gateway and `ApiManagement` category as Scenario 1, on the `client-foundry-sc2` account, but the model connection authenticates with the project's **managed identity** (`authType: ProjectManagedIdentity`, no stored key). This validates the **native AI Gateway** auth path: Foundry sends the project MI's Entra token, APIM validates it and calls the backend Foundry with APIM's own identity. A subscription-key connection (`apim-gateway`) remains as a fallback.

**Setup.** Already deployed by `deploy-client-foundry.ps1` — two model connections (`apim-gateway-mi` managed identity, `apim-gateway` key) plus the shared MCP + A2A connections. The MI leg targets a dedicated APIM API (`/inference-mi/openai`, no subscription key) whose inbound policy runs `validate-azure-ad-token` to accept the project MI's Entra token.

**How the managed-identity path is wired (steps).** To make a Foundry `ApiManagement` connection authenticate with the project's managed identity instead of a key, three things must line up:

1. **Expose an APIM API for inference without a subscription key.** Add an inference API (here `/inference-mi/openai`) and set `subscriptionRequired: false` so the caller authenticates with an Entra token rather than an APIM subscription key.
2. **Validate the caller's Entra token in the APIM inbound policy.** Add `validate-azure-ad-token` to the API's inbound policy, accepting the audience the Foundry project requests its token for (`https://cognitiveservices.azure.com`). APIM then forwards the request to the backend Foundry/Azure OpenAI using its **own** managed identity (`authentication-managed-identity` / `set-backend-service`), so no client key is ever stored.

   ```xml
   <validate-azure-ad-token tenant-id="{tenant-id}" header-name="Authorization"
       failed-validation-httpcode="401"
       failed-validation-error-message="Unauthorized: invalid or missing Entra token.">
     <audiences>
       <audience>https://cognitiveservices.azure.com</audience>
       <audience>https://cognitiveservices.azure.com/</audience>
     </audiences>
   </validate-azure-ad-token>
   ```
3. **Create a project-scoped `ProjectManagedIdentity` connection.** The connection must be **project-scoped** (`Microsoft.CognitiveServices/accounts/projects/connections`, `parent: project` — not account-scoped), with `authType: 'ProjectManagedIdentity'`, an explicit `audience` matching the policy, and empty `credentials: {}`. Foundry then sends the project MI's Entra token (for that audience) on every inference call. (An account-scoped connection or `authType: 'AAD'` without an `audience` is **not** resolved for inference and returns `400 — Connection '<name>' not found`.)

**Connections (bicep)** — from [infra/client-foundry-sc2.bicep](infra/client-foundry-sc2.bicep); the model has two connections (MI first, key fallback):

```bicep
resource apimModelMiConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project                          // PROJECT-scoped connection
  name: 'apim-gateway-mi'                  // MODEL (managed identity, tried first)
  properties: {
    category: 'ApiManagement'
    target: apimMiGatewayUrl                 // {apim}/inference-mi/openai (no subscription key)
    authType: 'ProjectManagedIdentity'       // no stored key — uses the project MI's Entra token
    audience: 'https://cognitiveservices.azure.com'  // token audience APIM validates
    credentials: {}
    metadata: { models: modelsMetadata, deploymentInPath: 'true', inferenceAPIVersion: inferenceApiVersion }
  }
}

resource apimModelConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'apim-gateway'                     // MODEL (subscription-key fallback)
  properties: {
    category: 'ApiManagement'
    target: apimGatewayUrl
    authType: 'ApiKey'
    credentials: { key: apimSubscription.listSecrets().primaryKey }
    metadata: { models: modelsMetadata, deploymentInPath: 'true', inferenceAPIVersion: inferenceApiVersion }
  }
}

// TOOL + A2A use the same `mslearn-mcp-apim` (CustomKeys) and `dummy-a2a-direct`
// (RemoteA2A) connections shown in Scenario 1.
```

**Run.**

```powershell
python ../src/test/scenario2_aigateway_native.py
```

**Result** ([scenario2_aigateway_native.py](src/test/scenario2_aigateway_native.py)):

| Leg | Connection (auth) | Result |
| --- | --- | --- |
| model (MI) | `apim-gateway-mi` (`ApiManagement`, ProjectManagedIdentity) | ✅ PASS |
| tool | `mslearn-mcp-apim` (`CustomKeys`) | ✅ PASS |
| A2A | `dummy-a2a-direct` (`RemoteA2A`, native driver) | ✅ PASS |

> The MI leg works because the connection is **project-scoped** with `authType: ProjectManagedIdentity` and an explicit `audience`, and APIM carries a `validate-azure-ad-token` inbound policy on the `/inference-mi/openai` API that accepts the project MI's Entra token (audience `https://cognitiveservices.azure.com`). APIM then calls the backend Foundry with its **own** managed identity. The subscription-key connection (`apim-gateway`) stays available as a fallback.

---

# Scenario 3 — Foundry agent via LiteLLM (bring your own)

Same Foundry agent shape as Scenario 2, on the `client-foundry-sc3` account, but the gateway is the self-hosted **LiteLLM** proxy registered as a **`ModelGateway`** connection (master key). The model **and** the MCP tool both ride LiteLLM; A2A uses the direct `RemoteA2A` connection (LiteLLM serves its agent card under a path, not the host root Foundry requires for the managed A2A tool — see [What works today](#what-works-today)).

**Setup.** Already deployed by `deploy-litellm-foundry.ps1` (Setup 3) + `deploy-client-foundry.ps1` (Setup 4).

**Connections (bicep)** — from [infra/client-foundry-sc3.bicep](infra/client-foundry-sc3.bicep):

```bicep
resource litellmModelConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'litellm-gateway'                  // MODEL — self-hosted LiteLLM proxy
  properties: {
    category: 'ModelGateway'
    target: litellmBaseUrl                  // the LiteLLM base URL
    authType: 'ApiKey'
    credentials: { key: litellmMasterKey }
    metadata: { models: modelsMetadata, deploymentInPath: 'false', authConfig: litellmAuthConfig }
  }
}

resource mcpLitellmConnection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: 'mslearn-mcp-litellm'              // TOOL — MS Learn MCP behind LiteLLM
  properties: {
    category: 'CustomKeys'
    target: '${litellmBaseUrl}/${litellmMcpPath}'   // {litellm}/mcp/
    authType: 'CustomKeys'
    credentials: { keys: { Authorization: 'Bearer ${litellmMasterKey}' } }
  }
}

// A2A uses the same `dummy-a2a-direct` (RemoteA2A, host-root card) connection as Scenarios 1-2.
```

**Run.**

```powershell
python ../src/test/scenario3_aigateway_litellm.py
```

**Result** ([scenario3_aigateway_litellm.py](src/test/scenario3_aigateway_litellm.py)):

| Leg | Connection | Result |
| --- | --- | --- |
| model | `litellm-gateway` (`ModelGateway`, key) | ✅ PASS |
| tool | `mslearn-mcp-litellm` (`CustomKeys`) | ✅ PASS |
| A2A | `dummy-a2a-direct` (`RemoteA2A`, native driver) | ✅ PASS |

---

# What works today

Every scenario runs **model → tool → A2A**. The **model** and **MCP-tool** legs pass over the gateway in all four scenarios. The **A2A** leg also passes everywhere — but in the three Foundry scenarios it is driven by a **native model**, not the gateway model, because the *gateway-model + managed-A2A-tool* combination fails today (the limitation called out below).

| Scenario | Model | Tool (MCP) | A2A (agent) |
| --- | --- | --- | --- |
| **0 — Local app via APIM** | ✅ | ✅ | ✅ A2A via APIM passthrough |
| **1 — Foundry agent via APIM (key)** | ✅ gateway | ✅ | ⚠️ native driver (gateway model ⛔) |
| **2 — Foundry agent via APIM (managed identity)** | ✅ gateway (MI + token policy) | ✅ | ⚠️ native driver (gateway model ⛔) |
| **3 — Foundry agent via LiteLLM (key)** | ✅ gateway | ✅ | ⚠️ native driver (gateway model ⛔) |

Legend: ✅ works · ⚠️ works via fallback / workaround · ⛔ not supported.

**Confirmed working (with the config noted):**

- **Model through the gateway** — key (Sc 1), managed identity (Sc 2), and BYO LiteLLM (Sc 3) all serve the model over the gateway connection.
- **APIM managed-identity model auth** — works **once APIM validates the project MI's Entra token** (`validate-azure-ad-token`, audience `https://cognitiveservices.azure.com`) on a no-subscription-key inference API; Scenario 2 ships exactly that.
- **A2A discovery** — Foundry resolves the agent card and calls the remote A2A agent through a `RemoteA2A` host-root connection (anonymous discovery, `.well-known/agent-card.json`).

**Not supported today (and the workaround used):**

- **A `CustomKeys` connection can't back a *model*.** Foundry serves models only through `ApiManagement` / `ModelGateway` connections (a `CustomKeys` model returns `400 — Category cannot be null`); `CustomKeys` is fine for **tool** auth. See [Bring your own model to Foundry Agent Service](https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway).
- **Managed-identity model auth needs an APIM-side token policy.** A `ProjectManagedIdentity` `ApiManagement` connection only resolves if APIM validates the project MI's Entra token (`validate-azure-ad-token`, audience `https://cognitiveservices.azure.com`). Scenario 2 provisions a dedicated `/inference-mi/openai` API carrying that policy, so the MI leg passes; the native AI Gateway configures the same policy automatically — the same principle as the *MCP behind a gateway* behavior in [the reference below](#mcp-tool--managed-identity-including-behind-a-gateway). See [Configure AI Gateway in your Foundry resources](https://learn.microsoft.com/azure/foundry/configuration/enable-ai-api-management-gateway-portal).
- **Model-through-gateway *plus* the managed A2A tool fails today.** Foundry's managed A2A tool returns `500` when the calling agent's model is an `ApiManagement` / `ModelGateway` connection (verified live for both the APIM and LiteLLM model connections), so every Foundry A2A leg (1 / 2 / 3) is driven by a small **native `gpt-4o-mini` driver** model; the model and MCP legs work fine over the gateway connections. The Microsoft Learn A2A tool docs describe the tool as sharing context between **Foundry-model-powered agents** and external endpoints — i.e. the *calling* agent is expected to run on a native Foundry model deployment, which is consistent with this preview behavior. No separate limitation note documents the `500` itself; treat it as a preview constraint. See [Connect to an A2A agent endpoint from Foundry Agent Service](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/agent-to-agent) and its [preview limitations](https://learn.microsoft.com/azure/foundry/agents/how-to/enable-agent-to-agent-endpoint#limitations).
- **A2A can't be routed *through* a path-scoped gateway.** Foundry resolves the A2A card at the connection target's **host root** `/.well-known/agent-card.json` (the A2A `.well-known` discovery contract), which the path-scoped routes of LiteLLM/APIM can't serve — so A2A is reached **directly** via a `RemoteA2A` connection to the agent's host root. The fix is a **host-root card** (a dedicated hostname, or an APIM/shim that rewrites the card `url`); see [Host root vs custom path](#a2a-agent2agent-tool) below and [Agent2Agent (A2A) authentication](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-to-agent-authentication).

The **Foundry User** role on the project is required for any connection-backed model / tool / A2A call (see [agent identity concepts](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity)).

**What you built:** an **APIM AI gateway** that load balances a Foundry model across regions (priority routing, circuit breakers, retries); **MCP and A2A governance** through APIM; a **bring-your-own LiteLLM** gateway registered into Foundry as a `ModelGateway` connection; and **four client scenarios** that consume the same model, tool, and agent through these gateways — contrasting a local app with Foundry agents over key, managed identity, and BYO connections.

## Reference — A2A and MCP tool behavior (per Microsoft docs)

This appendix describes how **Foundry Agent Service** handles **A2A** and **MCP** tools in a real implementation, independent of this lab's wiring. It is sourced from Microsoft Learn (links at the end), and backs the limitations called out above.

### Behavior summary

| Tool | Behavior | Supported? | Notes |
| --- | --- | --- | --- |
| **A2A** | Key-based auth (header) | ✅ | `Authorization: Bearer …` or `x-api-key: …`; attached to every request. |
| **A2A** | **Managed identity** (agent identity / project MI) | ✅ | Endpoint must accept the correct **audience** + identity needs role assignments. |
| **A2A** | OAuth identity passthrough (per-user) | ✅ | Preserves user context; consent on first use. |
| **A2A** | Unauthenticated access | ✅ | Only for public/network-protected endpoints. |
| **A2A** | Configurable agent card path (`AgentCardPath`) | ✅ | REST-API only; default `.well-known/agent-card.json`, Foundry-hosted = `agentCard/v1.0`. |
| **A2A** | Anonymous card on Foundry-hosted endpoint | ⛔ | All Foundry-hosted A2A URLs require Entra ID auth. |
| **A2A** | HTTP+JSON / gRPC transport (v1.0) | ⛔ | v1.0 is **JSONRPC-only**; only A2A v1.0 + v0.3 supported. |
| **A2A** | Non-text modality / streaming (SSE) | ⛔ | Text modality only; no streaming responses. |
| **MCP** | Key-based auth | ✅ | Credential stored in the project connection. |
| **MCP** | **Managed identity** (agent identity / project MI) | ✅ | Provide **Audience** (App ID URI); category `RemoteTool`, auth `AgenticIdentityToken`. |
| **MCP** | OAuth identity passthrough | ✅ | Per-user consent link on first use. |
| **MCP** | **Managed identity behind APIM** | ⚠️ | Works **only if** APIM validates the Entra token (`validate-azure-ad-token`, correct audience + MI client ID); otherwise falls back to key-based. |

Legend: ✅ supported · ⚠️ conditional · ⛔ not supported.

### A2A (Agent2Agent) tool

**Connection.** A Foundry agent calls a remote A2A agent through a project connection of category `RemoteA2A` that stores the endpoint URL, the authentication, and an optional **agent card path**.

**Discovery (agent card).**

- Foundry resolves the agent card from the connection **target** plus an **`AgentCardPath`** (connection metadata). The A2A default is `.well-known/agent-card.json`; Foundry-hosted agents instead serve theirs at `agentCard/v1.0`, so you set `AgentCardPath` explicitly. Setting a custom card path is **REST-API only** — it isn't exposed in the Foundry portal.
- Registering an external A2A agent in the **Foundry control plane** returns a Foundry-generated **proxy URL**; Foundry discovers the card at `/.well-known/agent-card.json` and adds access control and monitoring through the AI gateway.
- For Foundry-hosted A2A endpoints, **all** A2A URLs (including the card) require **Microsoft Entra ID** auth — anonymous card access isn't supported — and the caller needs the **Foundry User** role on the project.

**Host root vs custom path (e.g. behind APIM).** You don't have to serve the card at the gateway **host root**. Because the card location is `target` + `AgentCardPath`, you can point the connection `target` at an APIM **sub-path** API (for example `https://gw.azure-api.net/agent-b`) and set `AgentCardPath` in the connection `metadata` to the relative card path. This lets **multiple A2A agents share one gateway** on different paths. The host root is only the default that applies when `AgentCardPath` is left unset (the A2A client resolves `.well-known/agent-card.json` against the target's host).

![A2A card discovery: the agent fetches the card at target + AgentCardPath (host root or a custom path), then POSTs message/send to the URL the card advertises.](assets/a2a-card-path.drawio.svg)

**Authentication.** An A2A connection supports:

- **Key-based** — a header credential (e.g. `Authorization: Bearer <token>` or `x-api-key: <key>`); Agent Service attaches it to each request.
- **Microsoft Entra ID** — **agent identity** or **project managed identity**; Agent Service mints a token and includes it. Requires role assignments on the underlying service and the endpoint accepting the correct **audience**.
- **OAuth identity passthrough** — per-user sign-in/consent; preserves user context across calls.
- **Unauthenticated** — only for endpoints that are public or network-protected.

**Limitations (preview).** A2A **v1.0 and v0.3** only; for v1.0, **JSONRPC transport only** (no HTTP+JSON or gRPC); **text** modality only; **no streaming** (server-sent events).

### MCP tool — managed identity (including behind a gateway)

**Authentication methods.** MCP tools connect via a project connection and support **key-based**, **Microsoft Entra (managed identity)**, and **OAuth identity passthrough**.

**Managed identity.** For Entra auth you choose **Agent Identity** or **Project Managed Identity** and provide an **Audience** = the Application ID URI of the target service's Entra app registration. Agent Service requests a token scoped to that audience and passes it to the MCP endpoint (connection category `RemoteTool`, auth type `AgenticIdentityToken`). The identity needs the required **role assignments** on the underlying service.

**Behind a gateway (e.g. APIM).** Foundry **can** use managed identity to reach a remote MCP server fronted by APIM — **but only if the gateway validates the Entra token**. APIM must run a `validate-azure-ad-token` (or `validate-jwt`) inbound policy configured with the expected **audience** and accept the agent/project managed identity's **application (client) ID**. If the gateway doesn't validate the token (or only checks a subscription key), the managed-identity token is ignored and you fall back to key-based auth — the same principle that governs managed-identity **model** auth.

**Troubleshooting (Entra).** `401` = wrong/unaccepted audience, or the endpoint doesn't accept Entra tokens; `403` = the identity is missing role assignments (changes take up to ~10 minutes to propagate).

### APIM as the front door for LiteLLM (Entra ID in, key out)

You can put **APIM in front of LiteLLM** so callers authenticate with **Microsoft Entra ID** while the **LiteLLM master key stays server-side**. APIM validates the inbound token (`validate-azure-ad-token`) and injects the LiteLLM key on the backend call (`set-header Authorization: Bearer sk-…`). This is the **recommended enterprise pattern**: centralized auth, hidden secrets, throttling, and observability — clients never see the LiteLLM key.

![APIM fronts LiteLLM: Foundry's managed identity presents an Entra ID token; APIM validates it and injects the LiteLLM master key before forwarding to the LiteLLM gateway.](assets/apim-front-litellm.drawio.svg)

**Works for all three target types:**

- **Models** — a `ModelGateway` / `ApiManagement` connection with managed identity (audience `https://cognitiveservices.azure.com/`). APIM validates the token, then calls LiteLLM's OpenAI-compatible route with the key. (This is essentially what the native AI Gateway configures for you.)
- **MCP tools** — a `RemoteTool` connection with `AgenticIdentityToken` + **audience**. APIM validates, injects the key, and forwards to LiteLLM's `/mcp/`.
- **A2A agents** — a `RemoteA2A` connection with `ProjectManagedIdentity` / `AgenticIdentityToken` + **audience**, plus a custom `AgentCardPath` pointing at the APIM A2A path. APIM validates the token and injects the key to LiteLLM's `/a2a/…`.

**Advice / caveats.**

- ✅ **Recommended for models and MCP tools** — it's the standard secret-hiding gateway pattern and is fully additive (new APIM APIs + connections).
- ⚠️ APIM must validate the token with the **correct audience** and accept the managed identity's **application (client) ID**; otherwise the token is ignored and you fall back to key-based.
- ⚠️ **A2A discovery caveat** — confirm whether the **card fetch** carries the MI token. If the card path is Entra-protected but discovery is unauthenticated, keep the **card path anonymous** and protect only the **message endpoint**. Using a custom `AgentCardPath` also means a second A2A agent no longer collides with an existing host-root card on the same gateway.

### Project connections vs. the AI Gateway tab

Both approaches put **APIM in front of Foundry**; they differ in **who configures the gateway**. This lab uses **project connections** (the manual / bring-your-own path) against an APIM it deploys itself — it does **not** use the native **AI Gateway** tab.

![Two ways to front Foundry with APIM: per-project connections that you wire and own, versus the resource-level AI Gateway tab that Foundry provisions and manages. Both reach an APIM that load-balances across two enterprise Foundry regions.](assets/connections-vs-aigateway.drawio.svg)

**How this lab is wired (confirming the architecture).** Three dedicated **client** Foundry accounts (`client-foundry-sc1/2/3`) hold **no enterprise models of their own**. Each reaches the **enterprise APIM**, which load-balances across **two enterprise Foundry accounts** — `foundry1` (East US 2, priority 1) and `foundry2` (Sweden Central, priority 2) — with circuit breakers:

- **sc1** — `apim-custom-key` (**ApiManagement**, subscription **key**) for the model; `mslearn-mcp-apim` (**CustomKeys**) for the tool; `dummy-a2a-direct` (**RemoteA2A**) for the agent.
- **sc2** — `apim-gateway-mi` (**ApiManagement**, **managed identity** / AAD) with `apim-gateway` (**ApiManagement**, key) fallback for the model; same MCP + A2A connections.
- **sc3** — `litellm-gateway` (**ModelGateway**) to the BYO LiteLLM gateway; same MCP + A2A connections.

| | Project connection (this lab) | AI Gateway tab (native) |
| --- | --- | --- |
| **Where configured** | Per **project**, in the project's connections | Per **Foundry resource**, in **Operate ▸ Admin console ▸ AI Gateway** |
| **Who configures APIM** | **You** — bring the gateway URL + auth and author the APIM policies | **Foundry** — creates (or attaches) the APIM and writes the policies |
| **How targets are wired** | One `ApiManagement` / `CustomKeys` / `ModelGateway` / `RemoteA2A` connection per leg | Enroll a project with **Add project to gateway**; no per-leg wiring |
| **Managed-identity auth** | Works only if **your** APIM validates the token (`validate-azure-ad-token`) | Foundry configures MI token validation for you |
| **Governance** | Whatever you put in your APIM | Per-project **token limits / quotas**, model + MCP + A2A governance, telemetry in Foundry / App Insights |
| **Scope** | One connection = one project = one target | One gateway shared by all projects in the resource (**1 APIM ↔ 1 AI Gateway**) |

**Why the lab uses connections.** It needs explicit, per-scenario control (key vs managed identity vs BYO LiteLLM) over a **hand-rolled** APIM. To make Scenario 2's managed-identity model leg authenticate without a stored key, the lab adds — on a dedicated `/inference-mi/openai` API — the same `validate-azure-ad-token` policy that the **native AI Gateway would otherwise configure automatically**. With it, the `ProjectManagedIdentity` connection resolves and the MI leg passes; the `apim-gateway` key connection stays only as a fallback.

**Docs:**

- [Configure AI Gateway in your Foundry resources](https://learn.microsoft.com/azure/foundry/configuration/enable-ai-api-management-gateway-portal)
- [AI gateway in Microsoft Foundry (APIM)](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities#ai-gateway-in-microsoft-foundry-preview)
- [Bring your own model to Foundry Agent Service (Model Gateway / APIM connection)](https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway)
- [Govern MCP and A2A tools by using an AI gateway](https://learn.microsoft.com/azure/ai-foundry/agents/how-to/tools/governance)

- [Agent2Agent (A2A) authentication](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-to-agent-authentication)
- [Connect to an A2A agent endpoint from Foundry Agent Service](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/agent-to-agent)
- [Enable incoming A2A on a Foundry agent](https://learn.microsoft.com/azure/foundry/agents/how-to/enable-agent-to-agent-endpoint)
- [Set up authentication for MCP tools](https://learn.microsoft.com/azure/foundry/agents/how-to/mcp-authentication)
- [Agent identity concepts in Microsoft Foundry](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity)

---

# Clean up

Stop charges by deleting everything the lab created:

```powershell
cd infra
./cleanup.ps1
# or: az group delete --name lab-foundry-ai-gateway --yes --no-wait
```

`cleanup.ps1` (or deleting the resource group) removes the APIM instance, both Foundry regions, the Container Apps (A2A agent + LiteLLM), and the three client Foundry accounts. If you enabled the **native AI Gateway**, first **remove projects from the gateway** and **delete the AI Gateway** in the Foundry Admin console, then delete the APIM instance.

## References

- [Azure AI Projects client library for Python](https://learn.microsoft.com/python/api/overview/azure/ai-projects-readme)
- [Get started with Foundry SDKs and endpoints](https://learn.microsoft.com/azure/foundry/how-to/develop/sdk-overview?pivots=programming-language-python)
- [AI gateway capabilities in Azure API Management](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities)
- [Configure AI Gateway in your Foundry resources](https://learn.microsoft.com/azure/foundry/configuration/enable-ai-api-management-gateway-portal)
- [Bring your own model to Foundry Agent Service (Model Gateway connection)](https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway)
- [Expose an existing MCP server in APIM](https://learn.microsoft.com/azure/api-management/expose-existing-mcp-server)
- [Microsoft Learn MCP server](https://learn.microsoft.com/training/support/mcp)
- [LiteLLM — Azure AI provider](https://docs.litellm.ai/docs/providers/azure_ai)
