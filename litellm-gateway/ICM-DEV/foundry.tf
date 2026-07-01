###############################################################################
#  Azure OpenAI Foundries (2) + gpt-4.1 (DataZoneStandard) + keyless RBAC.
#  Public when private = false; locked to private endpoints when private = true.
###############################################################################

resource "azurerm_cognitive_account" "foundry" {
  count = length(var.foundry_regions)

  name                          = "aif-${var.name_prefix}-0${count.index + 1}-${local.suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.foundry_regions[count.index]
  kind                          = "OpenAI"
  sku_name                      = "S0"
  custom_subdomain_name         = "aif-${var.name_prefix}-0${count.index + 1}-${local.suffix}"
  public_network_access_enabled = !var.private
  tags                          = var.tags
}

resource "azurerm_cognitive_deployment" "gpt" {
  count = length(var.foundry_regions)

  name                 = var.model_deployment_name
  cognitive_account_id = azurerm_cognitive_account.foundry[count.index].id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = var.model_sku_name
    capacity = var.model_capacity
  }
}

# LiteLLM identity -> Cognitive Services User on each Foundry (keyless).
resource "azurerm_role_assignment" "identity_foundry_user" {
  count = length(var.foundry_regions)

  scope                = azurerm_cognitive_account.foundry[count.index].id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_user_assigned_identity.litellm.principal_id
}

# Private endpoints (only when private = true).
resource "azurerm_private_endpoint" "foundry" {
  count = var.private ? length(var.foundry_regions) : 0

  name                = "pe-${azurerm_cognitive_account.foundry[count.index].name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${azurerm_cognitive_account.foundry[count.index].name}"
    private_connection_resource_id = azurerm_cognitive_account.foundry[count.index].id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      var.private_dns_zone_id_openai,
      var.private_dns_zone_id_cognitiveservices,
    ]
  }
}
