# Shared private DNS zones (platform / DNS team)

Creates the **private DNS zones for Private Link** that all workloads share, and links them to your
spoke VNet(s). Run this **once** (ideally by the platform/DNS team, in the connectivity subscription's
shared DNS RG). Every app — this LiteLLM gateway and future ones — then reuses these zones **by ID**.

## Why separate from the app?

A private DNS zone name (e.g. `privatelink.openai.azure.com`) can be linked to a given VNet **only
once**. If each app created and linked its own copy, they'd collide. Centralizing the zones (the
Azure Landing Zone pattern) avoids conflicts, prevents drift, and is reusable. Even better, pair it
with a **DINE Azure Policy** that auto-registers each private endpoint's DNS record — then apps don't
touch DNS at all.

## Zones created

`privatelink.postgres.database.azure.com`, `privatelink.openai.azure.com`,
`privatelink.cognitiveservices.azure.com`, `privatelink.vaultcore.azure.net`,
`privatelink.<region>.azurecontainerapps.io` (+ anything in `extra_zones`).

## Use

```powershell
terraform init
terraform apply `
  -var="subscription_id=<connectivity-sub>" `
  -var="resource_group_name=rg-private-dns-zones-shd-frc-01" `
  -var='vnet_ids=["/subscriptions/.../virtualNetworks/vnet-miroki-dev-frc-01"]'
# output `zone_ids` gives name -> id
```

## Wire the app to these zones

In [../ICM-DEV](../ICM-DEV) set:

```hcl
create_private_dns_zones = false                 # don't let the app create zones
manage_pe_dns            = true                   # attach zone groups by ID
private_dns_zone_id_openai = "<zone_ids output>"  # etc. for vault / postgres
```

…or, if a DINE policy registers PE DNS for you, set `manage_pe_dns = false` in the app and skip the
per-endpoint zone groups entirely.

> The customer already has `postgres` + `francecentral.azurecontainerapps.io`. To make this module the
> single source of truth, either `terraform import` those two existing zones first, or (as agreed)
> recreate the set from here.
