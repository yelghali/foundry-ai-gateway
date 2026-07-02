###############################################################################
#  Azure AI Foundry accounts (2) + gpt-5.1 (DataZoneStandard) + keyless RBAC.
#  kind = "AIServices" is the Azure AI Foundry resource (superset of Azure
#  OpenAI). Models (gpt-5.1) are deployed INSIDE each Foundry instance.
#  ALWAYS PRIVATE: public network access disabled + a private endpoint each.
###############################################################################

resource "azurerm_cognitive_account" "foundry" {
  count = length(var.foundry_regions)

  name                          = "aif-${var.name_prefix}-0${count.index + 1}-${local.suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.foundry_regions[count.index]
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = "aif-${var.name_prefix}-0${count.index + 1}-${local.suffix}"
  public_network_access_enabled = false
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

# Private endpoint per Foundry (always).
resource "azurerm_private_endpoint" "foundry" {
  count = length(var.foundry_regions)

  name                = "pe-${azurerm_cognitive_account.foundry[count.index].name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  # Wait until the model deployment finishes — creating the PE while the account
  # still has an in-flight deployment fails with AccountProvisioningStateInvalid.
  depends_on = [azurerm_cognitive_deployment.gpt]

  private_service_connection {
    name                           = "psc-${azurerm_cognitive_account.foundry[count.index].name}"
    private_connection_resource_id = azurerm_cognitive_account.foundry[count.index].id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = var.manage_pe_dns ? [1] : []
    content {
      name                 = "default"
      private_dns_zone_ids = local.foundry_zone_ids
    }
  }
}
