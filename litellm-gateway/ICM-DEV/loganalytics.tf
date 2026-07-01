###############################################################################
#  Log Analytics workspace for the Container Apps environment.
###############################################################################

resource "azurerm_log_analytics_workspace" "logs" {
  name                = "log-${var.name_prefix}-${local.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}
