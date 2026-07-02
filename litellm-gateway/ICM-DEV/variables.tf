###############################################################################
#  LiteLLM on Miroki DEV — from-scratch module that plugs into the EXISTING
#  network (subnets) and shared private DNS zones.
#
#  Deploy PUBLIC first (private = false) to test, then flip `private = true`
#  to lock it down (internal ingress + private endpoints + private DNS).
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
  default     = "icmdev"
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
  description = "true = attach a private DNS zone group to each private endpoint. false = create the private endpoints WITHOUT a DNS zone group and let your landing-zone DNS policy (DINE) register the records."
  type        = bool
  default     = true
}

variable "create_private_dns_zones" {
  description = "Create the private DNS zones the shared RG is MISSING (privatelink.openai.azure.com for the Foundries, privatelink.vaultcore.azure.net for Key Vault) in THIS resource group and link them to the VNet. The postgres + azurecontainerapps zones already exist and are reused by ID. Set false if you pre-create them (then set the *_openai / *_vault zone-id vars) or if your DNS policy handles PE records (also set manage_pe_dns=false)."
  type        = bool
  default     = true
}

variable "vnet_id" {
  description = "Resource ID of the VNet to link the created private DNS zones to."
  type        = string
  default     = "/subscriptions/ed0c2c14-ba08-41b3-9cab-561f55ee40b4/resourceGroups/rg-miroki-network-dev-frc-01/providers/Microsoft.Network/virtualNetworks/vnet-miroki-dev-frc-01"
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
  type    = number
  default = 50
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

variable "store_model_in_db" {
  description = "Persist the model config in the DB (editable in /ui). Keep false so the routable pool is driven by the config file (the two Foundry deployments). When true, LiteLLM serves models from the DB and the config-file deployments are not routable until added via the UI/API, which makes /chat/completions return 'no healthy deployments'."
  type        = bool
  default     = false
}
