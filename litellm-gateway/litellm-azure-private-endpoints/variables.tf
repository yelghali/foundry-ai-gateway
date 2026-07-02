###############################################################################
#  LiteLLM on Azure (private endpoints) — from-scratch module that plugs into an
#  EXISTING network (subnets) and pre-created private DNS zones.
#
#  Deploy PUBLIC first (private_ingress = false) to test, then flip it to true
#  to lock it down (internal ingress + private endpoints + private DNS).
#
#  Every default below is an EXAMPLE (the original Miroki DEV env). A partner
#  overrides them all in a *.tfvars.json (subscription, RG, subnet IDs, and the
#  private_dns_zone_id_* values that point at THEIR shared DNS zones).
###############################################################################

variable "subscription_id" {
  description = "Target subscription (miroki-dev)."
  type        = string
  default     = "ed0c2c14-ba08-41b3-9cab-561f55ee40b4"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "francecentral"
}

variable "resource_group_name" {
  description = "EXISTING resource group to deploy into."
  type        = string
  default     = "rg-miroki-dev-frc-01"
}

variable "name_prefix" {
  description = "Short prefix for created resource names."
  type        = string
  default     = "litellm"
}

variable "name_suffix" {
  description = "Short suffix for globally-unique names (Key Vault, Foundry subdomains, etc.). Change if names collide."
  type        = string
  default     = "dev"
}

variable "tags" {
  type = map(string)
  default = {
    Environment = "DEV"
    Application = "Miroki"
    Workload    = "LiteLLM"
  }
}

###############################################################################
#  Networking model
#
#  Postgres, Foundries and Key Vault are ALWAYS PRIVATE (private endpoints in
#  snet-private-endpoints + private DNS). The ACA environment is ALWAYS
#  VNet-integrated (snet-appintegration) so it can reach them.
#
#  The only switch is the LiteLLM INGRESS:
#    private_ingress = false -> PUBLIC ingress (test the gateway from the internet)
#    private_ingress = true  -> INTERNAL ingress (VNet-private; activate its PE later)
###############################################################################

variable "private_ingress" {
  description = "false = PUBLIC LiteLLM ingress for testing (backends still private). true = INTERNAL ingress (VNet-private)."
  type        = bool
  default     = false
}

variable "manage_pe_dns" {
  description = "true = attach a private DNS zone group to each private endpoint (Terraform writes the A record into the platform zone). false = create the private endpoints WITHOUT a DNS zone group and let your landing-zone DNS policy (DINE) register the records."
  type        = bool
  default     = true
}

variable "key_vault_allowed_ip" {
  description = "Public IP allowed to reach the (otherwise private) Key Vault so THIS Terraform run can write the secrets. Leave \"\" to auto-detect the deployer's egress IP; set an explicit IP/CIDR if auto-detect is blocked; the app itself reads Key Vault over its private endpoint regardless."
  type        = string
  default     = ""
}

###############################################################################
#  EXISTING network (referenced by ID — not created here)
###############################################################################

variable "aca_infrastructure_subnet_id" {
  description = "EXISTING subnet for the Container Apps environment (delegated to Microsoft.App/environments). The env is always VNet-integrated here. Default: snet-appintegration."
  type        = string
  default     = "/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-network-dev-frc-01/providers/Microsoft.Network/virtualNetworks/vnet-miroki-dev-frc-01/subnets/snet-appintegration"
}

variable "private_endpoint_subnet_id" {
  description = "EXISTING subnet for the Foundry / Key Vault / PostgreSQL private endpoints. Default: snet-private-endpoints."
  type        = string
  default     = "/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-network-dev-frc-01/providers/Microsoft.Network/virtualNetworks/vnet-miroki-dev-frc-01/subnets/snet-private-endpoints"
}

###############################################################################
#  EXISTING shared private DNS zones (in the connectivity subscription)
###############################################################################

variable "private_dns_zone_id_postgres" {
  description = "privatelink.postgres.database.azure.com (for the Postgres private endpoint when private = true)."
  type        = string
  default     = "/subscriptions/a97f4651-d442-4661-8da7-1c5a60b32331/resourceGroups/rg-private-dns-zones-shd-frc-01/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
}

variable "private_dns_zone_id_aca" {
  description = "privatelink.francecentral.azurecontainerapps.io (needed to resolve the ACA env when private = true)."
  type        = string
  default     = "/subscriptions/a97f4651-d442-4661-8da7-1c5a60b32331/resourceGroups/rg-private-dns-zones-shd-frc-01/providers/Microsoft.Network/privateDnsZones/privatelink.francecentral.azurecontainerapps.io"
}

variable "private_dns_zone_id_openai" {
  description = "privatelink.openai.azure.com (for the Foundry private endpoints when private = true). Must exist in the shared DNS RG."
  type        = string
  default     = "/subscriptions/a97f4651-d442-4661-8da7-1c5a60b32331/resourceGroups/rg-private-dns-zones-shd-frc-01/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"
}

variable "private_dns_zone_id_cognitiveservices" {
  description = "privatelink.cognitiveservices.azure.com (for the Foundry private endpoints when private = true)."
  type        = string
  default     = "/subscriptions/a97f4651-d442-4661-8da7-1c5a60b32331/resourceGroups/rg-private-dns-zones-shd-frc-01/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com"
}

variable "private_dns_zone_id_services_ai" {
  description = "privatelink.services.ai.azure.com (required for the Azure AI Foundry (AIServices) private endpoints when private = true)."
  type        = string
  default     = "/subscriptions/a97f4651-d442-4661-8da7-1c5a60b32331/resourceGroups/rg-private-dns-zones-shd-frc-01/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com"
}

