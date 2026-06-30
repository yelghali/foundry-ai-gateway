# LiteLLM AI Gateway on Azure Container Apps (Terraform)

Self-contained Terraform that stands up a **LiteLLM** gateway which load balances across **two Azure AI Foundry `gpt-4.1` deployments in two regions**, backed by a real **Azure Database for PostgreSQL Flexible Server** and **Key Vault**, with logs in **Log Analytics**. Optionally runs the Foundries **fully private (Private Endpoints)** so LiteLLM reaches them over a VNet — to simulate a locked-down environment.

This is the keyless, KV-backed, managed-Postgres counterpart to the repo's sidecar-Postgres Bicep deployment ([../litellm-foundry.bicep](../litellm-foundry.bicep)).

## What it creates

| Resource | Purpose |
| --- | --- |
| User-assigned managed identity | LiteLLM → Foundries (keyless) + Key Vault reads |
| 2 × Azure AI Foundry (`AIServices`) + `gpt-4.1` deployment | The two regional backends (optional — can reuse existing) |
| Azure Database for PostgreSQL Flexible Server | LiteLLM key/spend/budget store (`DATABASE_URL`) |
| Key Vault (RBAC) | Holds `litellm-master-key` and `database-url` |
| Log Analytics + Container Apps environment | Hosting + monitoring |
| LiteLLM Container App (public HTTPS, port 4000) | The OpenAI-compatible gateway |
| *(optional)* VNet + subnets + Private Endpoints + private DNS | Private path from LiteLLM to the Foundries |

**Auth model:** LiteLLM calls the Foundries with its managed identity (`Cognitive Services User`, Entra token auto-refresh — no API keys). The master key and Postgres connection string live in Key Vault and are surfaced to the container as Key Vault-referenced ACA secrets via the same identity.

## 1. Load balancing (simplest setup)

Load balancing is **config-driven** — no extra script needed. The config ([litellm.config.yaml.tftpl](litellm.config.yaml.tftpl)) lists the *same public model name twice*, once per regional backend, and the LiteLLM router spreads requests across them:

```yaml
model_list:
  - model_name: gpt-4.1            # FOUNDRY1 (region 1)
    litellm_params: { model: azure/gpt-4.1, api_base: os.environ/FOUNDRY1_API_BASE, ... }
  - model_name: gpt-4.1            # FOUNDRY2 (region 2)
    litellm_params: { model: azure/gpt-4.1, api_base: os.environ/FOUNDRY2_API_BASE, ... }

router_settings:
  routing_strategy: simple-shuffle   # simplest LB; alternatives: least-busy, latency-based, usage-based
  num_retries: 2
  cooldown_time: 30
```

Callers hit one endpoint with `model = gpt-4.1`; LiteLLM picks a backend per request and retries the other on 429/5xx.

## 2. Private endpoints (optional — "simulate other env")

**Yes — you can run both Foundries behind Private Endpoints in the LiteLLM/ACA VNet and have LiteLLM call them privately.** Set:

```hcl
enable_private_networking = true
```

This:
- creates a **VNet** with an ACA subnet (delegated to `Microsoft.App/environments`) and a private-endpoint subnet;
- **VNet-integrates** the Container Apps environment (egress flows through the VNet; ingress stays public so you can still test the gateway);
- sets `public_network_access_enabled = false` on both Foundries and gives each a **Private Endpoint** in the VNet;
- links the `privatelink.openai.azure.com`, `privatelink.cognitiveservices.azure.com`, and `privatelink.services.ai.azure.com` **private DNS zones** to the VNet.

LiteLLM keeps calling the same `https://<acct>.openai.azure.com/` URL — it now resolves to the **private IP** and traffic never leaves the VNet. Cross-region is fine: the PE for the Sweden Foundry lives in the VNet's region and connects to the resource in the other region.

> Postgres and Key Vault stay public (Postgres via the *Allow Azure services* rule; KV secrets resolved by the platform). For a fully private env, add private endpoints for those too.

## 3. Budgeted user key (gpt-4.1, $50)

After deploy, mint a **virtual key** that may only call `gpt-4.1` (load balanced behind) and carries a spend budget:

```powershell
./create-user-key.ps1                       # gpt-4.1, $50 / 30d  (defaults)
./create-user-key.ps1 -Budget 50 -Model gpt-4.1 -Alias team-a -BudgetDuration 30d
```

It calls LiteLLM's `POST /key/generate` with the master key and prints the new `sk-…` key. Budgets/spend are tracked in PostgreSQL (`store_model_in_db = true`); when the key exceeds `$50` LiteLLM rejects further calls.

## 4. Monitoring (Log Analytics)

The Container Apps environment streams stdout/stderr to the Log Analytics workspace. Tail it:

```powershell
./logs.ps1                  # last 30 min of LiteLLM logs
./logs.ps1 -Minutes 60 -Grep error
```

Or query directly (Logs blade / `az monitor log-analytics query`):

```kusto
ContainerAppConsoleLogs_CL
| where ContainerAppName_s startswith "ca-litellm"
| where TimeGenerated > ago(1h)
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

## Prerequisites

- Terraform >= 1.5, Azure CLI, and `az login` to the target tenant.
- A principal that can create resources **and assign roles** (Owner, or Contributor + User Access Administrator) — the deployer is granted `Key Vault Secrets Officer` to write secrets.
- Quota for `gpt-4.1` (GlobalStandard) in **both** regions.

## Deploy

```powershell
cd infra/terraform-litellm
Copy-Item terraform.tfvars.example terraform.tfvars   # edit subscription_id (+ enable_private_networking if wanted)
./deploy.ps1 -SubscriptionId <sub-id>                 # add -PlanOnly to preview
./test.ps1                                            # health + models + chat + LB burst
./create-user-key.ps1                                 # $50 gpt-4.1 virtual key
```

## Reuse existing Foundries

```hcl
create_foundries           = false
existing_foundry_api_bases = [
  "https://my-foundry-eastus2.openai.azure.com/",
  "https://my-foundry-sweden.openai.azure.com/",
]
```

Then grant the LiteLLM identity `Cognitive Services User` on each account (Terraform doesn't own them). Private endpoints are only created for Foundries this stack creates.

## Optional: register into Foundry Agent Service

Add a **Model Gateway** connection (`category: ModelGateway`, `authType: ApiKey`, key = master key, target = `litellm_url`). See the connection block in [../litellm-foundry.bicep](../litellm-foundry.bicep).

## Clean up

```powershell
terraform destroy -var="subscription_id=<sub-id>"
```

## Notes / hardening

- Postgres uses the `0.0.0.0` "allow Azure services" firewall rule. For production, use a private endpoint and remove public access.
- Single replica by default — raise `max_replicas` for real load.
- `purge_protection_enabled = false` on Key Vault is for easy teardown; enable it for production.
