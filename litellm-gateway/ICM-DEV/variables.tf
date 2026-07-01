###############################################################################
#  Tunables for the LiteLLM additions to the existing Miroki DEV ICM env.
#  Everything defaults to the values discovered in the exported resources, so a
#  plain `terraform apply` targets the SAME subscription (miroki-dev,
#  ed0c2c14-ba08-41b3-9cab-561f55ee40b4) / RG (rg-miroki-dev-frc-01) / region
#  (francecentral) as the existing environment.
###############################################################################

variable "location" {
  description = "Azure region (same as the existing env)."
  type        = string
  default     = "francecentral"
}

variable "resource_group_name" {
  description = "Resource group to deploy the added resources into (reuse the existing app RG)."
  type        = string
  default     = "rg-miroki-dev-frc-01"
}

variable "tags" {
  description = "Tags applied to the added resources."
  type        = map(string)
  default = {
    Environment = "DEV"
    Application = "Miroki"
  }
}

# --- Managed identity + container app that already exist in the export --------
variable "identity_name" {
  description = "Name of the EXISTING user-assigned identity the container app uses."
  type        = string
  default     = "id-ca-icm-miroki-dev-frc-01"
}

variable "log_analytics_workspace_name" {
  description = "Name of the EXISTING Log Analytics workspace (used by the test Container Apps env)."
  type        = string
  default     = "log-icm-miroki-dev-frc-01"
}

variable "monitoring_resource_group_name" {
  description = "Resource group of the EXISTING Log Analytics workspace."
  type        = string
  default     = "rg-miroki-monitoring-dev-frc-01"
}

# --- Public TEST Container Apps env + app (throwaway; delete after testing) ----
variable "test_env_name" {
  description = "Name of the NEW public test Container Apps environment."
  type        = string
  default     = "cae-icmlitellm-test-frc-01"
}

variable "test_app_name" {
  description = "Name of the NEW public test LiteLLM container app."
  type        = string
  default     = "ca-icmlitellm-test-frc-01"
}

variable "test_env_infra_subnet_id" {
  description = "Optional: a DEDICATED subnet (delegated to Microsoft.App/environments) in vnet-miroki-dev-frc-01 to VNet-integrate the test env. Required ONLY if test_app_use_database = true (to reach the private Postgres). Leave \"\" for a fully public test with no VNet (Microsoft-managed)."
  type        = string
  default     = ""
}

variable "test_app_use_database" {
  description = "Wire DATABASE_URL so the test app persists virtual keys/budgets (and, with store_model_in_db, the model config) in the existing private Postgres. Requires test_env_infra_subnet_id (VNet integration) + TF_VAR_pg_admin_password. Default true = DB-backed."
  type        = bool
  default     = true
}

variable "store_model_in_db" {
  description = "Persist the LiteLLM model config in the DB (editable in /ui) instead of serving it only from the mounted file. Requires test_app_use_database = true. On a fresh DB the routable pool starts empty until the models are added via the UI/API (the config file seeds them)."
  type        = bool
  default     = true
}

# --- Foundry (Azure AI) backends to create + load balance ---------------------
variable "foundry_names" {
  description = "Names of the two Foundry (AIServices) accounts to create."
  type        = list(string)
  default     = ["aif-icm-litellm-01-dev-frc-01", "aif-icm-litellm-02-dev-sdc-01"]
}

variable "foundry_regions" {
  description = "Regions for the two Foundry accounts: France Central + Sweden Central (regional redundancy + LB). gpt-4.1 is deployed GlobalStandard so it serves from both."
  type        = list(string)
  default     = ["francecentral", "swedencentral"]
}

variable "foundry_public_access" {
  description = "Allow public network access to the Foundries. Set true for quick public testing (a public LiteLLM env can then reach them). The private endpoints still provide a private path. Set false to fully lock down."
  type        = bool
  default     = true
}

variable "model_deployment_name" {
  description = "Azure deployment name (callers use the public model name; LiteLLM maps to azure/<this>)."
  type        = string
  default     = "gpt-4.1"
}

variable "model_name" {
  description = "Azure OpenAI model."
  type        = string
  default     = "gpt-4.1"
}

variable "model_version" {
  description = "Model version."
  type        = string
  default     = "2025-04-14"
}

variable "model_sku_name" {
  description = "Deployment SKU. DataZoneStandard keeps traffic within the EU data zone (fits France Central + Sweden Central)."
  type        = string
  default     = "DataZoneStandard"
}

