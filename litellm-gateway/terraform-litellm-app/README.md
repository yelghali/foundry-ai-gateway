# Deploy LiteLLM on existing infra (Terraform, app-only)

This Terraform module deploys **only the LiteLLM Container App** on top of infra that already exists (Foundries, PostgreSQL, Key Vault, ACA environment, managed identity + role assignments) — for example, infra a partner deployed with Terraform. It does **not** modify the partner's infra state.

It reads the infra's Terraform **outputs** via `terraform_remote_state`. You pick where that state lives with **`infra_state_backend`**:

| `infra_state_backend` | reads from | extra input |
|---|---|---|
| `local` *(default)* | a state **file on disk** | `infra_state_path` |
| `azurerm` | **remote state** in an Azure Storage blob | `infra_state_config` map |
| `none` | **nothing** — you pass the infra references explicitly (tfvars / `TF_VAR_*`) | the explicit vars |

If you don't know whether the partner's state is local or in a blob: a **local** state is a `terraform.tfstate` file in their module folder; a **remote** state means their `terraform { backend "azurerm" {} }` points at a storage account + container + blob `key`. Ask them which, or just use `none` and have them hand you the output values.

## Auth — managed identity, no keys

LiteLLM authenticates to both Foundries with the infra's **user-assigned managed identity** (it already holds **Cognitive Services User** on each Foundry). The config sets `enable_azure_ad_token_refresh: true` and the container has `AZURE_CLIENT_ID`, so `DefaultAzureCredential` mints + refreshes Entra tokens automatically.

