###############################################################################
#  User-assigned managed identity for LiteLLM (keyless to Foundries + Key Vault).
###############################################################################

resource "azurerm_user_assigned_identity" "litellm" {
  name                = "id-${var.name_prefix}-${local.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}