variable "private_dns_zone_id_vault" {
  description = "privatelink.vaultcore.azure.net (for the Key Vault private endpoint when private = true)."
  type        = string
  default     = "/subscriptions/a97f4651-d442-4661-8da7-1c5a60b32331/resourceGroups/rg-private-dns-zones-shd-frc-01/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
}

###############################################################################
#  Foundries + model
###############################################################################

variable "foundry_regions" {
  description = "Regions for the two Foundry accounts."
  type        = list(string)
  default     = ["francecentral", "swedencentral"]
}

variable "model_deployment_name" {
  type    = string
  default = "gpt-5.1"
}

variable "model_name" {
  type    = string
  default = "gpt-5.1"
}

variable "model_version" {
  type    = string
  default = "2025-11-13"
}

variable "model_sku_name" {
  description = "Deployment SKU (DataZoneStandard keeps traffic in the EU data zone)."
  type        = string
  default     = "DataZoneStandard"
}

variable "model_capacity" {
  description = "Per-deployment capacity in thousands of tokens/min (TPM). DataZoneStandard gpt-5.1 quota (~300) is shared across the whole EU data zone, so with two deployments the max is ~150 each (150 + 150 = 300). Request a quota increase, run a single deployment, or switch model_sku_name to GlobalStandard (up to ~1000) for more. Apply fails if the total exceeds the data-zone quota."
  type        = number
  default     = 150
}

variable "public_model_name" {
  type    = string
  default = "gpt-5.1"
}

variable "api_version" {
  description = "Azure OpenAI REST api-version LiteLLM uses (needs a recent one for gpt-5.x)."
  type        = string
  default     = "2025-04-01-preview"
}

variable "prefer_primary_region" {
  description = "true = weight the PRIMARY Foundry (FOUNDRY1 = the first foundry_regions entry, e.g. France Central) so it serves ~all traffic (keeps it warm → lower latency, no idle-region cold starts), while the secondary still auto-covers if the primary is cooled down by errors/timeouts/429s. There is still only ONE public model (public_model_name). false = load-balance (simple-shuffle) evenly across both regions."
  type        = bool
  default     = true
}

variable "primary_region_weight" {
  description = "How strongly to favour the primary Foundry when prefer_primary_region = true. It's the primary's load-balancer weight against 1 for the secondary (e.g. 99 ≈ ~99% of traffic to the primary). Ignored when prefer_primary_region = false."
  type        = number
  default     = 99
}

###############################################################################
#  PostgreSQL (created here, always private)
###############################################################################

variable "pg_admin_login" {
  type    = string
  default = "litellmadmin"
}

variable "pg_sku_name" {
  type    = string
  default = "GP_Standard_D2ds_v4"
}

variable "pg_storage_mb" {
  type    = number
  default = 32768
}

variable "pg_version" {
  type    = string
  default = "16"
}

variable "pg_database" {
  type    = string
  default = "litellm"
}

###############################################################################
#  LiteLLM
###############################################################################

variable "litellm_image" {
  type    = string
  default = "ghcr.io/berriai/litellm:main-stable"
}

variable "litellm_cpu" {
  type    = number
  default = 1.0
}

variable "litellm_memory" {
  type    = string
  default = "2Gi"
}

variable "litellm_target_port" {
  type    = number
  default = 4000
}

variable "litellm_min_replicas" {
  description = "Minimum LiteLLM replicas. Keep 1 for a single authoritative in-memory router (correct load balancing + 429 failover + cooldown across the two Foundry deployments, no Redis needed)."
  type        = number
  default     = 1
}

variable "litellm_max_replicas" {
  description = "Maximum LiteLLM replicas. Keep 1 (cost-effective, deterministic routing) unless you enable_redis. With enable_redis = true the replicas share cooldown/rate-limit state via the private Redis Container App, so you can safely scale to 3-4."
  type        = number
  default     = 1
}

###############################################################################
#  Redis (shared LiteLLM router cache for multi-replica load balancing)
###############################################################################

variable "enable_redis" {
  description = "Deploy a private Redis Container App and point LiteLLM's router at it so cooldown/rate-limit/usage state is SHARED across replicas. Enable this whenever litellm_max_replicas > 1."
  type        = bool
  default     = false
}

variable "redis_image" {
  type    = string
  default = "redis:7-alpine"
}

variable "redis_cpu" {
  type    = number
  default = 0.25
}

variable "redis_memory" {
  type    = string
  default = "0.5Gi"
}

variable "redis_maxmemory" {
  description = "Redis maxmemory (with allkeys-lru eviction) — this is just an ephemeral routing cache."
  type        = string
  default     = "256mb"
}

variable "store_model_in_db" {
  description = "false (recommended): the two Foundry gpt-5.1 deployments come from the mounted config file (IaC source of truth) and stay routable across restarts; PostgreSQL still persists all operational state (virtual keys, teams, users, budgets, spend/usage) so nothing is lost on restart. true: LiteLLM serves models ONLY from the DB and IGNORES the config model_list, so on a fresh DB /chat/completions returns 'no healthy deployments' until models are added via the Admin UI/API — only use it if you manage models at runtime through the UI and seed the DB yourself."
  type        = bool
  default     = false
}

variable "spend_logs_retention" {
  description = "Auto-purge window for the usage/spend logs LiteLLM writes to PostgreSQL (e.g. \"30d\", \"90d\"). \"\" = leave at LiteLLM's default (no auto-purge). Note: only request METADATA (model, tokens, cost, key/team, timestamp) is logged — NOT prompt/response content (content logging is opt-in via store_prompts_in_spend_logs)."
  type        = string
  default     = ""
}
