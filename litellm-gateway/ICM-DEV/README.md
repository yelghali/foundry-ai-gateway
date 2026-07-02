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

## Networking model

Everything the gateway depends on is **private and reached over the VNet**. The ACA environment is
**always VNet-integrated**, so even the public-ingress test talks to the private backends. The only
switch is `private_ingress`.

| Component | Networking |
|---|---|
| PostgreSQL | 🔒 always private (public access off + private endpoint in `snet-private-endpoints` + `privatelink.postgres`) |
| Foundries | 🔒 always private (public access off + private endpoints + `privatelink.openai`/`cognitiveservices`) |
| Key Vault | 🔒 always private (selected-networks + private endpoint + `privatelink.vaultcore`) |
| ACA env | always VNet-integrated (`snet-appintegration`) |
| **LiteLLM ingress** | `private_ingress = false` → **public** (test) · `private_ingress = true` → **internal** |

**Key Vault + Terraform:** the vault denies by default, but this run **allow-lists the deployer's
egress IP** (auto-detected, or set `key_vault_allowed_ip`) so it can write the secrets. The app reads
them over the **private endpoint**. To go fully private later, run Terraform from inside the VNet.

**Private DNS:** the shared DNS RG only has `postgres` + `francecentral.azurecontainerapps.io`, so the
module **creates the two missing zones** — `privatelink.openai.azure.com` (Foundries) and
`privatelink.vaultcore.azure.net` (Key Vault) — in this RG and links them to the VNet
(`create_private_dns_zones = true`, default). Set it `false` if you pre-create them or a landing-zone
DNS policy (DINE) registers PE records (then also set `manage_pe_dns = false`).

## Existing infra it references (defaults point at the real ones)

- Subnets in `vnet-miroki-dev-frc-01`: `snet-appintegration` (ACA env), `snet-private-endpoints`
  (all private endpoints).
- Shared private DNS zones in `rg-private-dns-zones-shd-frc-01` (connectivity sub): `postgres` +
  `francecentral.azurecontainerapps.io` (reused by ID). The `openai` + `vaultcore` zones are
  **created by this module** and linked to the VNet (they don't exist in the shared RG).

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
- The deployer needs rights to **create role assignments** (Owner / User Access Administrator), to
  **create + link private DNS zones** to the VNet, and its egress IP must be able to reach Key Vault
  (or set `key_vault_allowed_ip`).
- Names use a random suffix; override `name_suffix` if a global name (KV / Foundry subdomain) collides.
- Image pulls from `ghcr.io` — push LiteLLM to an internal registry if egress is blocked.
