resource "azurerm_user_assigned_identity" "ManagedIdentity" {
  provider            = azurerm.miroki-dev
  location            = "francecentral"
  name                = "id-ca-icm-miroki-dev-frc-01"
  resource_group_name = "rg-miroki-dev-frc-01"
  tags                = {
     Environment = "DEV"
    Application = "Miroki"   
  }
}