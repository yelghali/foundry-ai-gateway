# LiteLLM AI Gateway on Azure (self-contained)

A **standalone** deployment of a [LiteLLM](https://github.com/BerriAI/litellm) OpenAI‑compatible
gateway that **load balances across two Azure AI Foundry `gpt-4.1` deployments in two regions**,
backed by **Azure Database for PostgreSQL** (keys/budgets) and **Key Vault** (secrets), running on
**Azure Container Apps** with **keyless managed‑identity** auth.

This folder is **independent of the rest of the lab** (the APIM / A2A / Foundry‑connection Bicep
parts under [../infra](../infra) and the samples under [../src](../src)). You can deploy, test, and
tear it down on its own.

## What you get

- LiteLLM gateway on Container Apps (public HTTPS, port 4000, OpenAI‑compatible `/v1/...`).
- **Load balancing** across two Foundry regions (router `simple-shuffle`, retries on 429/5xx).
- **Keyless** auth to the Foundries via a user‑assigned managed identity (`Cognitive Services User`)
  — required because the Foundries have `disableLocalAuth=true`.
- **Virtual keys + budgets** persisted in PostgreSQL; **master key + DB URL** in Key Vault.
- Optional **private networking** (VNet + Private Endpoints) to the Foundries.

## Two modules — pick one

| Folder | Use when | Creates |
| --- | --- | --- |
| [terraform-litellm](terraform-litellm) | You want the **whole stack from scratch** (Foundries + Postgres + Key Vault + ACA env + identity + the app). | Everything, in one apply. Set `deploy_litellm_app = true` to include the app, or `false` to leave infra‑only and run the app module separately. |
| [terraform-litellm-app](terraform-litellm-app) | The **platform already exists** and you only want to (re)deploy the **app**. Three flavours: read the infra **local** state, read **remote** (Azure blob) state, or pass values explicitly. Plus a **`bootstrap`** mode that wires up identity + RBAC + secrets on top of *minimal* infra (only ACA env + Postgres + empty Key Vault). | Just the LiteLLM Container App (and, in bootstrap, the identity/RBAC/secrets it needs). |

Each module has its own README with full steps:
- All‑in‑one infra + app → [terraform-litellm/README.md](terraform-litellm/README.md)
- App‑on‑existing‑infra (+ bootstrap) → [terraform-litellm-app/README.md](terraform-litellm-app/README.md)

> The app module reads the infra module's outputs from the **sibling** `../terraform-litellm`
> state by default, so keeping these two folders side by side here "just works".

## Quick start (whole stack)

```powershell
cd litellm-gateway/terraform-litellm
Copy-Item terraform.tfvars.example terraform.tfvars   # set subscription_id
./deploy.ps1 -SubscriptionId <sub-id>                 # terraform init + apply
./test.ps1                                            # liveness + /v1/models + chat + LB burst
./create-user-key.ps1 -Budget 50                      # optional $50 virtual key
```

## Using the gateway

Call it like OpenAI — `Authorization: Bearer <virtual-key>`, `model = gpt-4.1` (the public name).
`/v1/chat/completions` and `/v1/completions` work; `/v1/responses` needs a preview Azure
api‑version. See [terraform-litellm-app/README.md](terraform-litellm-app/README.md#using-a-virtual-key-chat--completions--responses)
for chat / completions / responses examples (curl + Python).

## Key facts (verified)

- **Keys are disabled by policy** (`disableLocalAuth=true`) → managed identity is the **only** auth path.
- Keep `store_model_in_db: false` — `true` makes the router read its routable pool from the (empty)
  DB and report *"no healthy deployments"*. Virtual keys/budgets still persist (they only need `DATABASE_URL`).
- **No Azure Files / no disk.** Config is an ACA **Secret** mounted as a file; it survives restarts
  and new revisions. Keys/budgets live in PostgreSQL. Restart‑tested.

## Cleanup

```powershell
cd litellm-gateway/terraform-litellm        # (or terraform-litellm-app for app-only)
terraform destroy -var="subscription_id=<sub-id>"
```
