###############################################################################
#  SHARED private DNS zones for Private Link — run ONCE by the platform / DNS
#  team (typically in the connectivity subscription's shared DNS RG). All
#  workloads (this LiteLLM app and future ones) reuse these zones by ID, so no
#  app creates its own zone (a zone name can be linked to a VNet only once).
###############################################################################

variable "subscription_id" {
  description = "Subscription that owns the shared DNS resource group (usually connectivity/platform)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the shared private DNS zones."
  type        = string
  default     = "rg-private-dns-zones-shd-frc-01"
}

variable "create_resource_group" {
  description = "Create the resource group (true) or use an existing one (false)."
  type        = bool
  default     = false
}

variable "location" {
  description = "Region (used to build the region-specific Container Apps zone privatelink.<region>.azurecontainerapps.io)."
  type        = string
  default     = "francecentral"
}

variable "extra_zones" {
  description = "Private DNS zone names to create IN ADDITION to the defaults."
  type        = list(string)
  default     = []
}

variable "vnet_ids" {
  description = "VNet resource IDs to link every zone to (the spoke VNet(s) where the private endpoints live)."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = { Service = "DNS", ManagedBy = "Terraform" }
}

locals {
  # The full set this workload needs. Add more via extra_zones.
  # The three cognitiveservices/openai/services.ai zones are ALL required for an
  # Azure AI Foundry (kind = AIServices) account private endpoint (subresource
  # "account"), which exposes .openai.azure.com, .cognitiveservices.azure.com and
  # .services.ai.azure.com FQDNs.
  default_zones = [
    "privatelink.postgres.database.azure.com",           # PostgreSQL Flexible Server
    "privatelink.openai.azure.com",                      # Foundry / Azure OpenAI data plane
    "privatelink.cognitiveservices.azure.com",           # Foundry / Cognitive Services data plane
    "privatelink.services.ai.azure.com",                 # Foundry (AI Services) data plane
    "privatelink.vaultcore.azure.net",                   # Key Vault
    "privatelink.${var.location}.azurecontainerapps.io", # Container Apps (internal env)
  ]
  zones = toset(concat(local.default_zones, var.extra_zones))

  # One link per (zone, vnet).
  links = {
    for pair in setproduct(tolist(local.zones), var.vnet_ids) :
    "${pair[0]}|${pair[1]}" => { zone = pair[0], vnet = pair[1] }
  }
}

resource "azurerm_resource_group" "dns" {
  count    = var.create_resource_group ? 1 : 0
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_private_dns_zone" "z" {
  for_each            = local.zones
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags

  depends_on = [azurerm_resource_group.dns]
}

resource "azurerm_private_dns_zone_virtual_network_link" "l" {
  for_each              = local.links
  name                  = "link-${replace(each.value.zone, ".", "-")}-${substr(sha1(each.value.vnet), 0, 6)}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.z[each.value.zone].name
  virtual_network_id    = each.value.vnet
  registration_enabled  = false
  tags                  = var.tags
}

output "zone_ids" {
  description = "Map of zone name -> resource id (feed these into the app module's *_zone_id vars)."
  value       = { for k, z in azurerm_private_dns_zone.z : k => z.id }
}
