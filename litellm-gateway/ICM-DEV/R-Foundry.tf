###############################################################################
#  ADDED: Azure AI Foundry (AIServices) backends + gpt-4.1 deployments.
#  Two accounts so LiteLLM load balances across them. Keyless: the EXISTING
#  container-app identity gets "Cognitive Services User" on each.
###############################################################################

resource "azurerm_cognitive_account" "foundry" {
  provider = azurerm.miroki-dev
  count    = length(var.foundry_names)

  name                  = var.foundry_names[count.index]
  resource_group_name   = var.resource_group_name
  location              = var.foundry_regions[count.index]
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = var.foundry_names[count.index]

  # Public for the quick test (var default true); flip foundry_public_access to
  # false + enable_private_endpoints to reach them only via the private endpoints.
  public_network_access_enabled = var.foundry_public_access

  tags = var.tags
}

resource "azurerm_cognitive_deployment" "gpt" {
  provider = azurerm.miroki-dev
  count    = length(var.foundry_names)

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

# Container-app identity -> Cognitive Services User on each Foundry (keyless).
resource "azurerm_role_assignment" "identity_foundry_user" {
  provider = azurerm.miroki-dev
  count    = length(var.foundry_names)

  scope                = azurerm_cognitive_account.foundry[count.index].id
  role_definition_name = "Cognitive Services User"
  principal_id         = data.azurerm_user_assigned_identity.existing.principal_id
}

###############################################################################
#  Private endpoints for the Foundries (one per account).
###############################################################################

resource "azurerm_private_endpoint" "foundry" {
  provider = azurerm.miroki-dev
  count    = var.enable_private_endpoints ? length(var.foundry_names) : 0

  name                = "pe-${var.foundry_names[count.index]}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.foundry_names[count.index]}"
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
