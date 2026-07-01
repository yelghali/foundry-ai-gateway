# LiteLLM on the Miroki DEV (ICM) environment — public quick‑test first

The pristine export of the **existing** infra lives in [`../existing code/ICM-DEV`](../existing%20code/ICM-DEV)
and is **never touched**. This folder references the bits it needs from that infra as **`data`
sources** and only **creates new** resources — so there is **no Terraform state to import and no
"already exists" conflict**.

## Do you get a conflict without TF state?

- **If existing resources were `resource` blocks** (as in the raw export) → **yes**: with no state,
  `apply` tries to *create* them and fails with *already exists* (you'd have to `terraform import`
  each one first).
- **What this folder does instead** → the existing identity / Postgres / Log Analytics are
  **`data` sources** ([data.tf](data.tf)). Terraform only **reads** them and **creates** the new
  resources below. No import, no conflict, existing infra untouched. (Full `terraform import` is
  still possible later if you want to *manage* the existing resources — see the bottom.)

## What gets created (all in the same subscription, RG, region)

| File | Creates |
| --- | --- |
| [R-Foundry.tf](R-Foundry.tf) | 2 × Azure OpenAI accounts + `gpt-4.1` (**DataZoneStandard**) in **France Central** + **Sweden Central**, the existing identity's **Cognitive Services User** role on each. `public_network_access_enabled = true` for now (so the public test app can reach them); private endpoints are wired but **off** (`enable_private_endpoints = false`). |
| [R-KeyVault.tf](R-KeyVault.tf) | Key Vault (RBAC) + `litellm-master-key` (always) + `litellm-salt-key` / `database-url` (only with DB), identity **Secrets User** + deployer **Secrets Officer** roles. |
| [R-ContainerAppEnvironment.tf](R-ContainerAppEnvironment.tf) | A **NEW public** Container Apps env (`internal_load_balancer_enabled = false`). VNet‑integrated **only** if you give it a dedicated infra subnet (needed for DB access). |
| [R-ContainerApp.tf](R-ContainerApp.tf) | A **NEW public** LiteLLM app on that env, using the **existing managed identity** (keyless to Foundry + KV), master key from KV, `STORE_MODEL_IN_DB=False`, ingress **4000**. |
| [R-PostgreSQLDatabase.tf](R-PostgreSQLDatabase.tf) | A `litellm` DB on the existing server — **only** when `test_app_use_database = true`. |

> This is a **throwaway public test** (env + app named `…-test-…`). Delete it after testing; it
> doesn't touch the existing private app.

## Quick public test (default — no VNet, no DB)

The fastest path: public Foundries + public LiteLLM, **master‑key auth only** (no virtual‑key
persistence, so no DB / VNet needed).

```powershell
terraform init
terraform apply    # uses the defaults below
```

Defaults for this mode: `foundry_public_access = true`, `enable_private_endpoints = false`,
`key_vault_public_access = true`, `test_app_use_database = false`.

Then hit it directly (it's **public**):

```bash
URL=$(terraform output -raw litellm_url)
KEY=$(terraform output -raw litellm_master_key)
curl "$URL/v1/chat/completions" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4.1","messages":[{"role":"user","content":"hi"}]}'
```

This validates: public endpoint, keyless MI auth to the two Foundries, and load balancing.

## Add DB persistence (virtual keys / budgets)

Set `test_app_use_database = true`. LiteLLM then needs to reach the **private** Postgres, so the
test env must be **VNet‑integrated** — provide a dedicated subnet delegated to
`Microsoft.App/environments` (a **second** ACA env can't reuse the existing env's
`snet-appintegration`):

```powershell
$env:TF_VAR_pg_admin_password = "<postgres admin password>"
terraform apply `
  -var="test_app_use_database=true" `
  -var="test_env_infra_subnet_id=/subscriptions/ed0c2c14-.../subnets/<dedicated-aca-subnet>"
```

## Iterate to private (later)

Flip `foundry_public_access = false` and `enable_private_endpoints = true`, set
`private_endpoint_subnet_id` + the DNS‑zone vars, and run the app on the **existing private** env
(or a VNet‑integrated internal env). See the variables for all toggles.

## If you'd rather MANAGE the existing resources (import)

The pristine `resource` blocks are in [`../existing code/ICM-DEV`](../existing%20code/ICM-DEV). To
manage them with Terraform, copy them back, then `terraform import` each (or use `import {}`
blocks) with its real resource id before `apply`. Not required for the quick test above.