> Key-based auth is **not** used (and isn't available — the Foundries have `disableLocalAuth=true`). MI is the required path.

The LiteLLM **master key** and **PostgreSQL connection string** come from **Key Vault**, referenced by the container via the same managed identity.

## What it deploys

- One `azurerm_container_app` (`ca-litellm-…`) running `litellm`, ingress on 4000.
- Config delivered as a **mounted file** (`/etc/litellm/litellm-config`), `store_model_in_db: false` so the router serves the two config model backends (load balanced `simple-shuffle`).

## Deploy steps (clear procedure)

### Prerequisites
- Terraform >= 1.5, Azure CLI, `az login` to the same tenant/subscription as the infra.
- Permission to create a Container App in the infra's resource group.
- The existing infra must provide these references (the partner exposes them as Terraform
  outputs, or you paste the values): resource group, **ACA environment id**, **user-assigned
  managed identity** id + client id (with `Cognitive Services User` on both Foundries and
  `Key Vault Secrets User` on the vault), **Key Vault secret URIs** for the master key and the
  PostgreSQL connection string, the **two Foundry endpoints**, model deployment name, api version.

### Step 1 — choose how to read the infra references (set `infra_state_backend`)
- **Option A — LOCAL state file** (`infra_state_backend = "local"`, the default): leave
  `infra_state_path` at its default (sibling `../terraform-litellm/terraform.tfstate`) or point it
  at the partner's state file.
- **Option B — REMOTE state in an Azure blob** (`infra_state_backend = "azurerm"`): set
  `infra_state_config = { resource_group_name = "…", storage_account_name = "…", container_name = "…", key = "…" }`
  (add `use_azuread_auth = "true"` to authenticate with your Entra login instead of a storage key).
- **Option C — no state** (`infra_state_backend = "none"`): pass the values via `TF_VAR_*` env vars
  or a `*.tfvars` file (see [terraform.tfvars.example](terraform.tfvars.example) and the section below).

### Step 2 — deploy the app
```powershell
cd litellm-gateway/terraform-litellm-app
./deploy.ps1 -SubscriptionId <sub-id>     # terraform init + apply (app only)
# or plain:  terraform init; terraform apply -var="subscription_id=<sub-id>"
```

### Step 3 — verify
```powershell
./test.ps1                                # liveness + /v1/models + chat + load-balance burst
```

### Step 4 — (optional) budgeted user key
```powershell
./create-user-key.ps1 -Budget 50          # $50 gpt-4.1 virtual key — persists in PostgreSQL
```

### Restart resilience
Restarting the app (`az containerapp revision restart`) or the DB
(`az postgres flexible-server restart`) does **not** lose anything: config reloads from the
mounted ACA Secret, and keys/budgets persist in PostgreSQL. Re-running `terraform apply` is a
no-op when nothing changed.

## Using a virtual key (chat / completions / responses)

A **virtual key** (`sk-…`, minted by `create-user-key.ps1` or in the `/ui`) is used **exactly like
an OpenAI API key**: send it as `Authorization: Bearer <key>` to the gateway's OpenAI-compatible
endpoints. The key is *just auth + budget/limits* — it works on **every** route the proxy exposes,
and all calls count against the same budget. Use the **public** model name (`gpt-4.1`), never the
Azure deployment name. (The **master key** is for admin/UI only — don't use it for app traffic.)

> Set once: `BASE=https://ca-litellm-d1yxw3.happybay-fed2a986.eastus2.azurecontainerapps.io` and
> `KEY=sk-…` (your virtual key).

### Which endpoints work here

| Endpoint | Works with this deploy? | Note |
| --- | --- | --- |
| `POST /v1/chat/completions` | ✅ yes | the recommended path for `gpt-4.1` |
| `POST /v1/completions` (legacy text) | ✅ yes | LiteLLM adapts the chat model |
| `POST /v1/embeddings` | ⚠️ only if an embeddings model is in the config | none configured by default |
| `POST /v1/responses` | ❌ 404 today | Azure returns *Resource not found* with `api_version = 2024-10-21`; needs a newer preview api-version (see below) |

### Chat Completions — `/v1/chat/completions`
```bash
curl "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4.1","messages":[{"role":"user","content":"hi"}]}'
```
```python
from openai import OpenAI
client = OpenAI(base_url=f"{BASE}/v1", api_key=KEY)   # KEY = the virtual key
print(client.chat.completions.create(
    model="gpt-4.1",
    messages=[{"role": "user", "content": "hi"}],
).choices[0].message.content)
```

### Text Completions (legacy) — `/v1/completions`
```bash
curl "$BASE/v1/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4.1","prompt":"write a haiku about gpus","max_tokens":40}'
```
```python
print(client.completions.create(
    model="gpt-4.1", prompt="write a haiku about gpus", max_tokens=40,
).choices[0].text)
```

### Responses API — `/v1/responses`
The virtual key authenticates this route too, **but it currently returns `404 Resource not found`**
because the Azure Foundry call uses `api_version = 2024-10-21`, which doesn't expose `/responses`.
To enable it, set a preview api-version that supports the Responses API (e.g. `preview` /
`2025-03-01-preview`) — either bump `api_version` for the whole module, or add a second model entry
pinned to that version — then redeploy. Once enabled the call is:
```python
resp = client.responses.create(model="gpt-4.1", input="hi")
print(resp.output_text)
```
```bash
curl "$BASE/v1/responses" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4.1","input":"hi"}'
```

> Budgets apply across all of these: when the key's `$` budget is exhausted, every endpoint returns
> a budget error until you raise it. Spend is tracked per-key in PostgreSQL.

## Storage & persistence (answers the "is anything on disk / does config survive restarts?" question)

**There is NO Azure Files share and NO persistent disk.** Verified on the deployed app:

```
ACA environment storages (Azure Files) : []          # none
App volumes                            : [ { name: config, storageType: Secret } ]
App volume mounts                      : config -> /etc/litellm
```

So the storage model is:

| What | Where it lives | Survives app restart / new revision? | Survives DB restart? |
| --- | --- | --- | --- |
| **Model/router config** (2 Foundry backends + load balancing) | an **ACA Secret** (`litellm-config`) mounted as a file at `/etc/litellm/litellm-config` | ✅ yes | ✅ yes (not in DB) |
| **LiteLLM master key, DB connection string** | **Key Vault** (referenced by ACA via the managed identity) | ✅ yes | ✅ yes |
| **Virtual keys + spend/budgets** (e.g. the `$50` key) | **PostgreSQL** Flexible Server | ✅ yes | ✅ yes (managed storage) |

**Why config is persistent without any disk:** the config is part of the **Container App definition** (an ACA *Secret*, stored in the ACA control plane). Every container start — restart, scale event, or new revision — ACA re-mounts that secret as the file. There is nothing ephemeral to lose. This is verified: restarting both the Postgres server and the Container App, the gateway came back healthy and a key created *before* the restart still worked.

### Can the model config be stored in the DB instead?
**No — don't.** Setting `store_model_in_db: true` makes LiteLLM source its **routable** model pool from the DB; on a fresh DB the router then reports *"no healthy deployments"* and `/v1/models` is empty. The model config is therefore kept **in the file** (`store_model_in_db: false`). The DB is used **only** for keys/budgets, which is exactly what you want to persist there.

> To change the model config later, edit [litellm.config.yaml.tftpl](litellm.config.yaml.tftpl) and re-run `terraform apply` (or `deploy.ps1`). That updates the ACA Secret and rolls a new revision — the new config is then persistent again. Virtual keys in Postgres are unaffected.

## Do you need the infra Terraform state?

**No — the state is optional.** The module needs a handful of infra *references* (RG, ACA environment id, managed identity id + client id, two Key Vault secret URIs, the two Foundry endpoints, model + api version). You can supply these **either** way:

### Option A — read the infra state (LOCAL file)
`infra_state_backend = "local"` (default) + `infra_state_path` pointing at the infra state file
(default: the sibling [../terraform-litellm](../terraform-litellm)). The module reads all
references from its outputs automatically.

### Option B — read the infra state (REMOTE Azure blob)
`infra_state_backend = "azurerm"` + `infra_state_config` describing the state blob. No code edits
needed — it's all variables:

```hcl
infra_state_backend = "azurerm"
infra_state_config = {
  resource_group_name  = "partner-tfstate-rg"
  storage_account_name = "partnertfstate"
  container_name       = "tfstate"
  key                  = "litellm-infra.tfstate"
  # use_azuread_auth   = "true"   # auth with your Entra login instead of a storage account key
}
```

### Option C — no state, pass values explicitly (env vars / tfvars)
Set `infra_state_backend = "none"` and provide the references directly — via a `*.tfvars` file or
**`TF_VAR_*` environment variables**. Nothing about the partner's state is required.

```powershell
$env:TF_VAR_infra_state_backend          = "none"
$env:TF_VAR_resource_group_name          = "rg-litellm-gateway"
$env:TF_VAR_container_app_environment_id = "/subscriptions/.../managedEnvironments/cae-..."
$env:TF_VAR_identity_id                  = "/subscriptions/.../userAssignedIdentities/id-..."
$env:TF_VAR_identity_client_id           = "<client-guid>"
$env:TF_VAR_master_key_secret_uri        = "https://<kv>.vault.azure.net/secrets/litellm-master-key"
$env:TF_VAR_database_url_secret_uri      = "https://<kv>.vault.azure.net/secrets/database-url"
$env:TF_VAR_foundry_api_bases            = '["https://f1.openai.azure.com/","https://f2.openai.azure.com/"]'
$env:TF_VAR_model_deployment_name        = "gpt-4.1"
$env:TF_VAR_public_model_name            = "gpt-4.1"
terraform apply -var="subscription_id=<sub-id>"
```

See [terraform.tfvars.example](terraform.tfvars.example) for the full list. The partner just hands you those values (or exposes them as outputs); you never touch their state.

> **Tip — which one is the partner using?** A *local* state is a `terraform.tfstate` file in their
> module folder. A *remote* state is configured by a `backend "azurerm" { ... }` block in their
> Terraform (storage account + container + blob `key`); run `terraform state pull` in their dir, or
> check `.terraform/terraform.tfstate` for `"backend": { "type": "azurerm" }`. If unsure, use
> Option C.

## Bootstrap mode — minimal / virgin infra (only ACA env + Postgres + Key Vault)

Use this when **only the raw platform exists** and nothing else has been wired up — i.e. the infra
module was run with `vanilla = true`, or a partner handed you raw infra:

- ✅ exists: an ACA **managed environment**, a **PostgreSQL** Flexible Server, an **(empty) Key Vault**, and the **Foundry accounts** (with a model deployment).
- ❌ does **not** exist: managed identity, **no RBAC**, **no Key Vault secrets**.

Set `bootstrap = true` (and `infra_state_backend = "none"`). The module then creates everything missing in addition to the container app:

1. a **user-assigned managed identity** (`id-<name_prefix>-litellm`) — **the identity is owned by THIS (app) module**, not the infra,
2. role assignments: **Cognitive Services User** on each `foundry_account_ids` entry (keyless inference) + **Key Vault Secrets User** on the existing vault (so the app can read secrets),
3. a generated **master key** + the **`DATABASE_URL`** connection string, written as `litellm-master-key` / `database-url` secrets into the **existing** Key Vault (the apply grants itself **Key Vault Secrets Officer** + waits 30s for RBAC to propagate),
4. the **LiteLLM Container App**, using the new identity + KV-referenced secrets. A second **60s wait** (`time_sleep.app_rbac`) lets the Foundry + Key Vault role assignments propagate before the first revision starts, so it doesn't fail to resolve the KV-referenced secrets or get 401s from the Foundries.

> The LiteLLM **config stays an inline ACA Secret** (it carries no credentials — auth is keyless MI), so it is *not* moved into Key Vault.

> ✅ **Validated end-to-end:** infra was stripped to vanilla (identity + RBAC + secrets removed), then this module in `bootstrap` mode recreated the identity, RBAC, and secrets and deployed the app — `/v1/models` returned `gpt-4.1` and chat succeeded across both Foundry backends.

Required inputs (see [terraform.tfvars.bootstrap.example](terraform.tfvars.bootstrap.example)):

```powershell
terraform init -upgrade
terraform apply `
  -var="subscription_id=<sub-id>" `
  -var="bootstrap=true" `
  -var="infra_state_backend=none" `
  -var="resource_group_name=rg-litellm" `
  -var="location=eastus2" `
  -var="container_app_environment_id=/subscriptions/.../managedEnvironments/<env>" `
  -var="key_vault_name=<existing-kv>" `
  -var="postgres_fqdn=<server>.postgres.database.azure.com" `
  -var="pg_admin_login=litellmadmin" `
  -var="pg_admin_password=<pg-pass>" `
  -var="pg_database=litellm" `
  -var='foundry_account_ids=["/subscriptions/.../accounts/<f1>","/subscriptions/.../accounts/<f2>"]' `
  -var='foundry_api_bases=["https://<f1>.openai.azure.com/","https://<f2>.openai.azure.com/"]' `
  -var="model_deployment_name=gpt-4.1" -var="public_model_name=gpt-4.1" -var="api_version=2024-10-21"
```

You (the deployer) need rights to **create role assignments** (Owner / User Access Administrator on the relevant scopes) and to write Key Vault secrets. After apply, `terraform output -raw litellm_url` + `terraform output -raw litellm_master_key` give you the URL and key to log into `/ui`.

> Bootstrap will **fail at apply** if the secrets (`litellm-master-key` / `database-url`) or the container app name already exist in the target Key Vault / environment — by design it expects a *clean* vault and a free app name. Point it at fresh infra (or remove the conflicting objects / pick a new `container_app_name`).

