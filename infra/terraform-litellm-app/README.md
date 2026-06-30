# Deploy LiteLLM on existing infra (Terraform, app-only)

This Terraform module deploys **only the LiteLLM Container App** on top of infra that already exists (Foundries, PostgreSQL, Key Vault, ACA environment, managed identity + role assignments) — for example, infra a partner deployed with Terraform. It does **not** modify the partner's infra state.

It reads the infra's Terraform **outputs** via `terraform_remote_state` (default: the sibling [../terraform-litellm](../terraform-litellm) state). For real partner infra, point `infra_state_path` at their state file or switch the data source to their remote backend.

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

### Step 1 — choose how to read the infra references
- **Option A (have the infra state):** leave `infra_state_path` at its default (sibling
  `../terraform-litellm/terraform.tfstate`) or point it at the partner's state / remote backend.
- **Option B (no state):** set `infra_state_path = ""` and pass the values via `TF_VAR_*` env vars
  or a `*.tfvars` file (see [terraform.tfvars.example](terraform.tfvars.example) and the section below).

### Step 2 — deploy the app
```powershell
cd infra/terraform-litellm-app
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

### Option A — read the infra state (convenient)
Set `infra_state_path` to the infra state file (default: the sibling [../terraform-litellm](../terraform-litellm)). The module reads all references from its outputs automatically. Use this when you have access to the infra state.

For a **remote** backend (real partner setup), replace the `terraform_remote_state` data source in [main.tf](main.tf):

```hcl
data "terraform_remote_state" "infra" {
  count   = 1
  backend = "azurerm"
  config = {
    resource_group_name  = "partner-tfstate-rg"
    storage_account_name = "partnertfstate"
    container_name       = "tfstate"
    key                  = "litellm-infra.tfstate"
  }
}
```

### Option B — no state, pass values explicitly (env vars / tfvars)
Set `infra_state_path = ""` and provide the references directly — via a `*.tfvars` file or **`TF_VAR_*` environment variables**. Nothing about the partner's state is required.

```powershell
$env:TF_VAR_infra_state_path             = ""
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