variable "model_capacity" {
  description = "Deployment capacity (K TPM)."
  type        = number
  default     = 50
}

variable "public_model_name" {
  description = "Model name callers pass to LiteLLM."
  type        = string
  default     = "gpt-4.1"
}

variable "api_version" {
  description = "Azure OpenAI API version LiteLLM uses."
  type        = string
  default     = "2024-10-21"
}

# --- Key Vault ----------------------------------------------------------------
variable "key_vault_name" {
  description = "Name of the Key Vault to create (holds the LiteLLM master key, salt key, and DB URL). Max 24 chars, globally unique."
  type        = string
  default     = "kv-icmlitellm-dev-frc01"
}

variable "key_vault_public_access" {
  description = "Allow public network access to the Key Vault. Keep true so this Terraform run (from outside the VNet) can write the secrets; the private endpoint still provides the private data path. Flip to false once you deploy from inside the network."
  type        = bool
  default     = true
}

# --- PostgreSQL (existing private Flexible Server) ----------------------------
variable "postgres_server_name" {
  description = "Name of the EXISTING PostgreSQL Flexible Server."
  type        = string
  default     = "psql-icm-miroki-dev-frc-01"
}

variable "postgres_fqdn" {
  description = "FQDN of the EXISTING PostgreSQL Flexible Server."
  type        = string
  default     = "psql-icm-miroki-dev-frc-01.postgres.database.azure.com"
}

variable "pg_admin_login" {
  description = "PostgreSQL admin login (from the existing server)."
  type        = string
  default     = "litellmuser"
}

variable "pg_admin_password" {
  description = "PostgreSQL admin password. Best supplied via TF_VAR_pg_admin_password rather than a file. If left empty, the value from the R-PostgreSQL.tf resource is used."
  type        = string
  default     = ""
  sensitive   = true
}

variable "pg_database" {
  description = "Database LiteLLM uses for keys/spend/budgets (a dedicated DB is created on the existing server)."
  type        = string
  default     = "litellm"
}

# --- LiteLLM container --------------------------------------------------------
variable "litellm_image" {
  description = "LiteLLM proxy image. Push it to the env's ACR (cricmmirokidevfrc01.azurecr.io) if egress to ghcr.io is blocked."
  type        = string
  default     = "ghcr.io/berriai/litellm:main-stable"
}

variable "litellm_target_port" {
  description = "Container port LiteLLM listens on."
  type        = number
  default     = 4000
}

# --- Private networking (private endpoints for Foundry + Key Vault) -----------
variable "enable_private_endpoints" {
  description = "Create private endpoints (+ DNS zone groups) for the Foundries and the Key Vault. OFF for the quick public test (foundries + KV reached over public endpoints); turn ON later to lock down."
  type        = bool
  default     = false
}

variable "private_endpoint_subnet_id" {
  description = "Resource ID of the subnet to place the private endpoints in (a non-delegated subnet in vnet-miroki-dev-frc-01). ADJUST to your real PE subnet."
  type        = string
  default     = "/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-network-dev-frc-01/providers/Microsoft.Network/virtualNetworks/vnet-miroki-dev-frc-01/subnets/snet-privateendpoints"
}

# Existing shared private DNS zones (same RG/subscription the Postgres zone lives in).
variable "private_dns_zone_id_openai" {
  description = "Resource ID of the privatelink.openai.azure.com private DNS zone."
  type        = string
  default     = "/subscriptions/a97f4651-d442-4661-8da7-1c5a60b32331/resourceGroups/rg-private-dns-zones-shd-frc-01/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"
}

variable "private_dns_zone_id_cognitiveservices" {
  description = "Resource ID of the privatelink.cognitiveservices.azure.com private DNS zone."
  type        = string
  default     = "/subscriptions/a97f4651-d442-4661-8da7-1c5a60b32331/resourceGroups/rg-private-dns-zones-shd-frc-01/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com"
}

variable "private_dns_zone_id_services_ai" {
  description = "Resource ID of the privatelink.services.ai.azure.com private DNS zone."
  type        = string
  default     = "/subscriptions/a97f4651-d442-4661-8da7-1c5a60b32331/resourceGroups/rg-private-dns-zones-shd-frc-01/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com"
}

variable "private_dns_zone_id_vault" {
  description = "Resource ID of the privatelink.vaultcore.azure.net private DNS zone."
  type        = string
  default     = "/subscriptions/a97f4651-d442-4661-8da7-1c5a60b32331/resourceGroups/rg-private-dns-zones-shd-frc-01/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
}
