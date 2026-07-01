# LiteLLM on Miroki DEV — from-scratch Terraform (public → private)

Creates the **full LiteLLM stack** in the existing subscription/RG and **plugs into the existing
network + shared private DNS zones**. Deploy **public** to test, then flip **one variable** to lock
it down. Intended for a **fresh** deploy (delete the old app resources first).

## What it creates

- User-assigned **managed identity** (keyless)
- **2 × Azure OpenAI** Foundries + `gpt-4.1` (**DataZoneStandard**), France Central + Sweden Central,
  identity granted **Cognitive Services User** on each
- **PostgreSQL Flexible Server** — *always private* (VNet-injected into `snet-database` + the
  `privatelink.postgres.database.azure.com` zone) + a `litellm` database
- **Key Vault** (RBAC) + `litellm-master-key` / `litellm-salt-key` / `database-url`
- **Log Analytics** + **Container Apps environment** (always VNet-integrated on `snet-appintegration`)
- **LiteLLM Container App** (keyless MI, config mounted, `STORE_MODEL_IN_DB` configurable, port 4000)

## The one switch: `private`

| | `private = false` (default, **test**) | `private = true` (**locked down**) |
|---|---|---|
| LiteLLM ingress | **public** | **internal** (VNet-private) |
| Foundries | public network access | private endpoints (`snet-private-endpoints`) + `privatelink.openai`/`cognitiveservices` |
| Key Vault | public (so this run can write secrets) | private endpoint (`privatelink.vaultcore`) — run Terraform **from inside the VNet** |
| PostgreSQL | **private always** (reached via the VNet-integrated env) | private always |
| ACA env | VNet-integrated, external LB | VNet-integrated, internal LB |

PostgreSQL is private in **both** modes because the ACA env is always VNet-integrated — so the
public test already exercises the real private DB.

## Existing infra it references (as IDs — defaults point at the real ones)

- Subnets in `vnet-miroki-dev-frc-01`: `snet-appintegration` (ACA env), `snet-database` (Postgres),
  `snet-private-endpoints` (PEs).
- Shared private DNS zones in `rg-private-dns-zones-shd-frc-01` (connectivity sub): `postgres`,
  `francecentral.azurecontainerapps.io` (given), plus `openai` / `cognitiveservices` / `vaultcore`
  (defaults — must exist for `private = true`).

## Deploy — public test

```powershell
cd litellm-gateway\ICM-DEV
az login
terraform init
terraform apply           # private = false by default
```
Then:
```powershell
$u = terraform output -raw litellm_url
$k = terraform output -raw litellm_master_key
curl "$u/v1/chat/completions" -H "Authorization: Bearer $k" -H "Content-Type: application/json" `
  -d '{\"model\":\"gpt-4.1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'
```

## Lock it down later

```powershell
terraform apply -var="private=true"
```
(Requires the `openai`/`cognitiveservices`/`vaultcore` private DNS zones to exist and be linked to
the VNet, and Terraform to run from inside the VNet so it can still write Key Vault secrets. Flipping
the ACA env between external/internal recreates the env.)

## Prerequisites / gotchas

- `snet-appintegration` must be **free** (delete the old ACA env first) and delegated to
  `Microsoft.App/environments`; `snet-database` delegated to `Microsoft.DBforPostgreSQL/flexibleServers`.
- The deployer needs rights to **create role assignments** (Owner / User Access Administrator) and to
  write the cross-subscription **private DNS** records (Postgres zone).
- Names use a random suffix; override `name_suffix` if a global name (KV / Foundry subdomain) collides.
- Image pulls from `ghcr.io` — push LiteLLM to an internal registry if egress is blocked.
