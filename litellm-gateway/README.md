# LiteLLM AI Gateway on Azure (private endpoints)

A **standalone** deployment of a [LiteLLM](https://github.com/BerriAI/litellm) OpenAI‑compatible
gateway that **load balances across two Azure AI Foundry `gpt-5.1` deployments in two regions**,
backed by **Azure Database for PostgreSQL** (keys/budgets) and **Key Vault** (secrets), running on
**Azure Container Apps** with **keyless managed‑identity** auth — all **behind private endpoints**.

This folder is **independent of the rest of the lab** (the APIM / A2A / Foundry‑connection Bicep
parts under [../infra](../infra) and the samples under [../src](../src)). You can deploy, test, and
tear it down on its own.

## What you get

- LiteLLM gateway on Container Apps (OpenAI‑compatible `/v1/...`, port 4000). Ingress flips from
  **public** (for testing) to **internal** (`private_ingress = true`).
- **Load balancing** across two Foundry regions (router `simple-shuffle`, retries on 429/5xx),
  optional **Redis** for shared router state across replicas.
- **Keyless** auth to the Foundries via a user‑assigned managed identity (`Cognitive Services User`).
- **Virtual keys + budgets** persisted in PostgreSQL; **master key + DB URL** in Key Vault.
- **Private by default:** Foundries, Postgres and Key Vault are always reached over **private
  endpoints**; the ACA env is VNet‑integrated.

## Two modules

| Folder | Owned by | Creates |
| --- | --- | --- |
| [private-dns-zones](private-dns-zones) | **platform / network team** | The shared `privatelink.*` **private DNS zones** (Foundry × 3, Key Vault, Postgres, Container Apps) in a **dedicated DNS resource group**, linked to your spoke VNet. Run once; every workload reuses them by ID. |
| [litellm-azure-private-endpoints](litellm-azure-private-endpoints) | **app team** | The full LiteLLM stack — identity, 2× Foundry + `gpt-5.1`, Postgres, Key Vault, ACA env, the app + all private endpoints. **Consumes** existing subnets and the DNS zones **by ID** (never creates zones). |

Each has its own README with full steps:
- Shared DNS zones → [private-dns-zones/README.md](private-dns-zones/README.md)
- The LiteLLM stack (+ partner adoption guide) → [litellm-azure-private-endpoints/README.md](litellm-azure-private-endpoints/README.md)

> **Order:** deploy `private-dns-zones` first (or point at zones you already have), then feed the
> resulting zone IDs into `litellm-azure-private-endpoints` via its `private_dns_zone_id_*` variables.

## Quick start

```powershell
# 1) Platform: shared private DNS zones (once)
cd litellm-gateway/private-dns-zones
terraform init
terraform apply -var="subscription_id=<connectivity-sub>" `
  -var="resource_group_name=<dns-rg>" `
  -var='vnet_ids=["/subscriptions/.../virtualNetworks/<spoke-vnet>"]'

# 2) App: the LiteLLM stack (public ingress test, private backends)
cd ../litellm-azure-private-endpoints
terraform init
terraform apply -var-file="terraform.tfvars.json"     # supply your subnet + zone IDs
```
Then call it like OpenAI — `Authorization: Bearer <virtual-key>`, `model = gpt-5.1`.

## Key facts (verified)

- **Keyless** — managed identity is the auth path to the Foundries (`disableLocalAuth`).
- Keep `store_model_in_db = false` — `true` makes the router read its routable pool from the (empty)
  DB and report *"no healthy deployments"*. Virtual keys/budgets still persist (they only need `DATABASE_URL`).
- **No Azure Files / no disk.** Config is an ACA **Secret** mounted as a file; it survives restarts
  and new revisions. Keys/budgets live in PostgreSQL. Restart‑tested.
- **No conversation content stored** by default — only usage metadata in PostgreSQL (`LiteLLM_SpendLogs`);
  retention via `spend_logs_retention`.

## Cleanup

```powershell
cd litellm-gateway/litellm-azure-private-endpoints
terraform destroy -var-file="terraform.tfvars.json"
# then, if you own them, the shared DNS zones:
cd ../private-dns-zones
terraform destroy
```
