###############################################################################
#  DEV/TEST escape hatch (create_private_dns_zones = true): create the Foundry
#  (openai + cognitiveservices + services.ai) and Key Vault (vaultcore) private
#  DNS zones IN THIS RG and link them to the VNet, so the private endpoints
#  resolve without a shared/platform DNS RG. The postgres + azurecontainerapps
#  zones are always reused by ID.
#  PRODUCTION: keep this false and let the ../private-dns-zones module own every
#  zone in a dedicated DNS RG; pass the IDs via the private_dns_zone_id_* vars.
###############################################################################

locals {
  create_dns = var.manage_pe_dns && var.create_private_dns_zones

  # zone short-name => full private DNS zone name, for the zones we may create.
  managed_zones = {
    openai            = "privatelink.openai.azure.com"
    cognitiveservices = "privatelink.cognitiveservices.azure.com"
    services_ai       = "privatelink.services.ai.azure.com"
    vault             = "privatelink.vaultcore.azure.net"
  }
}

resource "azurerm_private_dns_zone" "openai" {
  count               = local.create_dns ? 1 : 0
  name                = local.managed_zones.openai
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "openai" {
  count                 = local.create_dns ? 1 : 0
  name                  = "link-${var.name_prefix}-openai"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.openai[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone" "cognitiveservices" {
  count               = local.create_dns ? 1 : 0
  name                = local.managed_zones.cognitiveservices
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "cognitiveservices" {
  count                 = local.create_dns ? 1 : 0
  name                  = "link-${var.name_prefix}-cognitiveservices"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.cognitiveservices[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone" "services_ai" {
  count               = local.create_dns ? 1 : 0
  name                = local.managed_zones.services_ai
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "services_ai" {
  count                 = local.create_dns ? 1 : 0
  name                  = "link-${var.name_prefix}-services-ai"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.services_ai[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone" "vault" {
  count               = local.create_dns ? 1 : 0
  name                = local.managed_zones.vault
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "vault" {
  count                 = local.create_dns ? 1 : 0
  name                  = "link-${var.name_prefix}-vault"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.vault[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}
