###############################################################################
#  Private DNS zones the shared RG is MISSING — created here (in this RG) and
#  linked to the VNet so the Foundry / Key Vault private endpoints resolve.
#  Only privatelink.postgres.database.azure.com and
#  privatelink.francecentral.azurecontainerapps.io exist in the shared DNS RG;
#  privatelink.openai.azure.com and privatelink.vaultcore.azure.net do not.
#  (Skip with create_private_dns_zones = false if you pre-create them or a DNS
#  policy handles PE registration.)
###############################################################################

locals {
  create_dns = var.manage_pe_dns && var.create_private_dns_zones
}

resource "azurerm_private_dns_zone" "openai" {
  count               = local.create_dns ? 1 : 0
  name                = "privatelink.openai.azure.com"
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

resource "azurerm_private_dns_zone" "vault" {
  count               = local.create_dns ? 1 : 0
  name                = "privatelink.vaultcore.azure.net"
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
