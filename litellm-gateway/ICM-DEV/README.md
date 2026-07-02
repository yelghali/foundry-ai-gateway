# LiteLLM on Miroki DEV — from-scratch Terraform (private backends, public→private ingress)

Creates the **full LiteLLM stack** in the existing subscription/RG and **plugs into the existing
network + shared private DNS zones**. **Postgres, Foundries and Key Vault are always PRIVATE**
(private endpoints); only the **LiteLLM ingress** flips from public (for testing) to internal.
Intended for a **fresh** deploy (delete the old app resources first).

## What it creates

- User-assigned **managed identity** (keyless)
- **2 × Azure OpenAI** Foundries + `gpt-5.1` (**DataZoneStandard**), France Central + Sweden Central,
  identity granted **Cognitive Services User** on each — **private** (public access off + private endpoint)
- **PostgreSQL Flexible Server** (**private**: public access off + private endpoint) + a `litellm` DB
- **Key Vault** (RBAC, **private**: selected-networks + private endpoint) + `litellm-master-key` /
  `litellm-salt-key` / `database-url`
- **Log Analytics** + **Container Apps environment** (**always VNet-integrated** on `snet-appintegration`)
- **LiteLLM Container App** (keyless MI, config mounted, `STORE_MODEL_IN_DB` configurable, port 4000)

> **This app never creates DNS zones.** All private DNS zones live in a **dedicated DNS resource
> group** owned by the platform/network team and deployed by the separate
> [`../private-dns-zones`](../private-dns-zones/) module. This app only **consumes zone IDs** via the
> `private_dns_zone_id_*` variables and (by default) writes its own PE A-records into them.

## Networking model

Everything the gateway depends on is **private and reached over the VNet**. The ACA environment is
**always VNet-integrated**, so even the public-ingress test talks to the private backends. The only
switch is `private_ingress`.

| Component | Networking |
|---|---|
| PostgreSQL | 🔒 always private (public access off + private endpoint in `snet-private-endpoints` + `privatelink.postgres`) |
| Foundries | 🔒 always private (public access off + private endpoints + `privatelink.openai`/`cognitiveservices`/`services.ai`) |
| Key Vault | 🔒 always private (selected-networks + private endpoint + `privatelink.vaultcore`) |
| ACA env | always VNet-integrated (`snet-appintegration`) |
| **LiteLLM ingress** | `private_ingress = false` → **public** (test) · `private_ingress = true` → **internal** |

**Key Vault + Terraform:** the vault denies by default, but this run **allow-lists the deployer's
egress IP** (auto-detected, or set `key_vault_allowed_ip`) so it can write the secrets. The app reads
them over the **private endpoint**. To go fully private later, run Terraform from inside the VNet.

## Private DNS zones (owned by the platform, in a dedicated RG)

The app requires **6 private DNS zones**, all pre-created in the **dedicated DNS resource group** by
the [`../private-dns-zones`](../private-dns-zones/) module and **linked to the spoke VNet**. Pass
their resource IDs into this app via the matching variables:

| Private DNS zone | For | Variable |
|---|---|---|
| `privatelink.openai.azure.com` | Foundry (LiteLLM `api_base`) | `private_dns_zone_id_openai` |
| `privatelink.cognitiveservices.azure.com` | Foundry (account endpoint) | `private_dns_zone_id_cognitiveservices` |
| `privatelink.services.ai.azure.com` | Foundry (AIServices) | `private_dns_zone_id_services_ai` |
| `privatelink.vaultcore.azure.net` | Key Vault | `private_dns_zone_id_vault` |
| `privatelink.postgres.database.azure.com` | PostgreSQL Flexible Server | `private_dns_zone_id_postgres` |
| `privatelink.francecentral.azurecontainerapps.io` | Container Apps env | `private_dns_zone_id_aca` |

> The three Foundry zones are all required because the account is kind **AIServices**: the PE
> `account` subresource registers records across `openai` + `cognitiveservices` + `services.ai`.

### How PE A-records get written into those zones — two mechanisms

1. **Via code (default, `manage_pe_dns = true`).** Each private endpoint gets a
   `private_dns_zone_group` and **Terraform writes the A-record** straight into the platform zone.
   Simple and self-contained; the deployer needs write access on the zones (or the zones' RG).
2. **Via Azure Policy (`manage_pe_dns = false`).** The PEs are created **without** a DNS zone group;
   a landing-zone **DINE policy** ("Deploy private DNS zone group for …") then registers the records
   asynchronously. Use this when the network team owns record registration and the app identity
   isn't granted write on the zones.

## Existing infra it references (defaults point at the real ones)

- Subnets in `vnet-miroki-dev-frc-01`: `snet-appintegration` (ACA env), `snet-private-endpoints`
  (all private endpoints).
- The **6 private DNS zones** above, pre-created by the platform in the dedicated DNS RG and linked
  to the VNet — consumed here by ID (this app creates none of them).

## Deploy — public ingress test (private backends)

```powershell
cd litellm-gateway\ICM-DEV
az login
terraform init
terraform apply           # private_ingress = false by default
```
Then hit it from the internet:
```powershell
$u = terraform output -raw litellm_url
$k = terraform output -raw litellm_master_key
curl "$u/v1/chat/completions" -H "Authorization: Bearer $k" -H "Content-Type: application/json" `
  -d '{\"model\":\"gpt-5.1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'
```

## Make the ingress private later

```powershell
terraform apply -var="private_ingress=true"
```
(Flipping the ACA env between external/internal recreates the env. Once internal, resolve the gateway
via `privatelink.francecentral.azurecontainerapps.io` from inside the VNet.)

## Prerequisites / gotchas

- `snet-appintegration` must be **free** (delete the old ACA env first) and delegated to
  `Microsoft.App/environments`.
- The deployer needs rights to **create role assignments** (Owner / User Access Administrator), and
  its egress IP must be able to reach Key Vault (or set `key_vault_allowed_ip`). With
  `manage_pe_dns = true` it also needs write access on the platform DNS zones' RG.
- The **6 private DNS zones must already exist** in the dedicated DNS RG (deploy
  [`../private-dns-zones`](../private-dns-zones/) first) and be linked to the VNet.
- Names use a random suffix; override `name_suffix` if a global name (KV / Foundry subdomain) collides.
- Image pulls from `ghcr.io` — push LiteLLM to an internal registry if egress is blocked.

## Logging, observability & data retention

- **Logging:** container stdout/stderr and ACA system logs ship to the **Log Analytics** workspace
  this module creates (30-day retention). **Application Insights is intentionally not included** —
  LiteLLM isn't auto-instrumented for it, so it adds cost for little value here. Add it later only if
  you wire LiteLLM's OpenTelemetry callbacks.
- **Conversations are NOT stored by default.** LiteLLM does **not** persist prompt/response *content*.
  It writes only **usage metadata** to the `LiteLLM_SpendLogs` table in PostgreSQL — model, token
  counts, cost, virtual-key/team, and timestamp — used for budgets and spend reporting.
- **Opt-in content logging:** storing actual prompts/responses requires explicitly enabling
  `store_prompts_in_spend_logs` — left **off** here for privacy. Don't enable it unless required.
- **Retention:** set `spend_logs_retention` (e.g. `"30d"`, `"90d"`) to auto-purge the SpendLogs after
  a window (maps to LiteLLM's `maximum_spend_logs_retention_period`). Default `""` = no auto-purge.
  To disable usage logging entirely, that's a separate LiteLLM setting (`disable_spend_logs`).
